"""Black Label Trading — backend data API (SELF-CONTAINED).

The server half of the product. Serves the Trading data over JSON so the sandboxed SwiftUI app
talks to it over the network. It reads the product's OWN local store (a SQLite database the
product owns under ~/Library/Application Support/Black Label Trading) — NOT Michael's Utah
Postgres. The store starts EMPTY; it is filled only by the buyer's own webhook-pushed or captured
trading-platform feed. Every endpoint degrades to an honest JSON payload on a cold store — never a
crash, never a fabricated number.

DECOUPLING: the default store is the own SQLite store (stdlib-only, no Postgres driver, no
utah). The legacy Utah Postgres path is reachable ONLY as an OPT-IN DEV OVERRIDE: set
BLTD_DSN=<postgres dsn> AND have a Postgres driver installed. Without that env, the product is
fully independent of Utah/Postgres.

Endpoints (Bearer token from /auth/signin required on /api/*):
  POST /auth/signin {email,password}      -> {ok, token}
  GET  /api/meta                          -> {online, feedLive, signalsToday}
  GET  /api/symbols                       -> {backtestable, live, liveTicks, busiest}
  GET  /api/bars?symbol=&limit=5000       -> {symbol, bars:[[o,h,l,c,ts_epoch]...]}  (oldest-> for backtest)
  GET  /api/recent?symbol=&limit=90       -> {symbol, bars:[...]}                      (chart history)
  GET  /api/live?symbol=                  -> {symbol, price, ts_epoch} | {gated}
  GET  /api/latest                        -> {fire:{...}|null}
  GET  /api/studies?symbol=&limit=300     -> {symbol, studies:{ema/vwap/rsi/bollinger...}}
  GET  /api/backtest?engine=&symbol=      -> {ok, stats:{...}, curve:[...], reason}
  GET  /api/screen?symbols=&engines=      -> {rows:[{engine,symbol,edge,winRate,netPts...}]}
  GET  /api/gate/rerun?symbols=&engines=  -> {available,prover_sha,sigMinN,alpha,engines:[{engine,status,contracts:[{n,wins,losses,maxDrawdownR,pEdge...}]}], ...}
  GET  /api/backtest/run?engine=&symbol=&start=&end=&folds= -> {available,prover_sha,whole,folds:[{fold,trades,wins,losses,maxDrawdownR,pEdge,insufficient...}]}  (no-code lab)
  GET  /api/backtest/bounds?symbol=       -> {symbol, count, firstTs, lastTs}  (date-range defaults for the lab)
  GET  /api/backtest/farm?engine=&symbol=&start=&end=&workers= -> {available,prover_sha,cellsTried,selectionHits,cells:[{params,trades,wins,losses,maxDrawdownR,pEdgeAdj,selectionHit,insufficient}],best,status}  (TR-19 own-silicon parameter-sweep farm; BH-FDR-corrected screening hits per cell)
  GET  /api/research/optimizer/latest    -> latest completed bounded optimizer report (read-only)
  GET  /api/fires?limit=&symbol=&engine=  -> {fires:[{...}]}   (the signal journal)
  GET  /api/journal?symbol=&engine=       -> {graded, winRate, netPnl, byEngine}
  GET  /api/feed/sources                  -> {sources:[{key,label,kind,credFields,note}], active}
  GET  /api/feed/status                   -> {source, state, detail, symbol, lastTickAge}
  POST /api/feed/connect {source,creds}   -> status (webhook only; API feed posts rejected)
  GET  /api/webhook/info                  -> local webhook URL/header/example for sender setup
  POST /webhook/feed                      -> ingest pushed ticks/bars into the local store
  POST /api/feed/disconnect               -> {state:"disconnected"}

Instrument scope is set by bltd_store.in_scope. Release default is the Topstep ES-family setup so
stale non-ES rows never populate the app. Developers can set BLTD_SCOPE=all for wider parser/feed
tests; signals still fire only where the edge-gate proves an OOS edge per (engine, symbol).

Run:  python3 bltd_api.py 8793
"""
from __future__ import annotations

import hashlib
import json
import os
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import bltd_store
import bltd_analytics
import bltd_alerts   # TR-06 honest edge-gate alert delivery (off by default; buyer-owned endpoint)
import bltd_paths

RUNTIME_CONTRACT = "bltd-signals-only-runtime-v1"
BUILD_ID = str(os.environ.get("BLTD_BUILD") or "dev").strip()[:64] or "dev"
BACKEND_SCRIPT = os.path.realpath(__file__)


def _health_payload() -> dict:
    """Exact runtime identity used by the bundle launcher during safe upgrade takeover."""
    return {
        "ok": True,
        "service": "black-label-trading",
        "build": BUILD_ID,
        "runtimeContract": RUNTIME_CONTRACT,
        "backendScript": BACKEND_SCRIPT,
        "capabilities": {
            "signals": True,
            "execution": False,
            "optimizerCompute": False,
        },
        "ts": time.time(),
        "store": "pg" if USING_PG else "own",
    }

# A real deployment issues per-user tokens; for the local/dev backend any sign-in mints this.
# SECURITY: the app launcher passes only a 0600 token-file path into long-lived processes, never
# the bearer token in argv. Direct tests/dev callers may still use BLTD_TOKEN for compatibility.
def _resolve_token() -> str:
    token_file = os.environ.get("BLTD_TOKEN_FILE")
    if token_file:
        try:
            with open(token_file, encoding="utf-8") as handle:
                token = handle.read(4097).strip()
            if token and len(token) <= 4096:
                return token
        except OSError:
            pass
    t = os.environ.get("BLTD_TOKEN")
    if t:
        return t
    import secrets
    return secrets.token_urlsafe(24)


TOKEN = _resolve_token()

# SECURITY: Host-header allowlist (DNS-rebinding defense). Binding to 127.0.0.1 stops raw
# off-machine TCP, but a malicious page the buyer visits can resolve attacker.com -> 127.0.0.1
# and make the buyer's OWN browser POST to the local backend. We reject any request whose Host
# is not a loopback name, BEFORE auth, so a rebinding page can't reach /auth/signin or any write
# endpoint. Compare on the hostname only (port-agnostic) so the real bound port never has to be
# threaded in.
_LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "::1"}


def _host_allowed(host_header: str) -> bool:
    h = (host_header or "").strip()
    if not h:
        return False                          # HTTP/1.1 requires Host; absent => reject
    if h.startswith("["):                     # [::1] or [::1]:port
        host = h[1:h.index("]")] if "]" in h else h[1:]
    elif h.count(":") == 1:                   # host:port (IPv4 / hostname)
        host = h.rsplit(":", 1)[0]
    else:
        host = h                              # bare hostname OR bare IPv6 literal (e.g. ::1)
    return host.lower() in _LOOPBACK_HOSTS


def _heartbeat_fresh(mtime, now, max_age=30.0) -> bool:
    """True iff a heartbeat file's mtime exists and is newer than max_age. Pure (unit-tested)."""
    return mtime is not None and (now - mtime) < max_age


# ---------------------------------------------------------------------------
# REFERENCE OOS artifact (served at GET /api/reference).
# This is Black Label's edge-gate verdicts computed on our OWN historical ES bars by the shipped
# provers (see backend/gen_reference.py). It ships as a small static JSON so a cold buyer — who has
# captured no bars of their own yet — can see the gate produce a real, earned verdict BEFORE weeks
# of their own capture. It is REFERENCE ONLY: historical ES, NOT the buyer's account, NOT a promise,
# no aggregate win-rate / equity curve / "verified-live edge" claim. When an engine has no edge it
# says "no edge". It is read-only, contains NO buyer data, and does not touch the store.
_REFERENCE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "reference_oos.json")
_reference_cache = {"mtime": None, "payload": None}
_OPTIMIZER_REPORT_MAX_BYTES = 64 * 1024 * 1024
_OPTIMIZER_RESERVATION_KIND = "bltd_optimizer_reservation_v1"
_OPTIMIZER_PROTOCOL_KIND = "bltd_bounded_nested_validation_v1"
_OPTIMIZER_DISCLAIMER = (
    "Research only — this report is not adopted, is not eligible for live use, and never changes "
    "the buyer's configuration. Separate forward evidence and an explicit release process are "
    "required before any parameter could be considered."
)
_OPTIMIZER_REPORT_FIELDS = {
    "kind", "available", "label", "contracts", "engines", "costBandsPoints", "outerFolds",
    "embargoBars", "priorFamilySize", "provenance", "folds", "researchCandidates",
    "eligibleForLive", "adopted", "reason", "familyTestsThisRun", "familyTestsCumulative",
    "reservationId", "generatedUTC", "researchOnly", "disclaimer", "hypothesisReservation",
}


def _load_reference() -> dict:
    """Return the bundled reference artifact, or an honest empty/pending state if it is absent.
    Never fabricates a verdict: a missing artifact yields available:false with a reason, which the
    Swift panel surfaces as a "pending" empty state rather than a painted number."""
    try:
        mt = os.path.getmtime(_REFERENCE_PATH)
    except OSError:
        return {"available": False,
                "reason": "reference verdicts not bundled in this build",
                "label": ("Reference only — computed on historical ES data, NOT your account, "
                          "NOT a promise, no performance guaranteed.")}
    if _reference_cache["mtime"] != mt:
        try:
            with open(_REFERENCE_PATH) as f:
                data = json.load(f)
            data["available"] = True
            _reference_cache.update(mtime=mt, payload=data)
        except Exception as e:  # noqa: BLE001 — a corrupt artifact must never be served as truth
            return {"available": False, "reason": f"reference artifact unreadable: {type(e).__name__}",
                    "label": ("Reference only — computed on historical ES data, NOT your account, "
                              "NOT a promise, no performance guaranteed.")}
    return _reference_cache["payload"]


def _optimizer_report_unavailable(reason: str) -> dict:
    return {
        "kind": "nested_strategy_validation",
        "available": False,
        "researchOnly": True,
        "eligibleForLive": False,
        "adopted": False,
        "researchCandidates": [],
        "reason": reason,
        "label": ("Research only — no completed bounded optimizer report is available. "
                  "This endpoint never computes research or changes configuration."),
    }


def _optimizer_hash(value) -> str:
    raw = json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
        allow_nan=False).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()


def _optimizer_sha256(value) -> bool:
    return (isinstance(value, str) and len(value) == 64
            and all(char in "0123456789abcdef" for char in value.lower()))


def _optimizer_report_trusted(report) -> bool:
    if not isinstance(report, dict):
        return False
    if set(report) - _OPTIMIZER_REPORT_FIELDS:
        return False
    provenance = report.get("provenance")
    binding = report.get("hypothesisReservation")
    if not isinstance(provenance, dict) or not isinstance(binding, dict):
        return False
    if (report.get("kind") != "nested_strategy_validation"
            or report.get("available") is not True
            or report.get("researchOnly") is not True
            or report.get("eligibleForLive") is not False
            or report.get("adopted") is not False
            or report.get("disclaimer") != _OPTIMIZER_DISCLAIMER
            or not isinstance(report.get("label"), str)
            or "research only" not in report["label"].lower()
            or not isinstance(report.get("reason"), str)
            or not isinstance(report.get("researchCandidates"), list)
            or not isinstance(report.get("folds"), list)
            or not isinstance(report.get("generatedUTC"), str)):
        return False

    engine = binding.get("engine")
    symbols = binding.get("symbols")
    inputs = binding.get("inputHashes")
    protocol = binding.get("protocol")
    sources = binding.get("sourceHashes")
    if (not isinstance(engine, str) or not engine
            or not isinstance(symbols, list) or not 2 <= len(symbols) <= 8
            or any(not isinstance(symbol, str) or not symbol for symbol in symbols)
            or symbols != sorted(set(symbols))
            or not isinstance(inputs, dict) or set(inputs) != set(symbols)
            or not isinstance(protocol, dict)
            or protocol.get("kind") != _OPTIMIZER_PROTOCOL_KIND
            or not isinstance(sources, dict)):
        return False
    for symbol in symbols:
        item = inputs.get(symbol)
        if (not isinstance(item, dict)
                or isinstance(item.get("bars"), bool)
                or not isinstance(item.get("bars"), int)
                or not 0 <= item["bars"] <= 30_000
                or not _optimizer_sha256(item.get("sha256"))):
            return False
    for name in ("optimizerSha256", "proverSha256", "cliSha256"):
        if not _optimizer_sha256(sources.get(name)):
            return False
    protocol_hash = binding.get("protocolHash")
    source_hash = binding.get("sourceHash")
    grid_hash = binding.get("gridSha256")
    hypothesis_count = binding.get("hypothesisCount")
    prior_family = binding.get("priorFamilySize")
    if (protocol_hash != _optimizer_hash(protocol)
            or source_hash != _optimizer_hash(sources)
            or not _optimizer_sha256(grid_hash)
            or isinstance(hypothesis_count, bool) or not isinstance(hypothesis_count, int)
            or hypothesis_count <= 0
            or isinstance(prior_family, bool) or not isinstance(prior_family, int)
            or prior_family < 350):
        return False
    identity = {
        "kind": _OPTIMIZER_RESERVATION_KIND,
        "engine": engine,
        "symbols": symbols,
        "inputHashes": inputs,
        "protocolHash": protocol_hash,
        "gridSha256": grid_hash,
        "sourceHash": source_hash,
    }
    if report.get("reservationId") != _optimizer_hash(identity):
        return False
    if (provenance.get("inputs") != inputs
            or provenance.get("engines") != [engine]
            or provenance.get("contracts") != symbols
            or provenance.get("gridSha256") != grid_hash
            or provenance.get("optimizerSha256") != sources["optimizerSha256"]
            or provenance.get("proverSha256") != sources["proverSha256"]
            or provenance.get("configSha256") != protocol.get("configSha256")
            or not _optimizer_sha256(provenance.get("runId"))):
        return False
    for report_key, protocol_key in (
            ("costBandsPoints", "costBandsPoints"),
            ("outerFolds", "outerFolds"),
            ("embargoBars", "embargoBars"),
            ("priorFamilySize", None)):
        expected = prior_family if protocol_key is None else protocol.get(protocol_key)
        if report.get(report_key) != expected:
            return False
    return True


def _load_optimizer_report() -> dict:
    """Read the CLI's one atomically published report; never compute, adopt, or write."""
    try:
        with open(bltd_paths.optimizer_report_path(), "rb") as handle:
            if os.fstat(handle.fileno()).st_size > _OPTIMIZER_REPORT_MAX_BYTES:
                raise ValueError("optimizer report exceeds bounded size")
            report = json.load(handle)
    except FileNotFoundError:
        return _optimizer_report_unavailable(
            "no completed optimizer research report is available")
    except (OSError, ValueError, TypeError, RecursionError, MemoryError):
        return _optimizer_report_unavailable(
            "the completed optimizer research report is unavailable or invalid")
    try:
        trusted = _optimizer_report_trusted(report)
    except (ValueError, TypeError, RecursionError, MemoryError):
        trusted = False
    if not trusted:
        return _optimizer_report_unavailable(
            "the completed optimizer research report is unavailable or invalid")
    return {key: report[key] for key in _OPTIMIZER_REPORT_FIELDS if key in report}


# --- store selection ------------------------------------------------------
# Default: the product's OWN SQLite store. The Utah Postgres DSN is an OPT-IN dev override only:
# it is used iff BLTD_DSN is set AND a Postgres driver is importable. Anything missing falls back
# to the own store, so a buyer machine with no Postgres still runs fully.
USING_PG = False
_DSN = os.environ.get("BLTD_DSN")


def _build_store():
    global USING_PG
    if _DSN:
        try:
            import bltd_pg  # noqa: F401 — thin optional Postgres adapter (dev only)
            store = bltd_pg.PgStore(_DSN)
            USING_PG = True
            return store
        except Exception as exc:  # noqa: BLE001 — no driver / unreachable -> own store
            print(f"BLTD_DSN set but Postgres unavailable ({exc}); using own SQLite store",
                  file=sys.stderr, flush=True)
    return bltd_store.Store(bltd_store.default_store_path())


STORE = _build_store()


# --- No-creds webhook feed manager ----------------------------------------------------------
# The surfaced data-ingestion source is webhook ingestion (POST /webhook/feed). FeedManager's
# catalogue exists so the Swift UI can ask the backend what source to show, but direct API-backed
# feed posts are rejected.
_FEED_MANAGER = None
_FEED_LOCK = threading.Lock()
_WEBHOOK_CAPTURE = None
_WEBHOOK_LOCK = threading.Lock()
_LAST_WEBHOOK_SOURCE = None


def feed_manager():
    global _FEED_MANAGER
    if _FEED_MANAGER is None:
        with _FEED_LOCK:
            if _FEED_MANAGER is None:
                import bltd_feeds
                _FEED_MANAGER = bltd_feeds.FeedManager(STORE)
    return _FEED_MANAGER


def _feed_manager_if_exists():
    return _FEED_MANAGER


def _webhook_capture():
    """Shared in-process capture normalizer for inbound webhook ticks."""
    global _WEBHOOK_CAPTURE
    if _WEBHOOK_CAPTURE is None:
        with _WEBHOOK_LOCK:
            if _WEBHOOK_CAPTURE is None:
                import bltd_capture
                _WEBHOOK_CAPTURE = bltd_capture.Capture(STORE)
    return _WEBHOOK_CAPTURE


# --- Connect handshake ----------------------------------------------------
# The Swift "Connect" screen calls these so the product (not the OS browser) owns a remote-debug
# browser profile:
#   POST /api/connect  -> open supported trading-platform login tabs in the product Chrome profile
#                         and report whether ANY logged-in feed page is reachable on CDP.
#   GET  /api/capture  -> live capture status (chrome up? any trading page logged in? feed flowing?)
#                         so the UI reflects REAL capture state, never a fabricated "connected".
def _connect(body=None) -> dict:
    """Launch/open the product-owned debug Chrome on browser trading-platform sign-ins.

    This is the no-API prop-account path: the buyer logs into the platform website, and the capture
    daemon reads real market-data WebSocket frames from that browser session. Honest — never claims
    connected when no logged-in feed page is present."""
    try:
        import bltd_capture as cap
        source = cap.normalize_browser_source((body or {}).get("source") if isinstance(body, dict) else None)
        # RC4: browser capture needs a Chromium browser. If none is installed, don't loop silently —
        # surface an honest prerequisite the app shows instead of a fabricated "connected".
        chrome_ok = cap.chrome_present()
        if not chrome_ok:
            cap.write_chrome_prereq()
            return {"ok": False, "chromePresent": False,
                    "chromeReason": "Google Chrome is required for browser capture.",
                    "chromeDetail": "Black Label Trading reads the live data feeding your platform's "
                                    "charts through a Chromium browser. Install Google Chrome (or "
                                    "Chromium, Brave, or Edge), then reopen and connect your platform.",
                    "source": source, "cdpReachable": False, "feedAvailable": False, "feedPages": [],
                    "cdpPort": cap.CDP_PORT}
        already = bool(cap.discover_feed_pages(source))
        if not already:
            cap.open_feed_login_tabs(source)
        pages = cap.discover_feed_pages(source)
        return {"ok": True, "source": source, "chromePresent": True, "launched": not already,
                "cdpReachable": cap.cdp_reachable(), "feedAvailable": bool(pages),
                "feedPages": [name for name, _ in pages], "cdpPort": cap.CDP_PORT}
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": f"{type(exc).__name__}: {exc}"}


def _capture_status() -> dict:
    """Real capture status for the UI: is any buyer trading-platform feed reachable on CDP, and is
    the own store currently receiving live ticks?"""
    feed = cdp = False
    browser_source = None
    try:
        import bltd_capture as cap
        cdp = cap.cdp_reachable()
        pages = cap.discover_feed_pages()
        feed = bool(pages)
        browser_source = pages[0][0] if pages else None
    except Exception:  # noqa: BLE001
        pass
    syms = STORE.symbols()
    feed_live = STORE.meta().get("feedLive", False)
    webhook_recent = bool(syms.get("liveTicks") or syms.get("live"))
    if webhook_recent:
        source = _LAST_WEBHOOK_SOURCE or "webhook"
        source_state = "webhook"
        feed = True
        feed_live = bool(feed_live or syms.get("liveTicks"))
    else:
        source = browser_source
        source_state = "browser" if browser_source else None
    # Fold in a connected managed feed if one exists; no broker/API feed is surfaced.
    # feedAvailable/feedLive are about whether REAL ticks can/are flowing, not which source produced
    # them. Only reads an already-created manager (never spins one up on a poll).
    mgr = _feed_manager_if_exists()
    if mgr is not None and not webhook_recent:
        try:
            fs = mgr.status()
            source, source_state = fs.get("source"), fs.get("state")
            if source_state in ("live", "idle", "connecting", "authenticating"):
                feed = True
            if source_state == "live":
                feed_live = True
        except Exception:  # noqa: BLE001
            pass
    return {"cdpReachable": cdp or bool(source), "feedAvailable": feed,
            "liveTicks": syms.get("liveTicks", []), "feedLive": feed_live,
            "feedSource": source, "feedState": source_state,
            "evaluatorAlive": _evaluator_alive()}


def _webhook_epoch(value):
    if value is None:
        return int(time.time())
    if isinstance(value, (int, float)) and value == value:
        e = float(value)
        if e > 1e12:
            e /= 1000.0
        if 1_000_000_000 <= e <= 4_000_000_000:
            return int(e)
        return int(time.time())
    if isinstance(value, str):
        s = value.strip()
        try:
            return _webhook_epoch(float(s))
        except ValueError:
            pass
        try:
            dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return int(dt.timestamp())
        except ValueError:
            return int(time.time())
    return int(time.time())


def _webhook_float(value):
    try:
        f = float(value)
    except (TypeError, ValueError):
        return None
    return f if f == f and f not in (float("inf"), float("-inf")) else None


def _webhook_symbol(obj, default_symbol=None):
    if isinstance(obj, dict):
        for k in ("symbol", "ticker", "contract", "instrument", "s"):
            v = obj.get(k)
            if isinstance(v, str) and v.strip():
                return v.strip()
    return default_symbol


def _iter_webhook_items(body, default_symbol=None, bucket=None):
    if isinstance(body, list):
        if body and not any(isinstance(x, (dict, list, tuple)) for x in body):
            yield body, default_symbol, bucket
            return
        for item in body:
            yield from _iter_webhook_items(item, default_symbol, bucket)
        return
    if not isinstance(body, dict):
        yield body, default_symbol, bucket
        return
    symbol = _webhook_symbol(body, default_symbol)
    emitted = False
    for name in ("ticks", "bars", "candles", "data"):
        val = body.get(name)
        if isinstance(val, list):
            emitted = True
            for item in val:
                yield from _iter_webhook_items(item, symbol, name)
    if not emitted:
        yield body, symbol, bucket


def _webhook_item_dict(item, default_symbol=None):
    if isinstance(item, dict):
        return dict(item)
    if isinstance(item, (list, tuple)):
        if item and isinstance(item[0], str):
            # [symbol, open, high, low, close, ts] or [symbol, price, ts]
            if len(item) >= 6:
                return {"symbol": item[0], "open": item[1], "high": item[2], "low": item[3],
                        "close": item[4], "epoch": item[5]}
            if len(item) >= 3:
                return {"symbol": item[0], "price": item[1], "epoch": item[2]}
        if default_symbol and len(item) >= 5:
            # [open, high, low, close, ts]
            return {"symbol": default_symbol, "open": item[0], "high": item[1], "low": item[2],
                    "close": item[3], "epoch": item[4]}
        if default_symbol and len(item) >= 2:
            return {"symbol": default_symbol, "price": item[0], "epoch": item[1]}
    return {}


def _webhook_ingest(body: dict) -> dict:
    """Ingest pushed market data. This is the no-creds prop-account integration path.

    Accepts dict/list payloads with ticks, bars, candles, or one top-level item. Examples:
      {"symbol":"ESU6","price":6123.25,"ts":1782537730}
      {"symbol":"ESU6","bars":[[6120,6125,6118,6123.25,1782537730]]}
      {"ticks":[{"symbol":"ESU6","last":5240.5,"timestamp":"2026-06-30T14:00:00Z"}]}
    """
    import bltd_feeds

    global _LAST_WEBHOOK_SOURCE
    cap = _webhook_capture()
    _LAST_WEBHOOK_SOURCE = "webhook"
    bar_rows = {}
    ticks = 0
    bars = 0
    rejected = 0
    symbols = set()
    for raw, default_symbol, bucket in _iter_webhook_items(body):
        item = _webhook_item_dict(raw, default_symbol)
        symbol = _webhook_symbol(item, default_symbol)
        raw_source = item.get("source") if isinstance(item, dict) else None
        if isinstance(raw_source, str) and raw_source.strip():
            _LAST_WEBHOOK_SOURCE = raw_source.strip()
        close = (item.get("close", item.get("c", item.get("price", item.get("last"))))
                 if isinstance(item, dict) else None)
        epoch = _webhook_epoch(item.get("epoch", item.get("ts", item.get("timestamp", item.get("time"))))
                               if isinstance(item, dict) else None)
        volume = item.get("volume", item.get("vol", item.get("v"))) if isinstance(item, dict) else None
        delta = item.get("delta", item.get("d", item.get("orderFlowDelta"))) if isinstance(item, dict) else None
        cd = bltd_feeds.make_candle(symbol, close, open=item.get("open", item.get("o")),
                                    high=item.get("high", item.get("h")),
                                    low=item.get("low", item.get("l")), epoch=epoch,
                                    volume=volume, delta=delta)
        if not cd:
            rejected += 1
            continue
        prev_close = getattr(cap, "last_close", {}).get(cd["symbol"])
        vol = float(cd.get("volume") or 0.0)
        dlt = float(cd.get("delta") or 0.0)
        if vol > 0 and dlt == 0.0 and prev_close is not None and cd["close"] != prev_close:
            cd["delta"] = vol if cd["close"] > prev_close else -vol
        symbols.add(cd["symbol"])
        cap.on_candle(cd, arrival=epoch)
        ticks += 1
        o = _webhook_float(item.get("open", item.get("o")))
        h = _webhook_float(item.get("high", item.get("h")))
        l = _webhook_float(item.get("low", item.get("l")))
        c = _webhook_float(cd["close"])
        # Explicit bar/candle payloads should land as bars immediately; tick-only payloads still
        # roll into bars over time through Capture.on_candle.
        if bucket in ("bars", "candles") or all(v is not None for v in (o, h, l)):
            o = c if o is None else o
            h = max(v for v in (c, o, h) if v is not None)
            l = min(v for v in (c, o, l) if v is not None)
            bar_rows.setdefault(cd["symbol"], []).append(
                (epoch, o, h, l, c, cd.get("volume", 0.0), cd.get("delta", 0.0)))
            bars += 1
    cap.flush()
    stored_bars = STORE.record_bars_batch(bar_rows) if bar_rows else 0
    if stored_bars < 0:
        stored_bars = 0
    return {"ok": ticks > 0 or bars > 0, "source": "webhook",
            "ticks": ticks, "bars": stored_bars, "rejected": rejected,
            "symbols": sorted(symbols)}


def _webhook_authorized(handler, parsed_url) -> bool:
    qs = parse_qs(parsed_url.query)
    supplied = ((handler.headers.get("Authorization", "").removeprefix("Bearer ").strip())
                or handler.headers.get("X-BLTD-Webhook-Token", "").strip()
                or (qs.get("token", [""])[0] or "").strip())
    return supplied == TOKEN


def _webhook_info(host_header: str) -> dict:
    host = (host_header or f"127.0.0.1:{os.environ.get('BLTD_PORT', '8793')}").strip()
    endpoint = f"http://{host}/webhook/feed"
    example = {"symbol": "ESU6", "price": 6123.25, "ts": int(time.time())}
    return {"source": "webhook", "endpoint": endpoint,
            "header": f"Authorization: Bearer {TOKEN}",
            "curl": f"curl -X POST {endpoint} -H 'Authorization: Bearer {TOKEN}' "
                    f"-H 'Content-Type: application/json' -d '{json.dumps(example)}'",
            "example": example}


def _evaluator_alive() -> bool:
    """Honest cross-process liveness: the evaluator runs in the SEPARATE capture daemon, bridged to
    this API process ONLY by the shared store file. The daemon touches a heartbeat next to the store
    every evaluator cycle (~8s); if it's stale/missing the evaluator is down and an API-feed buyer
    would get bars-but-no-fires — so the UI must surface that, never fake 'live'."""
    path = getattr(STORE, "path", None)
    if not path:
        return False                          # Postgres dev override has no local heartbeat
    try:
        import bltd_capture as cap
        return _heartbeat_fresh(os.path.getmtime(cap.evaluator_heartbeat_path(path)), time.time())
    except OSError:
        return False                          # no heartbeat file yet => evaluator not running
    except Exception:  # noqa: BLE001
        return False


class Server(ThreadingHTTPServer):
    # let a fresh backend re-bind the port immediately after a restart (no TIME_WAIT stall)
    allow_reuse_address = True
    daemon_threads = True


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        b = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        try:
            self.wfile.write(b)
        except BrokenPipeError:
            pass

    def _authed(self) -> bool:
        return self.headers.get("Authorization", "") == f"Bearer {TOKEN}"

    def do_POST(self):
        if not _host_allowed(self.headers.get("Host", "")):
            return self._send(403, {"error": "forbidden"})   # DNS-rebinding defense, before auth
        u = urlparse(self.path)
        n = int(self.headers.get("Content-Length", 0) or 0)
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except Exception:  # noqa: BLE001
            body = {}
        if u.path == "/auth/signin":
            if (body.get("email") or "").strip() and (body.get("password") or "").strip():
                return self._send(200, {"ok": True, "token": TOKEN})
            return self._send(401, {"ok": False, "error": "email and password required"})
        if u.path in ("/webhook/feed", "/api/webhook/feed"):
            if not (self._authed() or _webhook_authorized(self, u)):
                return self._send(401, {"error": "unauthorized"})
            return self._send(200, _webhook_ingest(body if isinstance(body, (dict, list)) else {}))
        if u.path == "/api/config":
            if not self._authed():
                return self._send(401, {"error": "unauthorized"})
            return self._send(200, {"config": STORE.set_config(body if isinstance(body, dict) else {})})
        if u.path == "/api/connect":
            if not self._authed():
                return self._send(401, {"error": "unauthorized"})
            return self._send(200, _connect(body if isinstance(body, dict) else {}))
        if u.path == "/api/feed/connect":
            if not self._authed():
                return self._send(401, {"error": "unauthorized"})
            # body: {"source": "webhook"}. FeedManager rejects API-backed source names; webhook
            # ingestion uses pushed market data instead of prop-firm API credentials.
            source = (body.get("source") or "").strip() if isinstance(body, dict) else ""
            creds = body.get("creds") if isinstance(body, dict) and isinstance(body.get("creds"), dict) else {}
            try:
                return self._send(200, feed_manager().connect(source, creds))
            except Exception as exc:  # noqa: BLE001 — never leak creds; report type only
                return self._send(200, {"source": source, "state": "error",
                                        "detail": f"{type(exc).__name__}"})
        if u.path == "/api/feed/disconnect":
            if not self._authed():
                return self._send(401, {"error": "unauthorized"})
            mgr = _feed_manager_if_exists()
            return self._send(200, mgr.disconnect() if mgr else {"state": "disconnected"})
        # TR-06 honest alert: post the edge-gate verdict (incl. "no edge") to the buyer's OWN
        # endpoint. OFF/no-endpoint => zero egress (bltd_alerts guards before any socket). This path
        # can NEVER place an order — the shipping backend has no order control plane.
        if u.path == "/api/alerts/test":
            if not self._authed():
                return self._send(401, {"error": "unauthorized"})
            return self._send(200, bltd_alerts.test_send(STORE))
        if u.path == "/api/alerts/send":
            if not self._authed():
                return self._send(401, {"error": "unauthorized"})
            b = body if isinstance(body, dict) else {}
            syms = b.get("symbols") if isinstance(b.get("symbols"), list) else None
            engs = b.get("engines") if isinstance(b.get("engines"), list) else None
            return self._send(200, bltd_alerts.send_gate_alert(STORE, syms, engs))
        self._send(404, {"error": "not found"})

    def do_GET(self):
        if not _host_allowed(self.headers.get("Host", "")):
            return self._send(403, {"error": "forbidden"})   # DNS-rebinding defense, before auth
        u = urlparse(self.path)
        q = parse_qs(u.query)
        g = lambda k, d="": (q.get(k, [d])[0] or d)  # noqa: E731
        if u.path == "/health":
            return self._send(200, _health_payload())
        if not u.path.startswith("/api/"):
            return self._send(404, {"error": "not found"})
        if not self._authed():
            return self._send(401, {"error": "unauthorized"})
        # Reference OOS verdicts (Black Label's own ES history, no buyer data) render in the app as an
        # EARNED edge-gate verdict ("no edge" / candidate). They were once served BEFORE this auth
        # gate as "public research", which let a cold, UNAUTHENTICATED GET on the local API scrape a signed
        # verdict the server cannot attribute to a buyer session — a fail-open (trading-analyst
        # 2026-07-23). FAIL CLOSED: the reference artifact requires the same per-launch Bearer token
        # as every other /api/* read. The app already holds that token before its reference screen
        # loads (FeedClient.connect() runs first), so no honest pre-signin surface is lost.
        if u.path == "/api/reference":
            return self._send(200, _load_reference())
        try:
            if u.path == "/api/research/optimizer/latest":
                return self._send(200, _load_optimizer_report())
            if u.path == "/api/meta":
                return self._send(200, STORE.meta())
            if u.path == "/api/symbols":
                return self._send(200, STORE.symbols())
            if u.path == "/api/instruments":
                # First-class multi-asset catalog over the buyer's OWN captured bars (TR-05): every
                # instrument classified + per-instrument (never pooled). Honest onlyES state when thin.
                return self._send(200, bltd_analytics.instruments(STORE, STORE.config()))
            if u.path == "/api/bars":
                return self._send(200, STORE.bars(g("symbol"), int(g("limit", "5000")), newest=False))
            if u.path == "/api/recent":
                return self._send(200, STORE.bars(g("symbol"), int(g("limit", "90")), newest=True))
            if u.path == "/api/live":
                return self._send(200, STORE.live_price(g("symbol")))
            if u.path == "/api/latest":
                return self._send(200, STORE.latest_fire())
            if u.path == "/api/config":
                return self._send(200, {"config": STORE.config()})
            if u.path == "/api/capture":
                return self._send(200, _capture_status())
            if u.path == "/api/feed/sources":
                return self._send(200, feed_manager().sources())
            if u.path == "/api/feed/status":
                return self._send(200, feed_manager().status())
            if u.path == "/api/webhook/info":
                return self._send(200, _webhook_info(self.headers.get("Host", "")))
            if u.path == "/api/studies":
                sym = g("symbol")
                ohlc = STORE.ohlc(sym, int(g("limit", "300")))
                return self._send(200, {"symbol": sym, "studies": bltd_analytics.studies(ohlc, STORE.config())})
            if u.path == "/api/backtest":
                engine = g("engine", "meanrev")
                sym = g("symbol")
                if not bltd_store.in_scope(sym):
                    return self._send(200, {"ok": False, "engine": engine,
                                            "reason": f"'{sym}' is not a recognized instrument",
                                            "stats": bltd_analytics._stats([]), "curve": [], "enoughBars": False})
                ohlc = STORE.ohlc(sym)
                return self._send(200, bltd_analytics.full_backtest(engine, ohlc, STORE.config()))
            if u.path == "/api/screen":
                cfg = STORE.config()
                requested_syms = [s for s in g("symbols").split(",") if s]
                syms = bltd_store.scoped_symbols(requested_syms) if requested_syms else STORE.symbols().get("backtestable", [])
                engs = [e for e in g("engines").split(",") if e] or cfg.get("engines", [])
                return self._send(200, {"rows": bltd_analytics.screen(STORE, syms, engs, cfg)})
            if u.path == "/api/gate/rerun":
                # Buyer-triggered one-click re-run of the SHIPPED edge-gate over their OWN captured
                # bars — full n/W/L/drawdown/p-value per (engine, contract) + prover_sha. Every scoped
                # symbol × every engine (no cherry-picking); honest 'insufficient' under SIG_MIN_N.
                cfg = STORE.config()
                requested_syms = [s for s in g("symbols").split(",") if s]
                syms = bltd_store.scoped_symbols(requested_syms) if requested_syms else STORE.symbols().get("backtestable", [])
                engs = [e for e in g("engines").split(",") if e] or cfg.get("engines", [])
                report = bltd_analytics.gate_rerun(STORE, syms, engs, cfg)
                report["generatedUTC"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                return self._send(200, report)
            if u.path == "/api/backtest/run":
                # No-code backtest lab: run the SHIPPED prover on ONE (engine, symbol) over the buyer's
                # OWN captured bars, optionally date-scoped, split into contiguous folds. Per-fold
                # n/W/L/max-drawdown-R/p + prover_sha. No aggregate win-rate/$ figure (§5.1).
                def _int(name):
                    raw = g(name, "")
                    try:
                        return int(raw) if raw != "" else None
                    except ValueError:
                        return None
                engine = g("engine", "meanrev")
                sym = g("symbol")
                report = bltd_analytics.backtest_lab(STORE, engine, sym,
                                                     start_ts=_int("start"), end_ts=_int("end"),
                                                     folds=int(g("folds", "1") or 1), cfg=STORE.config())
                report["generatedUTC"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                return self._send(200, report)
            if u.path == "/api/backtest/farm":
                # TR-19 own-silicon parameter-sweep FARM: fan the SHIPPED prover's hyperparameter
                # grid across this Mac's cores over the buyer's OWN bars. Per-cell n/W/L/DD + a
                # BH-FDR-corrected p across the whole grid (NEVER a raw best-cell p) + prover_sha.
                # No cloud, no data fee, no aggregate win-rate/$ figure (§5.1/§5.7).
                def _int(name):
                    raw = g(name, "")
                    try:
                        return int(raw) if raw != "" else None
                    except ValueError:
                        return None
                engine = g("engine", "meanrev")
                sym = g("symbol")
                wk = g("workers", "")
                report = bltd_analytics.backtest_farm(
                    STORE, engine, sym, start_ts=_int("start"), end_ts=_int("end"),
                    workers=(int(wk) if wk.isdigit() else None), cfg=STORE.config())
                report["generatedUTC"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                return self._send(200, report)
            if u.path == "/api/backtest/bounds":
                # First/last captured epoch + bar count for a symbol — so the lab can default the
                # date range to the real span of the buyer's own data.
                return self._send(200, STORE.bar_bounds(g("symbol")))
            if u.path == "/api/fires":
                return self._send(200, STORE.fires(int(g("limit", "200")),
                                                   g("symbol") or None, g("engine") or None))
            if u.path == "/api/journal":
                return self._send(200, STORE.journal_stats(g("symbol") or None, g("engine") or None))
            if u.path == "/api/alerts/status":
                # Token-free view of the TR-06 alert config for the settings UI (no Pushover
                # token/user, no raw endpoint query is ever returned).
                return self._send(200, bltd_alerts.status(STORE))
        except Exception as exc:  # noqa: BLE001
            return self._send(200, {"error": f"{type(exc).__name__}: {exc}"})
        self._send(404, {"error": "unknown endpoint"})


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8793
    where = f"Postgres DSN (dev override)" if USING_PG else f"own store {STORE.path}"
    print(f"Black Label Trading API on http://127.0.0.1:{port}/  (data: {where})", flush=True)
    Server(("127.0.0.1", port), H).serve_forever()


if __name__ == "__main__":
    main()
