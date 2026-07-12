"""TR-06 tests for the honest edge-gate alert path (bltd_alerts.py).

Proves the three properties the dispatch demands:
  1. a NO-EDGE day still alerts (the honest whole point) — and the payload carries counts + reasons
     + prover_sha but NO aggregate win-rate/$/P&L;
  2. UNCONFIGURED = zero egress (off, or no endpoint, or a non-https external endpoint => no socket);
  3. NO order/auto-trade path exists from the alert module (it imports nothing from bltd_exec).

Runnable via `python3 -m pytest test_alerts.py` or plain `python3 test_alerts.py`.
"""
import json
import os

import bltd_alerts as A
import bltd_analytics
import claim_linter as L


class FakeStore:
    """Minimal store: only what bltd_alerts touches. config() drives every guard; symbols() is only
    reached on the (enabled+endpoint) send path."""
    def __init__(self, cfg):
        self._cfg = cfg

    def config(self):
        return dict(self._cfg)

    def symbols(self):
        return {"backtestable": ["ES", "NQ"]}


NO_EDGE_REPORT = {
    "available": True, "engineCount": 2, "candidateCount": 0, "noEdgeCount": 1,
    "insufficientCount": 1, "prover_sha": "abc123abc123abc1", "symbols": ["ES", "NQ"],
    "engines": [
        {"engine": "meanrev", "status": "no_edge", "contracts": [
            {"symbol": "ES", "trades": 41, "bars": 900, "insufficient": False, "proven": False,
             "reason": "no edge — win 47.2% / net -3.20 pts on 41 OOS trades (p=0.612, need p<0.05)"}]},
        {"engine": "breakout", "status": "insufficient", "contracts": [
            {"symbol": "NQ", "trades": 4, "bars": 120, "insufficient": True, "proven": False,
             "reason": "insufficient sample — 4 OOS trades, need >=30"}]},
    ],
}

OFF_CFG = {"alertEnabled": False, "alertEndpoint": "", "alertProvider": "ntfy"}
ON_CFG = {"alertEnabled": True, "alertEndpoint": "https://ntfy.sh/my-own-topic",
          "alertProvider": "ntfy"}


def _capture_post(monkey_holder):
    """Return a _post stand-in that records its args and reports a 200 (posted)."""
    def fake_post(url, content_type, body, headers, timeout=8.0):
        monkey_holder["url"] = url
        monkey_holder["body"] = body.decode("utf-8") if isinstance(body, bytes) else str(body)
        monkey_holder["ctype"] = content_type
        return {"posted": True, "status": 200, "endpoint": url, "reason": "posted to your endpoint"}
    return fake_post


# ── 1. a NO-EDGE day still alerts, with an honest payload ────────────────────
def test_no_edge_day_still_alerts_and_payload_is_honest():
    seen = {}
    orig_post, orig_rerun = A._post, bltd_analytics.gate_rerun
    A._post = _capture_post(seen)
    bltd_analytics.gate_rerun = lambda store, syms, engs, cfg: dict(NO_EDGE_REPORT)
    try:
        res = A.send_gate_alert(FakeStore(ON_CFG))
    finally:
        A._post, bltd_analytics.gate_rerun = orig_post, orig_rerun
    assert res["sent"] is True and res["networked"] is True, res
    body = seen["body"]
    assert "No edge on your bars today" in body, body           # the honest headline
    assert "meanrev" in body and "no_edge" in body               # per-engine status
    assert "abc123abc123abc1" in body                            # prover_sha
    assert "not a track record" in body.lower()                  # the disclaimer
    # and the payload must carry NO forbidden aggregate figure
    assert not L.scan_text(body), f"alert payload tripped the claim linter: {body!r}"


def test_canonical_payload_has_no_aggregate_and_carries_counts():
    p = A.canonical_payload(NO_EDGE_REPORT)
    assert p["candidateCount"] == 0 and p["noEdgeCount"] == 1 and p["insufficientCount"] == 1
    assert p["prover_sha"] == "abc123abc123abc1"
    # no aggregate stat keys sneak in
    for banned in ("winRate", "netPnl", "pnl", "equity", "roi"):
        assert banned not in p, f"payload leaked an aggregate field: {banned}"


# ── 2. UNCONFIGURED / OFF = zero egress (no socket is ever opened) ───────────
def test_off_config_makes_no_network_call():
    # _post is replaced with a landmine: if it is called, the test fails loudly.
    orig = A._post
    A._post = lambda *a, **k: (_ for _ in ()).throw(AssertionError("network called while OFF"))
    try:
        r1 = A.send_gate_alert(FakeStore(OFF_CFG))
        r2 = A.test_send(FakeStore(OFF_CFG))
    finally:
        A._post = orig
    assert r1["networked"] is False and r1["sent"] is False
    assert r2["networked"] is False and r2["sent"] is False


def test_enabled_but_no_endpoint_makes_no_network_call():
    cfg = {"alertEnabled": True, "alertEndpoint": "", "alertProvider": "ntfy"}
    orig = A._post
    A._post = lambda *a, **k: (_ for _ in ()).throw(AssertionError("network called with no endpoint"))
    try:
        r = A.send_gate_alert(FakeStore(cfg))
        rt = A.test_send(FakeStore(cfg))
    finally:
        A._post = orig
    assert r["networked"] is False and "endpoint" in r["reason"]
    assert rt["networked"] is False


def test_non_https_external_endpoint_is_refused_before_egress():
    cfg = {"alertEnabled": True, "alertEndpoint": "http://evil.example.com/x", "alertProvider": "webhook"}
    orig = A._post
    A._post = lambda *a, **k: (_ for _ in ()).throw(AssertionError("network called to plaintext host"))
    try:
        r = A.test_send(FakeStore(cfg))
    finally:
        A._post = orig
    assert r["networked"] is False and "https" in r["reason"].lower()


def test_egress_allowed_policy():
    assert A.egress_allowed("https://ntfy.sh/topic")
    assert A.egress_allowed("http://localhost:8080/notify")
    assert A.egress_allowed("http://127.0.0.1:9999/x")
    assert not A.egress_allowed("http://ntfy.sh/topic")          # plaintext external -> refused
    assert not A.egress_allowed("ftp://host/x")
    assert not A.egress_allowed("")


def test_enabled_https_endpoint_posts_to_the_buyer_endpoint():
    seen = {}
    orig = A._post
    A._post = _capture_post(seen)
    try:
        r = A.test_send(FakeStore(ON_CFG))
    finally:
        A._post = orig
    assert r["sent"] is True and r["networked"] is True
    assert seen["url"] == "https://ntfy.sh/my-own-topic"         # the buyer's OWN endpoint, not a relay
    assert "delivered" not in r["reason"]                        # honest: "posted", never "delivered"


# ── 3. NO order/auto-trade path from a push ─────────────────────────────────
def test_alert_module_has_no_execution_path():
    src = open(os.path.join(os.path.dirname(__file__), "bltd_alerts.py")).read()
    assert "import bltd_exec" not in src, "alert module must not import the execution engine"
    assert "place_bracket" not in src and "OrderIntent" not in src
    # module namespace carries no exec handle
    assert not hasattr(A, "bltd_exec")


def test_status_is_token_free():
    cfg = {"alertEnabled": True, "alertEndpoint": "https://ntfy.sh/topic", "alertProvider": "pushover",
           "alertPushoverToken": "SECRET_TOKEN", "alertPushoverUser": "SECRET_USER"}
    st = A.status(FakeStore(cfg))
    blob = json.dumps(st)
    assert "SECRET_TOKEN" not in blob and "SECRET_USER" not in blob
    assert st["pushoverConfigured"] is True


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
