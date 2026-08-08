#!/usr/bin/env python3
"""Regression locks for the bounded optimizer CLI ledger, cache, and atomic report."""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import threading
import time

import bltd_optimizer as O
import bltd_optimizer_cli as C
import bltd_store as S


def _series(offset=0, marker=100.0, count=300):
    return [(marker, marker + 1.0, marker - 1.0, marker, offset + i)
            for i in range(count)]


class _FakeStore:
    def __init__(self, series=None, cfg=None):
        self.series = series or {"ESU6": _series(), "MESU6": _series(10_000)}
        self.cfg = cfg or {**S.CONFIG_DEFAULTS, "engines": list(S.ACTIVE_ENGINE_FAMILY)}
        self.config_calls = 0

    def config(self):
        self.config_calls += 1
        return json.loads(json.dumps(self.cfg))

    def ohlc_between_timestamped(self, symbol, start_ts=None, end_ts=None, limit=None):
        rows = self.series.get(symbol, [])
        if start_ts is not None:
            rows = [row for row in rows if row[4] >= start_ts]
        if end_ts is not None:
            rows = [row for row in rows if row[4] <= end_ts]
        return list(rows[-int(limit):])


def _report(prior_family_size=350):
    return {
        "kind": "nested_strategy_validation",
        "available": True,
        "label": "Bounded nested validation. Research only.",
        "provenance": {"runId": f"run-{prior_family_size}"},
        "researchCandidates": [],
        "eligibleForLive": False,
        "adopted": False,
        "reason": "No confirmed research observation.",
    }


def _paths(directory):
    return (os.path.join(directory, "optimizer-latest.json"),
            os.path.join(directory, "optimizer-ledger.json"))


def test_reservation_id_binds_inputs_protocol_grid_and_source_without_time():
    cfg = {**S.CONFIG_DEFAULTS, "engines": list(S.ACTIVE_ENGINE_FAMILY)}
    symbols = ["ESU6", "MESU6"]
    series = {"ESU6": _series(), "MESU6": _series(10_000)}
    source = {"optimizerSha256": "a" * 64, "proverSha": "b" * 16,
              "proverSha256": "b" * 64, "cliSha256": "c" * 64}
    first = C._build_reservation(
        "momentum", symbols, series, cfg, bootstrap_samples=20, source_hashes=source)
    second = C._build_reservation(
        "momentum", symbols, series, cfg, bootstrap_samples=20, source_hashes=source)
    assert first["reservationId"] == second["reservationId"]
    assert first["hypothesisCount"] == 3 * 2 * 3 * (4 + 1)
    assert len(first["protocolHash"]) == len(first["gridSha256"]) == 64
    assert first["sourceHashes"] == source
    effective = O.effective_research_config()
    assert first["protocol"]["maxHoldingBars"] == 80
    assert first["protocol"]["embargoBars"] >= first["protocol"]["maxHoldingBars"]
    assert first["protocol"]["effectiveResearchConfig"] == effective
    assert first["protocol"]["gridBoundConfigKeys"] == {"momentum": ["lookback"]}
    assert first["protocol"]["parameterGrid"] == {
        "momentum": O.CANONICAL_GRIDS["momentum"],
    }
    assert first["protocol"]["configSha256"] == O._canonical_hash(effective)

    hostile_cfg = {**cfg, "bkMaxHold": 10_000, "researchTickSize": 7.0}
    hostile = C._build_reservation(
        "momentum", symbols, series, hostile_cfg, bootstrap_samples=20,
        source_hashes=source)
    assert hostile["reservationId"] == first["reservationId"]
    assert hostile["protocol"] == first["protocol"]

    changed_input = {**series, "ESU6": _series(offset=1)}
    changed_protocol = C._build_reservation(
        "momentum", symbols, series, cfg, bootstrap_samples=21, source_hashes=source)
    changed_source = C._build_reservation(
        "momentum", symbols, series, cfg, bootstrap_samples=20,
        source_hashes={**source, "cliSha256": "d" * 64})
    assert C._build_reservation(
        "momentum", symbols, changed_input, cfg, bootstrap_samples=20,
        source_hashes=source)["reservationId"] != first["reservationId"]
    assert changed_protocol["reservationId"] != first["reservationId"]
    assert changed_source["reservationId"] != first["reservationId"]

    original = O.CANONICAL_GRIDS["momentum"]
    try:
        O.CANONICAL_GRIDS["momentum"] = [*original, {"lookback": 99}]
        changed_grid = C._build_reservation(
            "momentum", symbols, series, cfg, bootstrap_samples=20, source_hashes=source)
    finally:
        O.CANONICAL_GRIDS["momentum"] = original
    assert changed_grid["reservationId"] != first["reservationId"]
    actual_source = C._build_reservation(
        "momentum", symbols, series, cfg, bootstrap_samples=20)["sourceHashes"]
    assert actual_source["proverSha256"] == S.prover_source_sha256()
    assert len(actual_source["proverSha256"]) == 64
    saved_cli_sha = C.cli_source_sha
    try:
        C.cli_source_sha = lambda: "unknown"
        try:
            C._build_reservation(
                "momentum", symbols, series, cfg, bootstrap_samples=20)
            assert False, "unavailable source identity must fail before reservation"
        except C.OptimizerCLIError as exc:
            assert "source provenance" in str(exc)
    finally:
        C.cli_source_sha = saved_cli_sha


def test_completed_exact_rerun_is_cached_and_not_reserved_twice():
    with tempfile.TemporaryDirectory() as directory:
        output, ledger = _paths(directory)
        calls = []

        def validator(_series_by_contract, **kwargs):
            calls.append(kwargs["prior_family_size"])
            return _report(kwargs["prior_family_size"])

        first, first_cached = C.run_optimizer(
            engine="momentum", symbols=["MESU6,ESU6"], store=_FakeStore(),
            output_path=output, ledger_path=ledger, bootstrap_samples=5,
            validator=validator)
        second, second_cached = C.run_optimizer(
            engine="momentum", symbols=["ESU6", "MESU6"], store=_FakeStore(),
            output_path=output, ledger_path=ledger, bootstrap_samples=5,
            validator=validator)
        assert first_cached is False and second_cached is True
        assert first == second and calls == [O.DEFAULT_PRIOR_FAMILY_SIZE]
        with open(ledger) as handle:
            events = json.load(handle)["events"]
        assert [event["status"] for event in events] == [
            "reserved", "reportPrepared", "completed"]
        assert len({event["reservationId"] for event in events}) == 1
        assert events[0]["hypothesisCount"] == 90
        assert first["researchOnly"] is True
        assert first["eligibleForLive"] is False and first["adopted"] is False
        assert "not eligible for live use" in first["disclaimer"]


def test_completed_cache_survives_other_runs_and_changed_latest_output_path():
    with tempfile.TemporaryDirectory() as directory:
        output, ledger = _paths(directory)
        other_output = os.path.join(directory, "alternate-latest.json")
        calls = []

        def validator(_series_by_contract, **kwargs):
            calls.append(kwargs["prior_family_size"])
            return _report(kwargs["prior_family_size"])

        store_a = _FakeStore()
        store_b = _FakeStore({
            "ESU6": _series(offset=1),
            "MESU6": _series(10_000),
        })
        report_a, cached_a = C.run_optimizer(
            engine="regime", symbols=["ESU6", "MESU6"], store=store_a,
            output_path=output, ledger_path=ledger, bootstrap_samples=2,
            validator=validator)
        report_b, cached_b = C.run_optimizer(
            engine="regime", symbols=["ESU6", "MESU6"], store=store_b,
            output_path=output, ledger_path=ledger, bootstrap_samples=2,
            validator=validator)
        again_a, cached_again = C.run_optimizer(
            engine="regime", symbols=["ESU6", "MESU6"], store=store_a,
            output_path=output, ledger_path=ledger, bootstrap_samples=2,
            validator=validator)
        moved_a, cached_moved = C.run_optimizer(
            engine="regime", symbols=["ESU6", "MESU6"], store=store_a,
            output_path=other_output, ledger_path=ledger, bootstrap_samples=2,
            validator=validator)
        assert [cached_a, cached_b, cached_again, cached_moved] == [
            False, False, True, True]
        assert len(calls) == 2
        assert report_a == again_a == moved_a and report_a != report_b
        with open(output) as handle:
            assert json.load(handle)["reservationId"] == report_a["reservationId"]
        with open(other_output) as handle:
            assert json.load(handle)["reservationId"] == report_a["reservationId"]
        cache_dir = ledger + ".reports"
        assert sorted(name for name in os.listdir(cache_dir) if name.endswith(".json"))
        assert len(os.listdir(cache_dir)) == 2


def test_failed_reservation_remains_in_next_runs_prior_family():
    with tempfile.TemporaryDirectory() as directory:
        output, ledger = _paths(directory)

        def fail(_series_by_contract, **_kwargs):
            raise RuntimeError("planted compute failure")

        try:
            C.run_optimizer(
                engine="momentum", symbols=["ESU6", "MESU6"], store=_FakeStore(),
                output_path=output, ledger_path=ledger, bootstrap_samples=5, validator=fail)
            assert False, "planted validator failure must escape"
        except RuntimeError:
            pass
        with open(ledger) as handle:
            after_failure = json.load(handle)
        assert [event["status"] for event in after_failure["events"]] == ["reserved", "failed"]
        spent = after_failure["events"][0]["hypothesisCount"]

        captured = []
        changed = _FakeStore({
            "ESU6": _series(offset=1),
            "MESU6": _series(10_000),
        })

        def succeed(_series_by_contract, **kwargs):
            captured.append(kwargs["prior_family_size"])
            return _report(kwargs["prior_family_size"])

        C.run_optimizer(
            engine="momentum", symbols=["ESU6", "MESU6"], store=changed,
            output_path=output, ledger_path=ledger, bootstrap_samples=5, validator=succeed)
        assert captured == [O.DEFAULT_PRIOR_FAMILY_SIZE + spent]
        with open(ledger) as handle:
            final = json.load(handle)
        assert len([event for event in final["events"]
                    if event["status"] == "reserved"]) == 2


def test_keyboard_interrupt_is_terminal_but_reservation_stays_counted():
    with tempfile.TemporaryDirectory() as directory:
        output, ledger = _paths(directory)

        def interrupt(_series_by_contract, **_kwargs):
            raise KeyboardInterrupt()

        try:
            C.run_optimizer(
                engine="structure", symbols=["ESU6", "MESU6"], store=_FakeStore(),
                output_path=output, ledger_path=ledger, bootstrap_samples=1,
                validator=interrupt)
            assert False, "KeyboardInterrupt must escape the library boundary"
        except KeyboardInterrupt:
            pass
        with open(ledger) as handle:
            contents = json.load(handle)
        assert [event["status"] for event in contents["events"]] == ["reserved", "failed"]
        assert contents["events"][1]["errorType"] == "KeyboardInterrupt"
        assert C._reserved_family_total(contents) == (
            O.DEFAULT_PRIOR_FAMILY_SIZE + contents["events"][0]["hypothesisCount"])


def test_unavailable_validation_is_failed_and_never_published_or_cached():
    with tempfile.TemporaryDirectory() as directory:
        output, ledger = _paths(directory)

        def unavailable(_series_by_contract, **kwargs):
            report = _report(kwargs["prior_family_size"])
            report.update(available=False, reason="insufficient bars for anchored folds")
            return report

        try:
            C.run_optimizer(
                engine="structure", symbols=["ESU6", "MESU6"], store=_FakeStore(),
                output_path=output, ledger_path=ledger, bootstrap_samples=1,
                validator=unavailable)
            assert False, "an incomplete validation must fail instead of becoming latest"
        except C.OptimizerCLIError as exc:
            assert "unavailable" in str(exc)
            assert "insufficient bars" in str(exc)
        assert not os.path.exists(output)
        with open(ledger) as handle:
            contents = json.load(handle)
        assert [event["status"] for event in contents["events"]] == ["reserved", "failed"]
        assert contents["events"][1]["errorType"] == "OptimizerCLIError"

        forged = {
            **_report(),
            "available": False,
            "reservationId": contents["events"][0]["reservationId"],
        }
        C._atomic_write_json(output, forged)
        store = _FakeStore()
        reservation = C._build_reservation(
            "structure", ["ESU6", "MESU6"], store.series, store.config(),
            bootstrap_samples=1)
        assert C._load_cached_report(
            output, reservation, contents["events"][0], contents["events"]) is None


def test_cli_main_exits_two_on_unavailable_empty_store_without_latest_report():
    with tempfile.TemporaryDirectory() as directory:
        output, ledger = _paths(directory)
        result = subprocess.run([
            sys.executable, C.__file__,
            "--engine", "momentum",
            "--symbols", "ESU6,MESU6",
            "--store", os.path.join(directory, "empty.sqlite3"),
            "--output", output,
            "--ledger", ledger,
            "--bootstrap-samples", "1",
        ], capture_output=True, text=True, timeout=15)
        assert result.returncode == 2
        assert "optimizer research unavailable" in result.stderr
        assert result.stdout == ""
        assert not os.path.exists(output)
        with open(ledger) as handle:
            assert [event["status"] for event in json.load(handle)["events"]] == [
                "reserved", "failed"]


def test_atomic_report_recovery_skips_compute_after_publish_before_completion():
    with tempfile.TemporaryDirectory() as directory:
        output, ledger = _paths(directory)
        store = _FakeStore()
        symbols = ["ESU6", "MESU6"]
        cfg = store.config()
        reservation = C._build_reservation(
            "channel", symbols, store.series, cfg, bootstrap_samples=3)
        reserved, created, _events = C._reserve(ledger, reservation)
        assert created is True
        report = {
            **_report(reserved["priorFamilySize"]),
            "reservationId": reservation["reservationId"],
            "generatedUTC": "2026-07-23T00:00:00Z",
            "researchOnly": True,
            "disclaimer": C.RESEARCH_DISCLAIMER,
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
                "priorFamilySize": reserved["priorFamilySize"],
            },
        }
        prepared_sha = hashlib.sha256(C._json_bytes(report, pretty=True)).hexdigest()
        C._append_report_prepared(ledger, reservation["reservationId"], prepared_sha)
        report_sha = C._atomic_write_json(output, report)
        assert report_sha == prepared_sha

        def must_not_compute(*_args, **_kwargs):
            raise AssertionError("atomically published report should be recovered as cache")

        recovered, cached = C.run_optimizer(
            engine="channel", symbols=symbols, store=store, output_path=output,
            ledger_path=ledger, bootstrap_samples=3, validator=must_not_compute)
        assert cached is True and recovered == report
        with open(ledger) as handle:
            events = json.load(handle)["events"]
        completed = [event for event in events if event["status"] == "completed"]
        assert len(completed) == 1
        assert completed[0]["reportSha256"] == report_sha
        assert completed[0]["recoveredAtomicReport"] is True


def test_uncommitted_matching_json_is_rejected_and_recomputed():
    with tempfile.TemporaryDirectory() as directory:
        output, ledger = _paths(directory)
        store = _FakeStore()
        symbols = ["ESU6", "MESU6"]
        reservation = C._build_reservation(
            "channel", symbols, store.series, store.config(), bootstrap_samples=3)
        reserved, _created, _events = C._reserve(ledger, reservation)
        C._append_failed(ledger, reservation["reservationId"], RuntimeError("prior attempt"))
        forged = {
            **_report(reserved["priorFamilySize"]),
            "reservationId": reservation["reservationId"],
            "researchOnly": True,
            "disclaimer": C.RESEARCH_DISCLAIMER,
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
                "priorFamilySize": reserved["priorFamilySize"],
            },
        }
        C._atomic_write_json(output, forged)  # no reportPrepared digest: not committed
        calls = []

        def validator(_series_by_contract, **kwargs):
            calls.append(kwargs["prior_family_size"])
            return _report(kwargs["prior_family_size"])

        actual, cached = C.run_optimizer(
            engine="channel", symbols=symbols, store=store, output_path=output,
            ledger_path=ledger, bootstrap_samples=3, validator=validator)
        assert cached is False and calls == [reserved["priorFamilySize"]]
        assert actual["generatedUTC"] and actual["reservationId"] == reservation["reservationId"]
        assert actual != forged


def test_concurrent_reservations_use_atomic_append_only_ledger_transactions():
    with tempfile.TemporaryDirectory() as directory:
        _output, ledger = _paths(directory)
        store = _FakeStore()
        cfg = store.config()
        errors = []
        reservations = [
            C._build_reservation(
                "regime", ["ESU6", "MESU6"], store.series, cfg, bootstrap_samples=2,
                source_hashes={"optimizerSha256": f"{index:064x}",
                               "proverSha": "b" * 16, "proverSha256": "b" * 64,
                               "cliSha256": "c" * 64})
            for index in range(8)
        ]

        def reserve(item):
            try:
                C._reserve(ledger, item)
            except BaseException as exc:  # noqa: BLE001
                errors.append(exc)

        threads = [threading.Thread(target=reserve, args=(item,)) for item in reservations]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        assert errors == []
        with open(ledger) as handle:
            contents = json.load(handle)
        reserved = [event for event in contents["events"] if event["status"] == "reserved"]
        assert len(reserved) == 8
        assert len({event["reservationId"] for event in reserved}) == 8
        count = reservations[0]["hypothesisCount"]
        assert sorted(event["priorFamilySize"] for event in reserved) == [
            O.DEFAULT_PRIOR_FAMILY_SIZE + count * index for index in range(8)
        ]
        assert not os.path.exists(ledger + ".lock")


def test_dead_owner_reservation_and_attempt_lock_retry_without_recount_live_owner_blocks():
    with tempfile.TemporaryDirectory() as directory:
        output, ledger = _paths(directory)
        store = _FakeStore()
        symbols = ["ESU6", "MESU6"]
        reservation = C._build_reservation(
            "regime", symbols, store.series, store.config(), bootstrap_samples=2)
        reserved, created, _events = C._reserve(ledger, reservation)
        assert created is True

        # A live owner with no terminal event remains exclusive.
        calls = []
        try:
            C.run_optimizer(
                engine="regime", symbols=symbols, store=store, output_path=output,
                ledger_path=ledger, bootstrap_samples=2,
                validator=lambda *_args, **_kwargs: calls.append(True))
            assert False, "live reservation owner must block a second compute"
        except C.OptimizerCLIError as exc:
            assert "live process" in str(exc)
        assert calls == []

        dead = subprocess.Popen([sys.executable, "-c", "pass"])
        dead.wait(timeout=5)
        with open(ledger) as handle:
            contents = json.load(handle)
        contents["events"][0]["ownerPid"] = dead.pid  # simulate owner killed after reserve
        C._atomic_write_json(ledger, contents)
        attempt_lock = (
            os.path.abspath(ledger) + f".attempt-{reservation['reservationId']}.lock")
        with open(attempt_lock, "w") as handle:
            json.dump({"pid": dead.pid, "nonce": "dead-attempt",
                       "createdEpoch": time.time()}, handle)

        report, cached = C.run_optimizer(
            engine="regime", symbols=symbols, store=store, output_path=output,
            ledger_path=ledger, bootstrap_samples=2,
            validator=lambda _series_by_contract, **kwargs:
                _report(kwargs["prior_family_size"]))
        assert cached is False and report["reservationId"] == reservation["reservationId"]
        assert not os.path.exists(attempt_lock)
        with open(ledger) as handle:
            events = json.load(handle)["events"]
        assert len([event for event in events if event["status"] == "reserved"]) == 1
        assert events[0]["priorFamilySize"] == reserved["priorFamilySize"]


def test_lock_reclaims_dead_owner_and_old_malformed_but_never_live_or_replaced_owner():
    with tempfile.TemporaryDirectory() as directory:
        _output, ledger = _paths(directory)
        lock = ledger + ".lock"

        dead = subprocess.Popen([sys.executable, "-c", "pass"])
        dead.wait(timeout=5)
        assert C._pid_confirmed_dead(dead.pid)
        with open(lock, "w") as handle:
            json.dump({"pid": dead.pid, "nonce": "dead-owner", "createdEpoch": time.time()}, handle)
        with C._exclusive_ledger_lock(ledger, timeout=0.2):
            token, _stat = C._read_lock(lock)
            assert token["pid"] == os.getpid() and token["nonce"] != "dead-owner"
        assert not os.path.exists(lock)

        # A fresh malformed/incomplete create is conservatively left alone.
        with open(lock, "w") as handle:
            handle.write("{")
        try:
            with C._exclusive_ledger_lock(ledger, timeout=0.05):
                assert False, "fresh malformed lock must not be stolen"
        except C.OptimizerCLIError:
            pass
        assert os.path.exists(lock)
        old = time.time() - C.MALFORMED_LOCK_STALE_SECONDS - 5
        os.utime(lock, (old, old))
        with C._exclusive_ledger_lock(ledger, timeout=0.2):
            token, _stat = C._read_lock(lock)
            assert token["pid"] == os.getpid()
        assert not os.path.exists(lock)

        # Replacing our acquired pathname cannot make our finally block unlink the new owner.
        replacement = {"pid": os.getpid(), "nonce": "replacement-owner",
                       "createdEpoch": time.time()}
        with C._exclusive_ledger_lock(ledger, timeout=0.2):
            os.unlink(lock)
            with open(lock, "w") as handle:
                json.dump(replacement, handle)
        with open(lock) as handle:
            assert json.load(handle) == replacement
        os.unlink(lock)


def test_artifact_paths_cannot_alias_store_or_config_directly_or_through_links():
    with tempfile.TemporaryDirectory() as directory:
        store_path = os.path.join(directory, "trading.sqlite3")
        config_path = os.path.join(directory, "config.json")
        S.save_config({**S.CONFIG_DEFAULTS, "lookback": 37}, config_path)
        store = S.Store(store_path, config_path=config_path)
        with open(config_path, "rb") as handle:
            config_before = handle.read()

        cases = [
            (config_path, os.path.join(directory, "ledger-a.json")),
            (os.path.join(directory, "latest-b.json"), store_path),
            (os.path.join(directory, "same.json"), os.path.join(directory, "same.json")),
        ]
        symlink_output = os.path.join(directory, "config-symlink.json")
        os.symlink(config_path, symlink_output)
        cases.append((symlink_output, os.path.join(directory, "ledger-c.json")))
        hardlink_ledger = os.path.join(directory, "config-hardlink.json")
        os.link(config_path, hardlink_ledger)
        cases.append((os.path.join(directory, "latest-d.json"), hardlink_ledger))

        for output, ledger in cases:
            try:
                C.run_optimizer(
                    engine="regime", symbols=["ESU6", "MESU6"], store=store,
                    output_path=output, ledger_path=ledger, bootstrap_samples=1,
                    validator=lambda *_args, **_kwargs:
                        (_ for _ in ()).throw(AssertionError("must reject before compute")))
                assert False, (output, ledger)
            except C.OptimizerCLIError as exc:
                assert "paths" in str(exc) or "overwrite" in str(exc)
        with open(config_path, "rb") as handle:
            assert handle.read() == config_before
        assert os.path.getsize(store_path) > 0


def test_runner_never_mutates_config_file():
    with tempfile.TemporaryDirectory() as directory:
        output, ledger = _paths(directory)
        store_path = os.path.join(directory, "trading.sqlite3")
        config_path = os.path.join(directory, "buyer-config.json")
        S.save_config({**S.CONFIG_DEFAULTS, "lookback": 37}, config_path)
        store = S.Store(store_path, config_path=config_path)
        with open(config_path, "rb") as handle:
            before = handle.read()

        C.run_optimizer(
            engine="regime", symbols=["ESU6", "MESU6"], store=store,
            output_path=output, ledger_path=ledger, bootstrap_samples=1,
            validator=lambda _series_by_contract, **kwargs:
                _report(kwargs["prior_family_size"]))
        with open(config_path, "rb") as handle:
            after = handle.read()
        assert after == before
        assert os.path.isfile(output) and os.path.isfile(ledger)
        assert not any(name.endswith(".tmp") for name in os.listdir(directory))


def test_runner_passes_frozen_config_when_buyer_geometry_is_hostile():
    with tempfile.TemporaryDirectory() as directory:
        output, ledger = _paths(directory)
        hostile_cfg = {
            **S.CONFIG_DEFAULTS,
            "bkMaxHold": 10_000,
            "researchTickSize": 7.0,
        }
        observed = []

        def validator(_series_by_contract, **kwargs):
            observed.append(dict(kwargs["base_cfg"]))
            return _report(kwargs["prior_family_size"])

        report, cached = C.run_optimizer(
            engine="breakout",
            symbols=["ESU6", "MESU6"],
            store=_FakeStore(cfg=hostile_cfg),
            output_path=output,
            ledger_path=ledger,
            bootstrap_samples=1,
            validator=validator,
        )
        effective = O.effective_research_config()
        assert cached is False
        assert observed == [effective]
        assert observed[0]["bkMaxHold"] == 80
        assert observed[0]["researchTickSize"] == 0.25
        protocol = report["hypothesisReservation"]["protocol"]
        assert protocol["effectiveResearchConfig"] == effective
        assert protocol["maxHoldingBars"] == 80
        assert protocol["embargoBars"] >= protocol["maxHoldingBars"]


def test_symbol_parser_accepts_repeated_comma_and_singular_alias_shape():
    assert C._split_symbols(["MESU6, ESU6", "ESU6", "NQU6"]) == [
        "ESU6", "MESU6", "NQU6"]
    try:
        C._validate_request(
            "momentum", ["CM.ESU6", "ESU6"], None, None, bootstrap_samples=1)
        assert False, "two spellings of one normalized contract are not independent inputs"
    except C.OptimizerCLIError as exc:
        assert "distinct normalized" in str(exc)
    try:
        C._validate_request(
            "momentum", [f"S{index}" for index in range(C.MAX_SYMBOLS + 1)],
            None, None, bootstrap_samples=1)
        assert False, "symbol fan-out must be globally bounded"
    except C.OptimizerCLIError as exc:
        assert "at most" in str(exc)


if __name__ == "__main__":
    import sys
    tests = [value for name, value in sorted(globals().items())
             if name.startswith("test_") and callable(value)]
    failed = 0
    for test in tests:
        try:
            test()
            print(f"ok {test.__name__}")
        except Exception as exc:  # noqa: BLE001
            failed += 1
            print(f"FAIL {test.__name__}: {type(exc).__name__}: {exc}")
    print(f"\n{len(tests) - failed} passed, {failed} failed")
    sys.exit(1 if failed else 0)
