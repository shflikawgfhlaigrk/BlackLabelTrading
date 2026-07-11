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
import bltd_store as S          # noqa: E402

TOK = "test-token-xyz"


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


# --- execution control-plane routes (auth + Host gated; live needs OS-auth) ------------------
def test_exec_routes_require_auth_and_host():
    srv, port = _start_server()
    try:
        # Cold-posture baseline: the suite shares one module-global store, and exec tests that sort
        # earlier alphabetically (arm/mode-live) leave armed/mode persisted in the exec_kv table. This
        # test asserts the DEFAULT disarmed/paper posture, so reset that state first (deterministic).
        for _k, _v in (("armed", "0"), ("mode", "paper"), ("kill", "0"), ("liveAuthExpiry", "0")):
            A.STORE.set_exec_kv(_k, _v)
        st, _ = _req(port, "POST", "/api/exec/arm", host=f"127.0.0.1:{port}")          # no bearer
        assert st == 401
        st, _ = _req(port, "POST", "/api/exec/arm", host="attacker.com", token=TOK)     # foreign host
        assert st == 403
        st, o = _req(port, "GET", "/api/exec/status", host=f"127.0.0.1:{port}", token=TOK)
        assert st == 200 and o.get("armed") is False and o.get("mode") == "paper"
    finally:
        srv.shutdown()


def test_exec_arm_disarm_and_kill():
    srv, port = _start_server()
    try:
        h = f"127.0.0.1:{port}"
        _req(port, "POST", "/api/exec/arm", host=h, token=TOK, body={})
        st, o = _req(port, "GET", "/api/exec/status", host=h, token=TOK)
        assert o["armed"] is True
        _req(port, "POST", "/api/exec/kill", host=h, token=TOK, body={})
        st, o = _req(port, "GET", "/api/exec/status", host=h, token=TOK)
        assert o["kill"] is True                                   # master halt set
        _req(port, "POST", "/api/exec/clearkill", host=h, token=TOK, body={})
        st, o = _req(port, "GET", "/api/exec/status", host=h, token=TOK)
        assert o["kill"] is False
    finally:
        srv.shutdown()


def test_exec_live_mode_requires_osauth():
    srv, port = _start_server()
    try:
        h = f"127.0.0.1:{port}"
        st, o = _req(port, "POST", "/api/exec/mode", host=h, token=TOK, body={"mode": "live"})
        assert o.get("ok") is False and "authentication" in o.get("error", "").lower()
        st, o2 = _req(port, "GET", "/api/exec/status", host=h, token=TOK)
        assert o2["mode"] == "paper" and o2["liveAuthorized"] is False   # still not live
        st, o3 = _req(port, "POST", "/api/exec/mode", host=h, token=TOK, body={"mode": "live", "osAuth": True})
        assert o3.get("ok") is True and o3["mode"] == "live" and o3["liveAuthorized"] is True
    finally:
        srv.shutdown()


def test_exec_config_post_cannot_arm():
    # End-to-end via HTTP: a /api/config POST with exec flags must NOT arm/enable-live/clear-kill.
    srv, port = _start_server()
    try:
        h = f"127.0.0.1:{port}"
        # establish a known baseline via the DEDICATED routes (tests share one STORE)
        _req(port, "POST", "/api/exec/disarm", host=h, token=TOK, body={})
        _req(port, "POST", "/api/exec/mode", host=h, token=TOK, body={"mode": "paper"})
        _req(port, "POST", "/api/exec/kill", host=h, token=TOK, body={})
        # now a config POST trying to flip exec flags must be a no-op for them
        _req(port, "POST", "/api/config", host=h, token=TOK,
             body={"execArmed": True, "execMode": "live", "execKill": False, "armed": True})
        st, o = _req(port, "GET", "/api/exec/status", host=h, token=TOK)
        assert o["armed"] is False and o["mode"] == "paper" and o["kill"] is True, o
        _req(port, "POST", "/api/exec/clearkill", host=h, token=TOK, body={})   # cleanup for other tests
    finally:
        srv.shutdown()


def test_exec_creds_route_records_nonsecret_account():
    srv, port = _start_server()
    try:
        h = f"127.0.0.1:{port}"
        st, o = _req(port, "POST", "/api/exec/creds", host=h, token=TOK,
                     body={"broker": "projectx", "username": "trader@example.com", "account": "EVAL-50K",
                           "apiKey": "must-not-be-stored-here"})
        assert st == 200 and o.get("ok") is True
        st, status = _req(port, "GET", "/api/exec/status", host=h, token=TOK)
        assert st == 200
        assert status["broker"] == "projectx"
        assert status["brokerUser"] == "trader@example.com"
        assert status["brokerAccount"] == "EVAL-50K"
        assert "apiKey" not in status
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
