"""Black Label Trading — API security + liveness tests (stdlib-only, OFFLINE).

The data path is no-creds webhook ingestion: a trader's sender/bridge posts observed market data
into the local backend, which serves only what was pushed/captured. These tests harden the internal
API the app uses and keep its status honest:
  * Host-header allowlist (DNS-rebinding defense) gates EVERY endpoint, before auth.
  * The backend mints a RANDOM per-launch token (no publicly-known constant).
  * Webhook writes are localhost + token gated, then land as real ticks/bars.
  * Evaluator-liveness freshness helper (the honest "evaluator offline" signal).

Sets BLTD_STORE/BLTD_TOKEN BEFORE importing bltd_api so the module-global STORE/TOKEN
bind to a temp file + a known token. Talks ONLY to a loopback test server — no broker,
no external network.
"""
from __future__ import annotations

import http.client
import json
import os
import tempfile
import threading
import time

os.environ["BLTD_STORE"] = os.path.join(tempfile.mkdtemp(), "t.sqlite3")
os.environ["BLTD_TOKEN"] = "test-token-xyz"          # deterministic Bearer for the suite

import bltd_api as A            # noqa: E402 — env must be set first
import bltd_capture as C        # noqa: E402
import bltd_optimizer_cli as OC  # noqa: E402
import bltd_store as S          # noqa: E402

TOK = "test-token-xyz"


def _optimizer_report_fixture(run_id=None):
    symbols = ["ESU6", "MESU6"]
    series = {
        "ESU6": [(100.0, 101.0, 99.0, 100.0, 1)],
        "MESU6": [(200.0, 201.0, 199.0, 200.0, 2)],
    }
    cfg = {**S.CONFIG_DEFAULTS, "engines": list(S.ACTIVE_ENGINE_FAMILY)}
    reservation = OC._build_reservation(
        "momentum", symbols, series, cfg, bootstrap_samples=1)
    protocol = reservation["protocol"]
    sources = reservation["sourceHashes"]
    prior = 350
    binding = {
        "engine": reservation["engine"],
        "symbols": reservation["symbols"],
        "inputHashes": reservation["inputHashes"],
        "protocol": protocol,
        "protocolHash": reservation["protocolHash"],
        "gridSha256": reservation["gridSha256"],
        "sourceHashes": sources,
        "sourceHash": reservation["sourceHash"],
        "hypothesisCount": reservation["hypothesisCount"],
        "priorFamilySize": prior,
    }
    return {
        "kind": "nested_strategy_validation",
        "available": True,
        "researchOnly": True,
        "reservationId": reservation["reservationId"],
        "generatedUTC": "2026-07-23T12:00:00Z",
        "provenance": {
            "runId": run_id or ("e" * 64),
            "engines": ["momentum"],
            "contracts": symbols,
            "inputs": reservation["inputHashes"],
            "gridSha256": reservation["gridSha256"],
            "optimizerSha256": sources["optimizerSha256"],
            "proverSha256": sources["proverSha256"],
            "configSha256": protocol["configSha256"],
        },
        "contracts": symbols,
        "engines": ["momentum"],
        "costBandsPoints": protocol["costBandsPoints"],
        "outerFolds": protocol["outerFolds"],
        "embargoBars": protocol["embargoBars"],
        "priorFamilySize": prior,
        "folds": [],
        "researchCandidates": [],
        "eligibleForLive": False,
        "adopted": False,
        "label": "Bounded nested validation. Research only.",
        "reason": "No confirmed research observation.",
        "disclaimer": OC.RESEARCH_DISCLAIMER,
        "hypothesisReservation": binding,
    }


# --- loopback test server helpers ------------------------------------------
def _start_server():
    srv = A.Server(("127.0.0.1", 0), A.H)          # ephemeral port
    port = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, port


def _req(port, method, path, *, host=None, token=None, body=None):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    conn.putrequest(method, path, skip_host=(host is not None))
    if host is not None:
        conn.putheader("Host", host)
    if token is not None:
        conn.putheader("Authorization", f"Bearer {token}")
    payload = None
    if body is not None:
        payload = json.dumps(body).encode()
        conn.putheader("Content-Type", "application/json")
        conn.putheader("Content-Length", str(len(payload)))
    conn.endheaders(message_body=payload)
    resp = conn.getresponse()
    raw = resp.read()
    conn.close()
    try:
        obj = json.loads(raw or b"{}")
    except Exception:  # noqa: BLE001
        obj = {}
    return resp.status, obj


# --- pure helpers -----------------------------------------------------------
def test_host_allowed_helper():
    ok = A._host_allowed
    assert ok("127.0.0.1:8787") and ok("localhost") and ok("127.0.0.1") and ok("localhost:8787")
    assert ok("[::1]:8787") and ok("::1")
    assert not ok("attacker.com")
    assert not ok("evil.example:8787")
    assert not ok("10.0.0.5:8787")
    assert not ok("")                       # HTTP/1.1 requires Host; absent => reject


def test_token_resolver_mints_random_when_unset():
    saved = os.environ.pop("BLTD_TOKEN", None)
    try:
        t1, t2 = A._resolve_token(), A._resolve_token()
        assert t1 and t2 and t1 != t2                 # random per call
        assert t1 != "bl-local-token"                 # never the old public constant
        os.environ["BLTD_TOKEN"] = "fixed-override"
        assert A._resolve_token() == "fixed-override"  # env honored (back-compat)
    finally:
        if saved is not None:
            os.environ["BLTD_TOKEN"] = saved
        else:
            os.environ.pop("BLTD_TOKEN", None)


def test_heartbeat_fresh_helper():
    fresh = A._heartbeat_fresh
    now = 1000.0
    assert fresh(now - 5, now, 30.0) is True
    assert fresh(now - 60, now, 30.0) is False
    assert fresh(None, now, 30.0) is False


def test_capture_heartbeat_path():
    p = C.evaluator_heartbeat_path("/a/b/trading.sqlite3")
    assert p.endswith("evaluator.heartbeat") and p.startswith(os.path.join("/a", "b"))


# --- Host-header gate (DNS-rebinding defense) ------------------------------
def test_loopback_host_allowed():
    srv, port = _start_server()
    try:
        st, obj = _req(port, "GET", "/health", host=f"127.0.0.1:{port}")
        assert st == 200 and obj.get("ok") is True
        assert obj.get("service") == "black-label-trading"
        st, _ = _req(port, "GET", "/health", host="localhost")
        assert st == 200
    finally:
        srv.shutdown()


def test_foreign_host_rejected_before_auth():
    srv, port = _start_server()
    try:
        # unauth GET with a foreign Host -> 403 (Host gate fires before anything)
        st, _ = _req(port, "GET", "/health", host="attacker.com")
        assert st == 403
        # a VALID token does NOT rescue a foreign Host -> proves Host is checked first
        st, _ = _req(port, "GET", "/api/meta", host="evil.example", token=TOK)
        assert st == 403
        # POST is gated too (DNS-rebinding can't reach any write path)
        st, _ = _req(port, "POST", "/api/config", host="rebind.attacker.com", token=TOK, body={})
        assert st == 403
    finally:
        srv.shutdown()


# --- /api/capture reports honest evaluator liveness ------------------------
def test_capture_status_reports_evaluator_alive():
    # No heartbeat file written yet -> evaluatorAlive is False (honest "offline").
    srv, port = _start_server()
    try:
        st, obj = _req(port, "GET", "/api/capture", host=f"127.0.0.1:{port}", token=TOK)
        assert st == 200 and obj.get("evaluatorAlive") is False
        # Touch a fresh heartbeat where the evaluator would write it -> alive flips True.
        hb = C.evaluator_heartbeat_path(A.STORE.path)
        os.makedirs(os.path.dirname(hb), exist_ok=True)
        with open(hb, "w") as f:
            f.write("")
        st, obj = _req(port, "GET", "/api/capture", host=f"127.0.0.1:{port}", token=TOK)
        assert st == 200 and obj.get("evaluatorAlive") is True
    finally:
        srv.shutdown()


def test_connect_opens_no_api_browser_capture_tabs():
    calls = []
    saved = (C.feeds_available, C.open_feed_login_tabs, C.discover_feed_pages, C.cdp_reachable)
    try:
        C.feeds_available = lambda: False
        C.open_feed_login_tabs = lambda source=None: calls.append(source)
        C.discover_feed_pages = lambda source=None: (
            [(source or "topstepx", {"url": "https://app.wealthcharts.com/"})] if calls else []
        )
        C.cdp_reachable = lambda: True

        obj = A._connect({"source": "wealthcharts"})
        assert obj["ok"] is True
        assert obj["source"] == "wealthcharts"
        assert obj["launched"] is True
        assert obj["feedAvailable"] is True
        assert obj["feedPages"] == ["wealthcharts"]
        assert calls == ["wealthcharts"]
    finally:
        C.feeds_available, C.open_feed_login_tabs, C.discover_feed_pages, C.cdp_reachable = saved


def test_feed_status_reports_reachable_browser_before_webhook_ticks():
    saved = C.discover_feed_pages
    try:
        C.discover_feed_pages = lambda source=None: [
            ("wealthcharts", {"url": "https://app.wealthcharts.com/", "webSocketDebuggerUrl": "ws://127.0.0.1:9223/devtools/page/1"})
        ]
        srv, port = _start_server()
        try:
            h = f"127.0.0.1:{port}"
            st, o = _req(port, "GET", "/api/feed/status", host=h, token=TOK)
            assert st == 200
            assert o["source"] == "wealthcharts"
            assert o["state"] == "browser"
            assert "capture browser" in o["detail"]
        finally:
            srv.shutdown()
    finally:
        C.discover_feed_pages = saved


def test_feed_connect_rejects_api_sources():
    srv, port = _start_server()
    try:
        h = f"127.0.0.1:{port}"
        st, o = _req(port, "POST", "/api/feed/connect", host=h, token=TOK,
                     body={"source": "projectx", "creds": {"apiKey": "must-not-be-used"}})
        assert st == 200
        assert o["state"] == "error"
        assert "webhook ingestion only" in o["detail"]
    finally:
        srv.shutdown()


def test_webhook_info_exposes_local_receiver_details():
    srv, port = _start_server()
    try:
        h = f"127.0.0.1:{port}"
        st, o = _req(port, "GET", "/api/webhook/info", host=h, token=TOK)
        assert st == 200
        assert o["source"] == "webhook"
        assert o["endpoint"] == f"http://{h}/webhook/feed"
        assert o["header"] == f"Authorization: Bearer {TOK}"
        assert "/webhook/feed" in o["curl"]
    finally:
        srv.shutdown()


def test_webhook_feed_ingests_ticks_and_bars():
    srv, port = _start_server()
    try:
        h = f"127.0.0.1:{port}"
        now = int(time.time())
        payload = {"symbol": "ESU6",
                   "ticks": [{"price": 100.5, "ts": now}],
                   "bars": [[100.0, 101.0, 99.5, 100.5, now]]}
        st, unauth = _req(port, "POST", "/webhook/feed", host=h, body=payload)
        assert st == 401

        st, o = _req(port, "POST", "/webhook/feed", host=h, token=TOK, body=payload)
        assert st == 200 and o["ok"] is True
        assert o["source"] == "webhook"
        assert o["ticks"] == 2 and o["bars"] == 1 and o["rejected"] == 0
        assert o["symbols"] == ["ESU6"]

        st, live = _req(port, "GET", "/api/live?symbol=ESU6", host=h, token=TOK)
        assert st == 200 and live["price"] == 100.5
        st, recent = _req(port, "GET", "/api/recent?symbol=ESU6&limit=5", host=h, token=TOK)
        assert st == 200 and len(recent["bars"]) == 1
        st, cap = _req(port, "GET", "/api/capture", host=h, token=TOK)
        assert st == 200
        assert cap["feedAvailable"] is True
        assert cap["feedSource"] == "webhook"
        assert "ESU6" in cap["liveTicks"]
    finally:
        srv.shutdown()


def test_webhook_feed_signs_volume_delta_for_wc_tick_bars():
    srv, port = _start_server()
    try:
        h = f"127.0.0.1:{port}"
        now = int(time.time())
        sym = "CM.DLT6"
        payload = {"symbol": sym,
                   "candles": [
                       {"open": 100.0, "high": 100.0, "low": 100.0, "close": 100.0,
                        "ts": now, "volume": 2.0},
                       {"open": 101.0, "high": 101.0, "low": 101.0, "close": 101.0,
                        "ts": now + 1, "volume": 3.0},
                   ]}
        st, o = _req(port, "POST", "/webhook/feed", host=h, token=TOK, body=payload)
        assert st == 200 and o["ok"] is True and o["bars"] == 2
        st, recent = _req(port, "GET", f"/api/recent?symbol={sym}&limit=5", host=h, token=TOK)
        assert st == 200
        assert recent["bars"][-1][5] == 3.0       # real WC volume preserved
        assert recent["bars"][-1][6] == 3.0       # tick-rule signed delta
    finally:
        srv.shutdown()


# --- b27 signals-only boundary ---------------------------------------------------------------
def test_execution_control_plane_is_absent_and_cannot_mutate_legacy_state():
    srv, port = _start_server()
    try:
        h = f"127.0.0.1:{port}"
        before = dict(A.STORE.exec_flags())
        st, body = _req(port, "POST", "/api/exec/arm", host=h, token=TOK,
                        body={"mode": "live", "osAuth": True})
        assert st == 404 and body.get("error") == "not found"
        st, body = _req(port, "GET", "/api/exec/status", host=h, token=TOK)
        assert st == 404 and body.get("error") == "unknown endpoint"
        after = dict(A.STORE.exec_flags())
        assert after == before
        assert after["armed"] is False and after["mode"] == "paper" and after["kill"] is True
    finally:
        srv.shutdown()


def test_backtest_lab_route_seeds_bars_and_returns_provenance():
    """The no-code lab route runs the SHIPPED prover on the buyer's OWN captured bars and returns
    per-fold n/W/L/max-drawdown-R/p + prover_sha — honest 'insufficient' on a thin seed, never a
    fabricated aggregate headline."""
    srv, port = _start_server()
    try:
        h = f"127.0.0.1:{port}"
        now = int(time.time())
        # Seed a real series of bars via the webhook (the buyer's own data path).
        bars = [[100.0 + i * 0.25, 100.0 + i * 0.25, 100.0 + i * 0.25, 100.0 + i * 0.25, now + i]
                for i in range(80)]
        st, o = _req(port, "POST", "/webhook/feed", host=h, token=TOK,
                     body={"symbol": "LABX6", "bars": bars})
        assert st == 200 and o["ok"] is True

        st, bnd = _req(port, "GET", "/api/backtest/bounds?symbol=LABX6", host=h, token=TOK)
        assert st == 200 and bnd["count"] == 80
        assert bnd["firstTs"] == now and bnd["lastTs"] == now + 79

        st, r = _req(port, "GET", "/api/backtest/run?engine=meanrev&symbol=LABX6&folds=2",
                     host=h, token=TOK)
        assert st == 200
        assert r["engine"] == "meanrev" and r["symbol"] == "LABX6"
        assert len(r["prover_sha"]) == 16 and r["sigMinN"] == S.SIG_MIN_N
        assert r["available"] is True and r["whole"] is not None
        for f in r["folds"]:
            assert f["wins"] + f["losses"] == f["trades"]          # honest W/L split
            if f["trades"] < S.SIG_MIN_N:
                assert f["insufficient"] is True and f["proven"] is False
        # never a fabricated aggregate win-rate / $ headline
        assert "winRateAll" not in r and "netPnlDollars" not in r
    finally:
        srv.shutdown()


def test_backtest_run_host_and_auth_gated():
    srv, port = _start_server()
    try:
        h = f"127.0.0.1:{port}"
        st, _ = _req(port, "GET", "/api/backtest/run?engine=meanrev&symbol=LABX6", host="attacker.com")
        assert st == 403                                          # host allowlist before anything
        st, _ = _req(port, "GET", "/api/backtest/run?engine=meanrev&symbol=LABX6", host=h)
        assert st == 401                                          # auth required (no token)
    finally:
        srv.shutdown()


def test_backtest_farm_route_sweeps_and_reports_cells_over_fit_transparently():
    """TR-19 farm route: seed the buyer's OWN bars, sweep the SHIPPED prover's grid, and return
    per-cell n/W/L/max-drawdown-R + a BH-FDR-corrected p (pEdgeAdj) across the whole grid + prover_sha.
    NEVER a raw best-cell p, never an aggregate win-rate/$ headline. workers=1 keeps the test serial."""
    srv, port = _start_server()
    try:
        h = f"127.0.0.1:{port}"
        now = int(time.time())
        # a real oscillating series so the mean-reversion prover actually triggers trades
        bars = []
        for i in range(400):
            base = 100.0 + (2.0 if (i // 5) % 2 == 0 else -2.0) + (i % 3) * 0.1
            bars.append([base, base + 0.5, base - 0.5, base, now + i])
        st, o = _req(port, "POST", "/webhook/feed", host=h, token=TOK,
                     body={"symbol": "FARMX6", "bars": bars})
        assert st == 200 and o["ok"] is True

        st, r = _req(port, "GET", "/api/backtest/farm?engine=meanrev&symbol=FARMX6&workers=1",
                     host=h, token=TOK)
        assert st == 200
        assert r["engine"] == "meanrev" and r["symbol"] == "FARMX6"
        assert len(r["prover_sha"]) == 16 and r["sigMinN"] == S.SIG_MIN_N
        assert r["available"] is True
        assert r["cellsTried"] == len(r["cells"]) > 1               # a real multi-cell sweep
        assert r["compute"].startswith("serial")                   # workers=1 -> serial, honest
        for c in r["cells"]:
            assert c["wins"] + c["losses"] == c["trades"]          # honest W/L split
            assert "pEdgeAdj" in c and "pEdge" not in c            # only the FDR-corrected p is shown
            assert 0.0 <= c["pEdgeAdj"] <= 1.0
            assert "selectionHit" in c and "proven" not in c       # screening, not proof/adoption
            if c["trades"] < S.SIG_MIN_N:
                assert c["insufficient"] is True and c["selectionHit"] is False
        # never a fabricated aggregate win-rate / $ headline
        assert "winRateAll" not in r and "netPnlDollars" not in r
    finally:
        srv.shutdown()


def test_backtest_farm_route_host_and_auth_gated():
    srv, port = _start_server()
    try:
        h = f"127.0.0.1:{port}"
        st, _ = _req(port, "GET", "/api/backtest/farm?engine=meanrev&symbol=LABX6", host="attacker.com")
        assert st == 403                                          # host allowlist before anything
        st, _ = _req(port, "GET", "/api/backtest/farm?engine=meanrev&symbol=LABX6", host=h)
        assert st == 401                                          # auth required (no token)
    finally:
        srv.shutdown()


def test_optimizer_latest_is_authenticated_read_only_research_report():
    saved = os.environ.get("BLTD_OPTIMIZER_REPORT")
    with tempfile.TemporaryDirectory() as directory:
        path = os.path.join(directory, "optimizer-latest.json")
        os.environ["BLTD_OPTIMIZER_REPORT"] = path
        report = _optimizer_report_fixture()
        report["researchCandidates"] = [
            {"engine": "momentum", "params": {"lookback": 20}}]
        with open(path, "w") as handle:
            json.dump(report, handle)
        with open(path, "rb") as handle:
            before_bytes = handle.read()
        before_config = A.STORE.config()
        srv, port = _start_server()
        try:
            h = f"127.0.0.1:{port}"
            st, body = _req(
                port, "GET", "/api/research/optimizer/latest",
                host="optimizer.attacker.example", token=TOK)
            assert st == 403 and body.get("error") == "forbidden"
            st, body = _req(port, "GET", "/api/research/optimizer/latest", host=h)
            assert st == 401 and body.get("error") == "unauthorized"
            st, body = _req(
                port, "GET", "/api/research/optimizer/latest", host=h, token=TOK)
            assert st == 200
            assert body["kind"] == "nested_strategy_validation"
            assert body["provenance"]["runId"] == "e" * 64
            assert body["researchCandidates"] == report["researchCandidates"]
            assert body["researchOnly"] is True
            assert body["eligibleForLive"] is False and body["adopted"] is False

            # There is deliberately no HTTP compute control plane.
            st, body = _req(
                port, "POST", "/api/research/optimizer/run", host=h, token=TOK, body={})
            assert st == 404 and body.get("error") == "not found"
            st, body = _req(
                port, "POST", "/api/research/optimizer/latest", host=h, token=TOK, body={})
            assert st == 404 and body.get("error") == "not found"
        finally:
            srv.shutdown()
        with open(path, "rb") as handle:
            assert handle.read() == before_bytes
        assert A.STORE.config() == before_config
    if saved is None:
        os.environ.pop("BLTD_OPTIMIZER_REPORT", None)
    else:
        os.environ["BLTD_OPTIMIZER_REPORT"] = saved


def test_optimizer_latest_observes_only_canonical_side_of_atomic_replace():
    saved = os.environ.get("BLTD_OPTIMIZER_REPORT")
    try:
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "optimizer-latest.json")
            staged = os.path.join(directory, ".optimizer-next.json")
            os.environ["BLTD_OPTIMIZER_REPORT"] = path
            before = _optimizer_report_fixture("1" * 64)
            after = _optimizer_report_fixture("2" * 64)
            with open(path, "w") as handle:
                json.dump(before, handle)
            with open(staged, "w") as handle:
                json.dump(after, handle)
            srv, port = _start_server()
            try:
                h = f"127.0.0.1:{port}"
                st, first = _req(
                    port, "GET", "/api/research/optimizer/latest", host=h, token=TOK)
                assert st == 200 and first["provenance"]["runId"] == "1" * 64
                os.replace(staged, path)
                st, second = _req(
                    port, "GET", "/api/research/optimizer/latest", host=h, token=TOK)
                assert st == 200 and second["provenance"]["runId"] == "2" * 64
            finally:
                srv.shutdown()
    finally:
        if saved is None:
            os.environ.pop("BLTD_OPTIMIZER_REPORT", None)
        else:
            os.environ["BLTD_OPTIMIZER_REPORT"] = saved


def test_optimizer_latest_missing_or_invalid_fails_closed_without_creating_report():
    saved = os.environ.get("BLTD_OPTIMIZER_REPORT")
    with tempfile.TemporaryDirectory() as directory:
        path = os.path.join(directory, "optimizer-latest.json")
        os.environ["BLTD_OPTIMIZER_REPORT"] = path
        srv, port = _start_server()
        try:
            h = f"127.0.0.1:{port}"
            # A sibling temp file is never visible before the CLI's atomic os.replace.
            with open(path + ".tmp", "w") as handle:
                json.dump({"kind": "nested_strategy_validation", "available": True}, handle)
            st, missing = _req(
                port, "GET", "/api/research/optimizer/latest", host=h, token=TOK)
            assert st == 200 and missing["available"] is False
            assert missing["researchCandidates"] == []
            assert missing["researchOnly"] is True
            assert missing["eligibleForLive"] is False and missing["adopted"] is False
            assert "never computes" in missing["label"]
            assert not os.path.exists(path)

            with open(path, "w") as handle:
                handle.write("{broken")
            st, malformed = _req(
                port, "GET", "/api/research/optimizer/latest", host=h, token=TOK)
            assert st == 200 and malformed["available"] is False
            assert malformed["researchCandidates"] == []

            with open(path, "w") as handle:
                json.dump([{"kind": "nested_strategy_validation"}], handle)
            st, wrong_shape = _req(
                port, "GET", "/api/research/optimizer/latest", host=h, token=TOK)
            assert st == 200 and wrong_shape["available"] is False

            with open(path, "w") as handle:
                json.dump({
                    "kind": "nested_strategy_validation",
                    "available": False,
                    "provenance": {"runId": "incomplete"},
                    "eligibleForLive": False,
                    "adopted": False,
                }, handle)
            st, incomplete = _req(
                port, "GET", "/api/research/optimizer/latest", host=h, token=TOK)
            assert st == 200 and incomplete["available"] is False
            assert incomplete["reason"] != "incomplete"
            assert incomplete["researchCandidates"] == []

            # A report that claims adoption/live eligibility is rejected, never sanitized into an
            # apparently valid result.
            unsafe_report = _optimizer_report_fixture()
            unsafe_report.update(
                eligibleForLive=True, adopted=True,
                researchCandidates=[{"engine": "momentum"}])
            with open(path, "w") as handle:
                json.dump(unsafe_report, handle)
            st, unsafe = _req(
                port, "GET", "/api/research/optimizer/latest", host=h, token=TOK)
            assert st == 200 and unsafe["available"] is False
            assert unsafe["researchCandidates"] == []
            assert unsafe["eligibleForLive"] is False and unsafe["adopted"] is False

            dishonest = _optimizer_report_fixture()
            dishonest.update(
                researchOnly=False, label="Guaranteed live profits",
                disclaimer="Eligible for live deployment", executionApproved=True)
            with open(path, "w") as handle:
                json.dump(dishonest, handle)
            st, rejected = _req(
                port, "GET", "/api/research/optimizer/latest", host=h, token=TOK)
            assert st == 200 and rejected["available"] is False
            assert "executionApproved" not in rejected

            # Pathologically deep but syntactically valid JSON is corrupt input, not an API error
            # shape or traceback leak.
            with open(path, "w") as handle:
                handle.write('{"nested":' * 1_100 + "null" + "}" * 1_100)
            st, deep = _req(
                port, "GET", "/api/research/optimizer/latest", host=h, token=TOK)
            assert st == 200 and deep["available"] is False
            assert deep["researchOnly"] is True and "error" not in deep
        finally:
            srv.shutdown()
    if saved is None:
        os.environ.pop("BLTD_OPTIMIZER_REPORT", None)
    else:
        os.environ["BLTD_OPTIMIZER_REPORT"] = saved


if __name__ == "__main__":
    import sys
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    failed = 0
    for fn in fns:
        try:
            fn()
            print(f"  ok   {fn.__name__}")
        except AssertionError as e:
            failed += 1
            print(f"  FAIL {fn.__name__}: {e}")
        except Exception as e:  # noqa: BLE001
            failed += 1
            print(f"  ERR  {fn.__name__}: {type(e).__name__}: {e}")
    print(f"\n{len(fns) - failed} passed, {failed} failed")
    sys.exit(1 if failed else 0)
