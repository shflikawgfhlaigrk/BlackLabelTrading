#!/usr/bin/env python3
"""Bounded, append-only command line runner for nested optimizer research.

The CLI snapshots at most 30,000 timestamped bars per requested contract, reserves the complete
worst-case hypothesis block before any optimizer work, and atomically publishes one latest report.
Reservations are never removed: a failed or interrupted process still spends its hypothesis budget.
An exact completed rerun is served from the published report and does not reserve or compute again.

This is an offline research tool. It never writes buyer configuration and a report can never adopt
parameters or authorize live use.
"""
from __future__ import annotations

import argparse
import contextlib
import errno
import hashlib
import json
import os
import sys
import tempfile
import time
import uuid
from typing import Callable

import bltd_optimizer as O
import bltd_paths
import bltd_store as S

LEDGER_KIND = "bltd_optimizer_hypothesis_ledger_v1"
RESERVATION_KIND = "bltd_optimizer_reservation_v1"
PROTOCOL_KIND = "bltd_bounded_nested_validation_v1"
MAX_BOOTSTRAP_SAMPLES = 10_000
MAX_SYMBOLS = 8
MAX_SYMBOL_LENGTH = 64
LOCK_TIMEOUT_SECONDS = 15.0
ATTEMPT_LOCK_TIMEOUT_SECONDS = 0.25
MALFORMED_LOCK_STALE_SECONDS = 300.0
RESEARCH_DISCLAIMER = (
    "Research only — this report is not adopted, is not eligible for live use, and never changes "
    "the buyer's configuration. Separate forward evidence and an explicit release process are "
    "required before any parameter could be considered."
)


class OptimizerCLIError(RuntimeError):
    """Fail-closed CLI input, ledger, or persistence error."""


def _json_bytes(value, *, pretty=False) -> bytes:
    options = {
        "sort_keys": True,
        "ensure_ascii": False,
        "allow_nan": False,
    }
    if pretty:
        options["indent"] = 2
    else:
        options["separators"] = (",", ":")
    return (json.dumps(value, **options) + ("\n" if pretty else "")).encode("utf-8")


def _hash_json(value) -> str:
    return hashlib.sha256(_json_bytes(value)).hexdigest()


def _hash_file(path: str) -> str:
    digest = hashlib.sha256()
    try:
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()
    except OSError:
        return "unknown"


def cli_source_sha() -> str:
    return _hash_file(__file__)


def _utc_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _atomic_write_json(path: str, value) -> str:
    """Write complete JSON beside its destination, fsync it, and publish with one replace."""
    target = os.path.abspath(path)
    parent = os.path.dirname(target)
    os.makedirs(parent, exist_ok=True)
    payload = _json_bytes(value, pretty=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{os.path.basename(target)}.", suffix=".tmp",
                                     dir=parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, target)
        # Persist the directory entry where the platform permits directory fsync. Genuine storage
        # failures propagate; only platforms/filesystems that explicitly do not support it degrade.
        try:
            flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
            directory_fd = os.open(parent, flags)
        except OSError as exc:
            unsupported = {
                errno.EINVAL, errno.ENOTSUP,
                getattr(errno, "EOPNOTSUPP", errno.ENOTSUP),
            }
            if exc.errno not in unsupported and not (
                    os.name == "nt" and exc.errno == errno.EACCES):
                raise
        else:
            try:
                try:
                    os.fsync(directory_fd)
                except OSError as exc:
                    unsupported = {
                        errno.EBADF, errno.EINVAL, errno.ENOTSUP,
                        getattr(errno, "EOPNOTSUPP", errno.ENOTSUP),
                    }
                    if exc.errno not in unsupported:
                        raise
            finally:
                os.close(directory_fd)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise
    return hashlib.sha256(payload).hexdigest()


def _paths_alias(left: str, right: str) -> bool:
    left = os.path.abspath(left)
    right = os.path.abspath(right)
    if os.path.normcase(os.path.realpath(left)) == os.path.normcase(os.path.realpath(right)):
        return True
    try:
        return os.path.samefile(left, right)
    except (FileNotFoundError, OSError):
        return False


def _validate_artifact_paths(write_paths: list[str], protected_paths: list[str]) -> None:
    writes = [os.path.abspath(path) for path in write_paths if path]
    protected = [os.path.abspath(path) for path in protected_paths if path]
    for index, left in enumerate(writes):
        for right in writes[index + 1:]:
            if _paths_alias(left, right):
                raise OptimizerCLIError("optimizer artifact paths must be distinct")
        for right in protected:
            if _paths_alias(left, right):
                raise OptimizerCLIError(
                    "optimizer artifacts must not overwrite the trading store or buyer config")


def _lock_identity(stat_result) -> tuple[int, int]:
    return int(stat_result.st_dev), int(stat_result.st_ino)


def _read_lock(path: str):
    """Return ``(token-or-None, stat)`` without following a substituted symlink."""
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    try:
        stat_result = os.fstat(fd)
        chunks = []
        remaining = 4096
        while remaining > 0:
            chunk = os.read(fd, remaining)
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
    finally:
        os.close(fd)
    try:
        token = json.loads(b"".join(chunks))
    except (ValueError, TypeError):
        token = None
    return token if isinstance(token, dict) else None, stat_result


def _pid_confirmed_dead(pid) -> bool:
    if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    except OSError as exc:
        return exc.errno == errno.ESRCH
    return False


def _unlink_same_lock(path: str, expected_identity: tuple[int, int],
                      expected_nonce: str | None) -> bool:
    """Unlink only the inode and nonce inspected by this caller, never a replacement owner."""
    try:
        token, stat_result = _read_lock(path)
    except OSError:
        return False
    if _lock_identity(stat_result) != expected_identity:
        return False
    if expected_nonce is not None and (
            not isinstance(token, dict) or token.get("nonce") != expected_nonce):
        return False
    try:
        current = os.stat(path, follow_symlinks=False)
    except OSError:
        return False
    if _lock_identity(current) != expected_identity:
        return False
    try:
        os.unlink(path)
        return True
    except OSError:
        return False


def _reclaim_stale_lock(lock_path: str) -> bool:
    """Reclaim only a confirmed-dead owner, or an old malformed/incomplete lock."""
    try:
        token, stat_result = _read_lock(lock_path)
    except OSError:
        return False
    identity = _lock_identity(stat_result)
    valid_owner = (
        isinstance(token, dict)
        and isinstance(token.get("nonce"), str) and bool(token.get("nonce"))
        and isinstance(token.get("pid"), int) and not isinstance(token.get("pid"), bool)
        and token.get("pid") > 0
    )
    if valid_owner and _pid_confirmed_dead(token.get("pid")):
        return _unlink_same_lock(lock_path, identity, token["nonce"])
    age = max(0.0, time.time() - float(stat_result.st_mtime))
    if not valid_owner and age >= MALFORMED_LOCK_STALE_SECONDS:
        nonce = token.get("nonce") if isinstance(token, dict) \
            and isinstance(token.get("nonce"), str) else None
        return _unlink_same_lock(lock_path, identity, nonce)
    return False


@contextlib.contextmanager
def _exclusive_ledger_lock(ledger_path: str, timeout: float = LOCK_TIMEOUT_SECONDS):
    """Cross-process O_EXCL lock held only for a short ledger read/replace transaction."""
    lock_path = os.path.abspath(ledger_path) + ".lock"
    os.makedirs(os.path.dirname(lock_path), exist_ok=True)
    deadline = time.monotonic() + max(0.0, float(timeout))
    fd = None
    owned_identity = None
    token = {
        "pid": os.getpid(),
        "createdUTC": _utc_now(),
        "createdEpoch": time.time(),
        "nonce": uuid.uuid4().hex,
    }
    while fd is None:
        try:
            fd = os.open(lock_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            owned_identity = _lock_identity(os.fstat(fd))
        except FileExistsError:
            if _reclaim_stale_lock(lock_path):
                continue
            if time.monotonic() >= deadline:
                raise OptimizerCLIError("optimizer hypothesis ledger is busy")
            time.sleep(0.02)
    try:
        payload = _json_bytes(token)
        offset = 0
        while offset < len(payload):
            written = os.write(fd, payload[offset:])
            if written <= 0:
                raise OSError("short optimizer ledger lock write")
            offset += written
        os.fsync(fd)
        os.close(fd)
        fd = None
        yield
    finally:
        if fd is not None:
            os.close(fd)
        if owned_identity is not None:
            _unlink_same_lock(lock_path, owned_identity, token["nonce"])


def _new_ledger() -> dict:
    return {
        "kind": LEDGER_KIND,
        "basePriorFamilySize": O.DEFAULT_PRIOR_FAMILY_SIZE,
        "events": [],
    }


def _load_ledger_unlocked(path: str) -> dict:
    try:
        with open(path, "rb") as handle:
            ledger = json.load(handle)
    except FileNotFoundError:
        return _new_ledger()
    except (OSError, ValueError, TypeError) as exc:
        raise OptimizerCLIError(
            f"optimizer hypothesis ledger is unreadable ({type(exc).__name__})") from exc
    if not isinstance(ledger, dict) or ledger.get("kind") != LEDGER_KIND:
        raise OptimizerCLIError("optimizer hypothesis ledger has an unsupported schema")
    base = ledger.get("basePriorFamilySize")
    events = ledger.get("events")
    if (isinstance(base, bool) or not isinstance(base, int)
            or base < O.DEFAULT_PRIOR_FAMILY_SIZE or not isinstance(events, list)
            or any(not isinstance(event, dict) for event in events)):
        raise OptimizerCLIError("optimizer hypothesis ledger is invalid")
    return ledger


def _reserved_family_total(ledger: dict) -> int:
    """Base plus each unique reservation's full planned family, regardless of terminal status."""
    total = int(ledger["basePriorFamilySize"])
    seen: dict[str, int] = {}
    for event in ledger["events"]:
        if event.get("status") != "reserved":
            continue
        reservation_id = event.get("reservationId")
        count = event.get("hypothesisCount")
        if (not isinstance(reservation_id, str) or len(reservation_id) != 64
                or isinstance(count, bool) or not isinstance(count, int) or count <= 0):
            raise OptimizerCLIError("optimizer hypothesis ledger contains an invalid reservation")
        if reservation_id in seen and seen[reservation_id] != count:
            raise OptimizerCLIError("optimizer hypothesis ledger contains a conflicting reservation")
        if reservation_id not in seen:
            seen[reservation_id] = count
            total += count
    return total


def _reservation_events(ledger: dict, reservation_id: str) -> list[dict]:
    return [event for event in ledger["events"]
            if event.get("reservationId") == reservation_id]


def _append_event(ledger_path: str, event: dict) -> None:
    with _exclusive_ledger_lock(ledger_path):
        ledger = _load_ledger_unlocked(ledger_path)
        ledger = {**ledger, "events": [*ledger["events"], event]}
        _atomic_write_json(ledger_path, ledger)


def _reserve(ledger_path: str, reservation: dict) -> tuple[dict, bool, list[dict]]:
    """Atomically return an existing reservation or append one with its prior-family snapshot."""
    reservation_id = reservation["reservationId"]
    with _exclusive_ledger_lock(ledger_path):
        ledger = _load_ledger_unlocked(ledger_path)
        matching = _reservation_events(ledger, reservation_id)
        reserved = [event for event in matching if event.get("status") == "reserved"]
        if reserved:
            first = reserved[0]
            for field in ("engine", "symbols", "protocolHash", "gridSha256",
                          "sourceHash", "inputHashes", "hypothesisCount"):
                if first.get(field) != reservation.get(field):
                    raise OptimizerCLIError(
                        "optimizer hypothesis ledger reservation identity conflict")
            prior = first.get("priorFamilySize")
            if (isinstance(prior, bool) or not isinstance(prior, int)
                    or prior < O.DEFAULT_PRIOR_FAMILY_SIZE):
                raise OptimizerCLIError(
                    "optimizer hypothesis ledger reservation has an invalid prior family")
            return first, False, matching

        prior_family_size = _reserved_family_total(ledger)
        event = {
            **reservation,
            "status": "reserved",
            "createdUTC": _utc_now(),
            "ownerPid": os.getpid(),
            "priorFamilySize": prior_family_size,
        }
        ledger = {**ledger, "events": [*ledger["events"], event]}
        _atomic_write_json(ledger_path, ledger)
        return event, True, [event]


def _append_completed(ledger_path: str, reservation_id: str, report: dict,
                      report_sha256: str, *, recovered=False) -> None:
    event = {
        "status": "completed",
        "reservationId": reservation_id,
        "completedUTC": _utc_now(),
        "reportSha256": report_sha256,
        "runId": ((report.get("provenance") or {}).get("runId")
                  if isinstance(report.get("provenance"), dict) else None),
        "available": bool(report.get("available")),
        "researchCandidateCount": len(report.get("researchCandidates") or []),
    }
    if recovered:
        event["recoveredAtomicReport"] = True
    with _exclusive_ledger_lock(ledger_path):
        ledger = _load_ledger_unlocked(ledger_path)
        for existing in _reservation_events(ledger, reservation_id):
            if (existing.get("status") == "completed"
                    and existing.get("reportSha256") == report_sha256):
                return
        ledger = {**ledger, "events": [*ledger["events"], event]}
        _atomic_write_json(ledger_path, ledger)


def _append_report_prepared(ledger_path: str, reservation_id: str,
                            report_sha256: str) -> None:
    event = {
        "status": "reportPrepared",
        "reservationId": reservation_id,
        "preparedUTC": _utc_now(),
        "reportSha256": report_sha256,
    }
    with _exclusive_ledger_lock(ledger_path):
        ledger = _load_ledger_unlocked(ledger_path)
        for existing in _reservation_events(ledger, reservation_id):
            if (existing.get("status") == "reportPrepared"
                    and existing.get("reportSha256") == report_sha256):
                return
        ledger = {**ledger, "events": [*ledger["events"], event]}
        _atomic_write_json(ledger_path, ledger)


def _append_failed(ledger_path: str, reservation_id: str, exc: BaseException) -> None:
    message = str(exc).replace("\n", " ").strip()
    event = {
        "status": "failed",
        "reservationId": reservation_id,
        "failedUTC": _utc_now(),
        "errorType": type(exc).__name__,
        "reason": (message[:240] if message else "optimizer research interrupted"),
    }
    _append_event(ledger_path, event)


def _ledger_events(ledger_path: str, reservation_id: str) -> list[dict]:
    with _exclusive_ledger_lock(ledger_path):
        return _reservation_events(_load_ledger_unlocked(ledger_path), reservation_id)


def _report_cache_path(ledger_path: str, reservation_id: str) -> str:
    return os.path.join(os.path.abspath(ledger_path) + ".reports",
                        f"{reservation_id}.json")


def _split_symbols(values) -> list[str]:
    symbols = set()
    for value in values or []:
        for symbol in str(value or "").split(","):
            symbol = symbol.strip()
            if symbol:
                symbols.add(symbol)
    return sorted(symbols)


def _validate_request(engine: str, symbols: list[str], start_ts, end_ts,
                      bootstrap_samples: int) -> None:
    if engine not in S.ACTIVE_ENGINE_FAMILY or engine not in O.CANONICAL_GRIDS:
        alias = S.DUPLICATE_ENGINE_ALIASES.get(engine)
        detail = f"; use canonical engine '{alias}'" if alias else ""
        raise OptimizerCLIError(f"one active canonical engine is required{detail}")
    if len(symbols) < 2:
        raise OptimizerCLIError("at least two independent contract symbols are required")
    if len(symbols) > MAX_SYMBOLS:
        raise OptimizerCLIError(f"at most {MAX_SYMBOLS} contract symbols are allowed")
    if any(len(symbol) > MAX_SYMBOL_LENGTH for symbol in symbols):
        raise OptimizerCLIError(
            f"contract symbols must be at most {MAX_SYMBOL_LENGTH} characters")
    normalized = [S.normalize_symbol(symbol) for symbol in symbols]
    if any(not symbol for symbol in normalized) or len(set(normalized)) < 2:
        raise OptimizerCLIError(
            "at least two distinct normalized contract symbols are required")
    if start_ts is not None and end_ts is not None and int(start_ts) > int(end_ts):
        raise OptimizerCLIError("--start must be less than or equal to --end")
    if (isinstance(bootstrap_samples, bool) or int(bootstrap_samples) < 1
            or int(bootstrap_samples) > MAX_BOOTSTRAP_SAMPLES):
        raise OptimizerCLIError(
            f"--bootstrap-samples must be between 1 and {MAX_BOOTSTRAP_SAMPLES}")


def _build_reservation(engine: str, symbols: list[str], series_by_contract: dict,
                       cfg: dict, *, start_ts=None, end_ts=None,
                       bootstrap_samples=200, source_hashes=None) -> dict:
    """Build the timestamp-independent reservation identity used by tests and the CLI."""
    grid = O.CANONICAL_GRIDS[engine]
    effective_cfg = O.effective_research_config()
    input_hashes = {
        symbol: {
            "bars": len(series_by_contract.get(symbol) or []),
            "sha256": O._series_hash(series_by_contract.get(symbol) or []),
        }
        for symbol in symbols
    }
    protocol = {
        "kind": PROTOCOL_KIND,
        "costBandsPoints": list(O.DEFAULT_COST_BANDS),
        "outerFolds": O.REQUIRED_OUTER_FOLDS,
        "embargoBars": O.MIN_EMBARGO_BARS,
        "maxHoldingBars": O.FROZEN_MAX_HOLDING_BARS,
        "maxBarsPerContract": O.MAX_BARS_PER_CONTRACT,
        "startTs": (None if start_ts is None else int(start_ts)),
        "endTs": (None if end_ts is None else int(end_ts)),
        "bootstrapSamples": int(bootstrap_samples),
        "researchConfigSource": "frozen_protocol_not_buyer_config",
        "effectiveResearchConfig": effective_cfg,
        "gridBoundConfigKeys": {
            engine: sorted(O.GRID_BOUND_CONFIG_KEYS[engine]),
        },
        "parameterGrid": {engine: list(grid)},
        "configSha256": O._canonical_hash(effective_cfg),
    }
    sources = source_hashes or {
        "optimizerSha256": O.optimizer_source_sha(),
        "proverSha": S.prover_source_sha(),
        "proverSha256": S.prover_source_sha256(),
        "cliSha256": cli_source_sha(),
    }
    required_full_sources = ("optimizerSha256", "proverSha256", "cliSha256")
    if any(
            not isinstance(sources.get(name), str)
            or len(sources[name]) != 64
            or any(char not in "0123456789abcdef" for char in sources[name].lower())
            for name in required_full_sources):
        raise OptimizerCLIError("optimizer source provenance is unavailable")
    grid_sha = O._canonical_hash({engine: grid})
    source_hash = _hash_json(sources)
    protocol_hash = _hash_json(protocol)
    hypothesis_count = (
        O.REQUIRED_OUTER_FOLDS * len(symbols) * len(O.DEFAULT_COST_BANDS) * (len(grid) + 1)
    )
    identity = {
        "kind": RESERVATION_KIND,
        "engine": engine,
        "symbols": symbols,
        "inputHashes": input_hashes,
        "protocolHash": protocol_hash,
        "gridSha256": grid_sha,
        "sourceHash": source_hash,
    }
    return {
        **identity,
        "reservationId": _hash_json(identity),
        "protocol": protocol,
        "gridCellCount": len(grid),
        "sourceHashes": sources,
        "hypothesisCount": hypothesis_count,
    }


def _load_cached_report(path: str, reservation: dict, reserved_event: dict,
                        events: list[dict]) -> tuple[dict, str] | None:
    try:
        with open(path, "rb") as handle:
            raw = handle.read()
        report = json.loads(raw)
    except (OSError, ValueError, TypeError):
        return None
    reservation_id = reservation["reservationId"]
    expected_binding = {
        "engine": reservation["engine"],
        "symbols": reservation["symbols"],
        "inputHashes": reservation["inputHashes"],
        "protocol": reservation["protocol"],
        "protocolHash": reservation["protocolHash"],
        "gridSha256": reservation["gridSha256"],
        "sourceHashes": reservation["sourceHashes"],
        "sourceHash": reservation["sourceHash"],
        "hypothesisCount": reservation["hypothesisCount"],
        "priorFamilySize": reserved_event["priorFamilySize"],
    }
    binding = report.get("hypothesisReservation") if isinstance(report, dict) else None
    provenance = report.get("provenance") if isinstance(report, dict) else None
    if (not isinstance(report, dict)
            or report.get("kind") != "nested_strategy_validation"
            or report.get("reservationId") != reservation_id
            or report.get("available") is not True
            or report.get("researchOnly") is not True
            or report.get("eligibleForLive") is not False
            or report.get("adopted") is not False
            or report.get("disclaimer") != RESEARCH_DISCLAIMER
            or not isinstance(provenance, dict)
            or not isinstance(provenance.get("runId"), str)
            or not provenance.get("runId")
            or not isinstance(binding, dict)
            or any(binding.get(key) != value for key, value in expected_binding.items())):
        return None
    digest = hashlib.sha256(raw).hexdigest()
    committed_digests = {
        event.get("reportSha256") for event in events
        if event.get("status") in ("reportPrepared", "completed")
        and isinstance(event.get("reportSha256"), str)
    }
    if digest not in committed_digests:
        return None
    return report, digest


def _find_cached_report(output_path: str, ledger_path: str, reservation: dict,
                        reserved_event: dict, events: list[dict]):
    for path in (output_path, _report_cache_path(ledger_path, reservation["reservationId"])):
        cached = _load_cached_report(path, reservation, reserved_event, events)
        if cached is not None:
            return cached
    return None


def _write_immutable_report_cache(path: str, report: dict, expected_digest: str) -> None:
    try:
        with open(path, "rb") as handle:
            existing = handle.read()
    except FileNotFoundError:
        existing = None
    except OSError as exc:
        raise OptimizerCLIError(
            f"optimizer report cache is unreadable ({type(exc).__name__})") from exc
    if existing is not None:
        if hashlib.sha256(existing).hexdigest() != expected_digest:
            raise OptimizerCLIError("optimizer report cache identity conflict")
        return
    written = _atomic_write_json(path, report)
    if written != expected_digest:
        raise OptimizerCLIError("optimizer report cache digest mismatch")


def run_optimizer(*, engine: str, symbols: list[str], store_path: str | None = None,
                  output_path: str | None = None, ledger_path: str | None = None,
                  start_ts=None, end_ts=None, bootstrap_samples=200, store=None,
                  validator: Callable | None = None) -> tuple[dict, bool]:
    """Reserve, run, and atomically publish. Returns ``(report, was_cached)``."""
    symbols = _split_symbols(symbols)
    if isinstance(bootstrap_samples, bool):
        raise OptimizerCLIError(
            f"--bootstrap-samples must be between 1 and {MAX_BOOTSTRAP_SAMPLES}")
    try:
        bootstrap_samples = int(bootstrap_samples)
    except (TypeError, ValueError, OverflowError) as exc:
        raise OptimizerCLIError("--bootstrap-samples must be an integer") from exc
    _validate_request(engine, symbols, start_ts, end_ts, bootstrap_samples)
    output_path = output_path or bltd_paths.optimizer_report_path()
    ledger_path = ledger_path or bltd_paths.optimizer_ledger_path()
    store = store or S.Store(store_path or bltd_paths.store_path())
    effective_store_path = store_path or getattr(store, "path", None)
    config_path = getattr(store, "config_path", None)
    protected_paths = [effective_store_path, config_path]
    _validate_artifact_paths(
        [output_path, ledger_path, ledger_path + ".lock", ledger_path + ".reports"],
        protected_paths)

    # Snapshot bars only. Buyer settings never enter the research protocol or engine geometry.
    cfg = O.effective_research_config()
    series = {
        symbol: store.ohlc_between_timestamped(
            symbol, start_ts=start_ts, end_ts=end_ts, limit=O.MAX_BARS_PER_CONTRACT)
        for symbol in symbols
    }
    reservation = _build_reservation(
        engine, symbols, series, cfg, start_ts=start_ts, end_ts=end_ts,
        bootstrap_samples=bootstrap_samples)
    reservation_id = reservation["reservationId"]
    cache_path = _report_cache_path(ledger_path, reservation_id)
    attempt_base = os.path.abspath(ledger_path) + f".attempt-{reservation_id}"
    _validate_artifact_paths(
        [output_path, ledger_path, ledger_path + ".lock", ledger_path + ".reports",
         cache_path, attempt_base + ".lock"],
        protected_paths)
    reserved_event, created, existing_events = _reserve(ledger_path, reservation)

    def use_cache(events):
        cached = _find_cached_report(
            output_path, ledger_path, reservation, reserved_event, events)
        if cached is None:
            return None
        report, report_sha = cached
        _write_immutable_report_cache(cache_path, report, report_sha)
        # A/B/A and a changed --output both republish the immutable completed report as latest.
        with open(output_path, "rb") if os.path.exists(output_path) else contextlib.nullcontext(None) as handle:
            latest_sha = hashlib.sha256(handle.read()).hexdigest() if handle is not None else None
        if latest_sha != report_sha:
            if _atomic_write_json(output_path, report) != report_sha:
                raise OptimizerCLIError("optimizer latest report digest mismatch")
        if not any(event.get("status") == "completed"
                   and event.get("reportSha256") == report_sha for event in events):
            _append_completed(
                ledger_path, reservation_id, report, report_sha, recovered=True)
        return report, True

    cached_result = use_cache(existing_events)
    if cached_result is not None:
        return cached_result
    has_terminal_attempt = any(
        event.get("status") in ("failed", "reportPrepared", "completed")
        for event in existing_events)
    if (not created and not has_terminal_attempt
            and not _pid_confirmed_dead(reserved_event.get("ownerPid"))):
        raise OptimizerCLIError(
            "identical optimizer research is reserved by a live process")

    # A per-reservation O_EXCL attempt lease prevents duplicate retries. SIGKILL leaves a PID-tagged
    # orphan which the same stale-owner logic safely reclaims without adding another reservation.
    with _exclusive_ledger_lock(attempt_base, timeout=ATTEMPT_LOCK_TIMEOUT_SECONDS):
        refreshed_events = _ledger_events(ledger_path, reservation_id)
        cached_result = use_cache(refreshed_events)
        if cached_result is not None:
            return cached_result

        validate = validator or O.nested_validate
        try:
            report = validate(
                series,
                engines=[engine],
                grids={engine: list(O.CANONICAL_GRIDS[engine])},
                base_cfg=cfg,
                costs=O.DEFAULT_COST_BANDS,
                outer_folds=O.REQUIRED_OUTER_FOLDS,
                embargo=O.MIN_EMBARGO_BARS,
                prior_family_size=reserved_event["priorFamilySize"],
                bootstrap_samples=bootstrap_samples,
            )
            if not isinstance(report, dict) or report.get("kind") != "nested_strategy_validation":
                raise OptimizerCLIError("optimizer returned an invalid research report")
            if report.get("available") is not True:
                reason = str(report.get("reason") or "validation protocol did not complete")
                raise OptimizerCLIError(f"optimizer research unavailable: {reason}")
            report = {
                **report,
                "reservationId": reservation_id,
                "generatedUTC": _utc_now(),
                "researchOnly": True,
                "eligibleForLive": False,
                "adopted": False,
                "disclaimer": RESEARCH_DISCLAIMER,
                "hypothesisReservation": {
                    "engine": reservation["engine"],
                    "symbols": reservation["symbols"],
                    "inputHashes": reservation["inputHashes"],
                    "protocol": reservation["protocol"],
                    "protocolHash": reservation["protocolHash"],
                    "gridSha256": reservation["gridSha256"],
                    "sourceHashes": reservation["sourceHashes"],
                    "sourceHash": reservation["sourceHash"],
                    "hypothesisCount": reservation["hypothesisCount"],
                    "priorFamilySize": reserved_event["priorFamilySize"],
                },
            }
            report_sha = hashlib.sha256(_json_bytes(report, pretty=True)).hexdigest()
            # Precommit the exact payload digest before either visible atomic publication.
            _append_report_prepared(ledger_path, reservation_id, report_sha)
            _write_immutable_report_cache(cache_path, report, report_sha)
            if _atomic_write_json(output_path, report) != report_sha:
                raise OptimizerCLIError("optimizer latest report digest mismatch")
            _append_completed(ledger_path, reservation_id, report, report_sha)
            return report, False
        except BaseException as exc:
            try:
                _append_failed(ledger_path, reservation_id, exc)
            except BaseException:
                pass
            raise


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=("Run bounded nested strategy validation over timestamped bars already in the "
                     "buyer's own Black Label Trading store. Research only; never changes config."))
    parser.add_argument("--engine", required=True,
                        help="one active canonical engine (for example: meanrev)")
    parser.add_argument(
        "--symbols", "--symbol", dest="symbols", action="append", required=True,
        help="two or more independent contracts; repeat or comma-separate this option")
    parser.add_argument("--store", default=None, help="SQLite store path")
    parser.add_argument("--output", default=None, help="latest atomic research report path")
    parser.add_argument("--ledger", default=None, help="append-only hypothesis ledger path")
    parser.add_argument("--start", type=int, default=None, help="inclusive first bar epoch")
    parser.add_argument("--end", type=int, default=None, help="inclusive last bar epoch")
    parser.add_argument("--bootstrap-samples", type=int, default=200,
                        help=f"deterministic bootstrap samples (1..{MAX_BOOTSTRAP_SAMPLES})")
    return parser


def main(argv=None) -> int:
    args = _parser().parse_args(argv)
    try:
        report, _cached = run_optimizer(
            engine=args.engine,
            symbols=args.symbols,
            store_path=args.store,
            output_path=args.output,
            ledger_path=args.ledger,
            start_ts=args.start,
            end_ts=args.end,
            bootstrap_samples=args.bootstrap_samples,
        )
    except KeyboardInterrupt:
        print("optimizer research interrupted; its reservation remains counted", file=sys.stderr)
        return 130
    except Exception as exc:  # noqa: BLE001 — CLI boundary; ledger records the precise type
        print(f"optimizer research failed: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 2
    sys.stdout.buffer.write(_json_bytes(report, pretty=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
