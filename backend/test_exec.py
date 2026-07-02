"""Black Label Trading — execution-engine SAFETY tests (stdlib-only, OFFLINE, zero broker code).

Proves the core guarantee: a LIVE broker order is impossible unless EVERY precondition holds. Uses a
FakeState (fully armed/live/authorized by default) and a SpyLive adapter that records any
place_bracket call — so any test that drops one condition asserts the spy was NEVER called.
"""
from __future__ import annotations

import os
import tempfile

import bltd_exec as X


class SpyLive(X.BrokerAdapter):
    name = "spylive"

    def __init__(self):
        self.calls = []

    def place_bracket(self, intent):
        self.calls.append(intent)
        return {"status": "live_working"}

    def flatten_all(self):
        return True


class FakeState:
    """All conditions satisfied by default -> a fire routes LIVE. Each test flips ONE field off."""

    def __init__(self):
        self._dir = tempfile.mkdtemp()
        self.flags = {"armed": True, "mode": "live", "kill": False, "firm": "topstep",
                      "firmAck": True, "confirmEachOrder": True, "broker": "projectx"}
        self.authorized = True
        self.demo_ok = True
        self.confirmed = True
        self.cfg = {"accountSize": 50000.0, "maxDailyLossPct": 3.0, "execMaxContracts": 5,
                    "execMaxDrawdown": 2000.0, "maxTrades": 10, "riskPerTradePct": 1.0}
        self.realized_loss = 0.0
        self.contracts = 0
        self.equity_v = 50000.0
        self.hwm = 50000.0
        self.trades = 0
        self.edge = True
        self.open_pos = False
        self.fired = set()
        self.decisions = []

    def exec_flags(self): return dict(self.flags)
    def live_authorized(self): return self.authorized
    def demo_validated(self): return self.demo_ok
    def order_confirmed(self, cid): return self.confirmed
    def risk_config(self): return dict(self.cfg)
    def day_realized_loss(self): return self.realized_loss
    def open_contracts(self, symbol): return self.contracts
    def equity(self): return self.equity_v
    def equity_hwm(self): return self.hwm
    def trades_today(self): return self.trades
    def edge_ok(self, engine, symbol): return self.edge
    def has_open_position(self, engine, symbol, direction): return self.open_pos
    def already_fired(self, cid): return cid in self.fired
    def store_dir(self): return self._dir
    def record_decision(self, intent, decision): self.decisions.append((intent, decision))
    def broker_creds(self): return {"broker": "projectx", "apiKey": "k", "username": "u", "account": "EVAL"}


def _engine(state, live=None):
    return X.ExecutionEngine(state, live=live or SpyLive())


def _fire(eng, bar_key=1, engine="meanrev", symbol="ESU6", direction="long",
          entry=5000.0, stop=4990.0, target=5020.0):
    return eng.on_fire(symbol, direction, entry, stop, target, engine, bar_key)


# --- the core guarantee: drop each precondition, assert NO live order ------------------------
def test_full_chain_routes_live_only_when_everything_holds():
    s = FakeState(); spy = SpyLive(); e = _engine(s, spy)
    d = _fire(e)
    assert d.route == "live", d.reason
    assert len(spy.calls) == 1 and spy.calls[0].is_automated is True


def test_no_live_order_when_any_condition_dropped():
    # Each mutator flips ONE precondition off; the live spy must NEVER be called.
    mutators = {
        "disarmed":        lambda s: s.flags.update(armed=False),
        "kill_flag":       lambda s: s.flags.update(kill=True),
        "paper_mode":      lambda s: s.flags.update(mode="paper"),
        "firm_not_ok":     lambda s: s.flags.update(firm="apex"),
        "firm_unack":      lambda s: s.flags.update(firmAck=False),
        "no_creds_auth":   lambda s: setattr(s, "authorized", False),
        "not_demo_valid":  lambda s: setattr(s, "demo_ok", False),
        "not_confirmed":   lambda s: setattr(s, "confirmed", False),
        "daily_loss":      lambda s: setattr(s, "realized_loss", 1600.0),  # 1600+200 > 3% of 50k=1500
        "contract_cap":    lambda s: setattr(s, "contracts", 5),
        "drawdown":        lambda s: setattr(s, "equity_v", 47000.0),       # hwm-equity=3000 >= 2000
        "max_trades":      lambda s: setattr(s, "trades", 10),
        "no_edge":         lambda s: setattr(s, "edge", False),
        "open_position":   lambda s: setattr(s, "open_pos", True),
        "no_size_cfg":     lambda s: s.cfg.update(riskPerTradePct=0.0),
    }
    for name, mut in mutators.items():
        s = FakeState(); mut(s); spy = SpyLive(); e = _engine(s, spy)
        d = _fire(e)
        assert d.route != "live", f"{name}: must NOT route live (got {d.route})"
        assert len(spy.calls) == 0, f"{name}: live adapter must not be called"


def test_no_target_no_naked_bracket():
    s = FakeState(); spy = SpyLive(); e = _engine(s, spy)
    d = e.on_fire("ESU6", "long", 5000.0, 4990.0, None, "breakout", 1)   # target None
    assert d.route == "blocked" and "naked" in d.reason and len(spy.calls) == 0


def test_unknown_pointvalue_no_size():
    s = FakeState(); spy = SpyLive(); e = _engine(s, spy)
    d = _fire(e, symbol="EURUSD")          # not in POINT_VALUES -> no size -> blocked
    assert d.route == "blocked" and "size" in d.reason and len(spy.calls) == 0


def test_dedup_single_flight():
    s = FakeState(); spy = SpyLive(); e = _engine(s, spy)
    d1 = _fire(e, bar_key=7)
    assert d1.route == "live"
    s.fired.add("meanrev:ES:long:7")        # the deterministic client_order_id
    d2 = _fire(e, bar_key=7)
    assert d2.route == "blocked" and "duplicate" in d2.reason and len(spy.calls) == 1


# --- kill switch ----------------------------------------------------------------------------
def test_kill_flag_and_sentinel_file_halt_everything():
    s = FakeState(); spy = SpyLive(); e = _engine(s, spy)
    # sentinel file alone (flag still false) must block
    open(X.kill_sentinel_path(s.store_dir()), "w").close()
    d = _fire(e)
    assert d.route == "blocked" and "kill" in d.reason and len(spy.calls) == 0
    os.remove(X.kill_sentinel_path(s.store_dir()))
    # now the flag alone
    s.flags["kill"] = True
    assert _fire(e).route == "blocked"


def test_kill_checked_first():
    # Even fully unauthorized + killed, the reason is the kill (checked first), and never live.
    s = FakeState(); s.flags.update(kill=True, armed=False); spy = SpyLive(); e = _engine(s, spy)
    d = _fire(e)
    assert "kill" in d.reason and len(spy.calls) == 0


# --- default posture is signals-only --------------------------------------------------------
def test_default_posture_no_broker():
    # fresh/default exec flags (armed False, paper) -> blocked, paper adapter untouched, no live.
    s = FakeState(); s.flags = {"armed": False, "mode": "paper", "kill": False, "firm": "",
                                "firmAck": False, "confirmEachOrder": True, "broker": ""}
    spy = SpyLive(); e = _engine(s, spy)
    d = _fire(e)
    assert d.route == "blocked" and len(spy.calls) == 0 and len(e.paper.placed) == 0


def test_disarmed_executor_is_noop():
    de = X.DisarmedExecutor()
    assert de.on_fire("ESU6", "long", 5000, 4990, 5020, "meanrev", 1).route == "blocked"
    assert de.flatten_all() is True


# --- paper route (armed + paper + gates pass) -----------------------------------------------
def test_paper_route_when_armed_paper():
    s = FakeState(); s.flags["mode"] = "paper"; spy = SpyLive(); e = _engine(s, spy)
    d = _fire(e)
    assert d.route == "paper" and len(spy.calls) == 0
    assert len(e.paper.placed) == 1 and e.paper.placed[0]["sim"] is True   # honest sim label


def test_paper_runs_full_risk_chain():
    # paper still respects risk gates (a faithful dry-run), e.g. daily-loss halt blocks even paper.
    s = FakeState(); s.flags["mode"] = "paper"; s.realized_loss = 1600.0
    spy = SpyLive(); e = _engine(s, spy)
    d = _fire(e)
    assert d.route == "blocked" and "daily-loss" in d.reason and len(e.paper.placed) == 0


# --- fail-closed ----------------------------------------------------------------------------
def test_precheck_fail_closed_on_state_error():
    class Boom(FakeState):
        def exec_flags(self): raise RuntimeError("store down")
    s = Boom(); spy = SpyLive(); e = _engine(s, spy)
    d = _fire(e)
    assert d.route == "blocked" and "fail-closed" in d.reason and len(spy.calls) == 0


# --- sizing -------------------------------------------------------------------------------
def test_sizing_from_account_risk():
    s = FakeState(); e = _engine(s)
    # risk 10pt * $50 ES = $500/contract; 1% of $50k = $500 -> size 1
    assert e._size(X.OrderIntent("ESU6", "long", 5000, 4990, 5020, "m", "c")) == 1
    s.cfg["accountSize"] = 200000.0   # 1% = $2000 / $500 -> 4
    assert e._size(X.OrderIntent("ESU6", "long", 5000, 4990, 5020, "m", "c")) == 4


def test_point_value_and_root():
    assert X.point_value("CM.ESU6") == 50.0 and X.point_value("MNQU6") == 2.0
    assert X.point_value("EURUSD") is None
    assert X.futures_root("CM.ESU6") == "ES" and X.futures_root("EURUSD") == "EURUSD"


def test_flatten_all():
    s = FakeState(); spy = SpyLive(); e = _engine(s, spy)
    _fire(e, bar_key=3)                      # places a live order via spy
    assert e.flatten_all() is True


# --- store-backed control plane (the real persistence + the config-can't-arm guarantee) ------
def _store():
    # ISOLATED config path. (Regression: the old helper used the default config path, so the suite
    # read the developer's REAL ~/Library/.../config.json — when that file had a persisted
    # execConfirmEachOrder:False, test_store_default_is_disarmed failed on that machine and the
    # combined gate went red. A buyer's fresh machine is what a default-posture test must model.)
    import tempfile, bltd_store as S
    d = tempfile.mkdtemp()
    return S.Store(os.path.join(d, "t.sqlite3"), config_path=os.path.join(d, "cfg.json"))


def test_store_default_is_disarmed():
    st = _store()
    eng = X.make_executor(st)
    d = eng.on_fire("ESU6", "long", 5000, 4990, 5020, "meanrev", 1)
    assert d.route == "blocked" and "not armed" in d.reason
    assert st.exec_flags() == {"armed": False, "mode": "paper", "kill": False, "firm": "",
                               "firmAck": False, "broker": "", "confirmEachOrder": True}


def test_config_cannot_disable_per_order_confirm_on_live():
    # FIX (from a trading-qa finding, 2026-06-29): the per-order human-confirm gate must NOT be
    # relaxable via /api/config. The engine no longer consults the config flag for the live confirm
    # requirement — confirm is MANDATORY on every live order (the only firms permitted to go live
    # are human-in-loop). Here: everything maximally armed/live/authorized, confirm DISABLED in
    # config, a live adapter INJECTED (simulating Slice 2), but the order NOT confirmed => the
    # engine STILL blocks for confirmation and never places the order. (config may still hold the
    # cosmetic flag; it just can't weaken the live path.)
    s = FakeState()
    s.flags["confirmEachOrder"] = False    # config says "don't require confirm"
    s.confirmed = False                    # and the order is NOT confirmed
    spy = SpyLive(); e = _engine(s, spy)
    d = _fire(e)
    assert d.route == "blocked" and "confirm" in d.reason, \
        f"per-order confirm MUST be mandatory on live regardless of config (got {d.route}/{d.reason})"
    assert len(spy.calls) == 0, "no live order may be placed without confirmation"
    # confirming it (with confirm 'disabled' in config) DOES allow live -> proves it's the gate
    s.confirmed = True
    assert _fire(e, bar_key=99).route == "live"


def test_store_config_cannot_flip_arm_mode_kill():
    # THE risk-officer #1 finding: a /api/config POST must NEVER arm/enable-live/clear-kill.
    st = _store()
    st.set_exec_kv("kill", "1")
    st.set_config({"execArmed": True, "execMode": "live", "execKill": False,
                   "armed": True, "mode": "live", "kill": False})
    f = st.exec_flags()
    assert f["armed"] is False and f["mode"] == "paper" and f["kill"] is True, f
    # only the dedicated state setter changes them
    st.set_exec_kv("armed", "1"); st.set_exec_kv("kill", "0")
    assert st.exec_flags()["armed"] is True and st.exec_flags()["kill"] is False


def test_store_config_cannot_disable_confirm_each_order():
    # T-2 (2026-07-01 audit): per-order confirm lived in config; a plain /api/config POST could flip
    # it off. It now lives in exec_kv. A config POST must NOT change it; it defaults to require-confirm.
    st = _store()
    assert st.exec_flags()["confirmEachOrder"] is True          # safe default
    st.set_config({"execConfirmEachOrder": False, "confirmEachOrder": False})
    assert st.exec_flags()["confirmEachOrder"] is True, "config POST must not disable per-order confirm"
    # only the dedicated exec setter changes it (the API route additionally gates this on fresh OS-auth)
    st.set_exec_kv("confirmEachOrder", "0")
    assert st.exec_flags()["confirmEachOrder"] is False
    st.set_exec_kv("confirmEachOrder", "1")
    assert st.exec_flags()["confirmEachOrder"] is True


def test_store_live_needs_fresh_os_auth():
    import time as _t
    st = _store()
    assert st.exec_live_authorized() is False                 # default: no capability
    st.set_exec_kv("liveAuthExpiry", str(_t.time() + 300))      # fresh -> authorized
    assert st.exec_live_authorized() is True
    st.set_exec_kv("liveAuthExpiry", str(_t.time() - 1))        # expired -> not
    assert st.exec_live_authorized() is False


def test_store_edge_bypass_cache_param():
    # The exec path must be able to force a fresh edge verdict (no stale 120s cache authorizing live).
    st = _store()
    v = st.edge_ok("meanrev", "ESU6", bypass_cache=True)
    assert v.get("ok") is False   # no bars -> honest not-proven (and never raises)


# --- ProjectX live adapter (built to the documented order API; OFFLINE via a mock poster) -----
def test_projectx_order_body_matches_documented_contract():
    import bltd_projectx as PX
    a = PX.ProjectXExecAdapter("jwt", account_id=123, contract_id="CON.F.US.EP.U25", symbol="ESU6")
    intent = X.OrderIntent("ESU6", "long", 5000.0, 4990.0, 5020.0, "meanrev", "cid-1")
    intent.size = 2
    b = a._order_body(intent)
    # ES tick = 0.25: stop 10pt = 40 ticks, target 20pt = 80 ticks; Market entry, side 0 (buy).
    assert b["accountId"] == 123 and b["contractId"] == "CON.F.US.EP.U25"
    assert b["type"] == 2 and b["side"] == 0 and b["size"] == 2 and b["customTag"] == "cid-1"
    assert b["stopLossBracket"] == {"ticks": 40, "type": 4}
    assert b["takeProfitBracket"] == {"ticks": 80, "type": 1}
    # short -> side 1
    short = X.OrderIntent("ESU6", "short", 5000.0, 5010.0, 4980.0, "meanrev", "cid-2"); short.size = 1
    assert a._order_body(short)["side"] == 1


def test_projectx_place_bracket_uses_mock_poster_no_network():
    import bltd_projectx as PX
    captured = {}

    def fake_post(url, body, token=None, timeout=0):
        captured["url"] = url; captured["body"] = body; captured["token"] = token
        return 200, {"orderId": 9056, "success": True, "errorCode": 0, "errorMessage": None}, ""

    a = PX.ProjectXExecAdapter("jwt-xyz", 7, "CON.X", "ESU6", poster=fake_post)
    i = X.OrderIntent("ESU6", "long", 5000.0, 4990.0, 5020.0, "meanrev", "cid"); i.size = 1
    r = a.place_bracket(i)
    assert r["success"] is True and r["orderId"] == 9056 and r["status"] == "working"
    assert captured["url"].endswith("/api/Order/place") and captured["token"] == "jwt-xyz"
    assert captured["body"]["type"] == 2   # real contract sent, no network


def test_projectx_rejects_unticked_instrument():
    import bltd_projectx as PX
    a = PX.ProjectXExecAdapter("jwt", 1, "CON.X", "EURUSD")   # no tick size known
    i = X.OrderIntent("EURUSD", "long", 1.08, 1.07, 1.09, "meanrev", "cid"); i.size = 1
    assert a._order_body(i) is None
    assert a.place_bracket(i)["success"] is False   # never sends a bracket it can't tick


def test_live_registration_via_factory_offline():
    # The live adapter is built lazily from the buyer's Keychain creds via an injected factory —
    # offline, no network. Registration places NO order; it just makes the adapter available.
    s = FakeState()
    built = {}
    def fake_factory(creds, symbol):
        built["creds"] = creds; built["symbol"] = symbol
        return SpyLive()
    e = X.ExecutionEngine(s, live=None, live_factory=fake_factory)
    assert e.live is None
    d = _fire(e)                                 # mode live -> ensure_live_registered runs the factory
    assert e.live is not None and built["creds"]["apiKey"] == "k" and d.route == "live"
    # no creds -> stays None -> live blocked (fail-safe)
    s2 = FakeState(); s2.broker_creds = lambda: None
    e2 = X.ExecutionEngine(s2, live=None, live_factory=fake_factory)
    d2 = _fire(e2)
    assert e2.live is None and d2.route == "blocked" and "live not authorized" in d2.reason
    # factory error -> stays None (never raises)
    s3 = FakeState()
    e3 = X.ExecutionEngine(s3, live=None, live_factory=lambda c, sym: (_ for _ in ()).throw(RuntimeError("boom")))
    d3 = _fire(e3)
    assert e3.live is None and d3.route == "blocked"


def test_pick_tradable_account():
    import bltd_projectx as PX
    resp = {"accounts": [{"id": 1, "name": "EVALX", "canTrade": False},
                         {"id": 2, "name": "EVAL", "canTrade": True},
                         {"id": 3, "name": "FUND", "canTrade": True}]}
    assert PX.pick_tradable_account(resp)["id"] == 2          # first tradable
    assert PX.pick_tradable_account(resp, "FUND")["id"] == 3  # preferred name
    assert PX.pick_tradable_account({"accounts": [{"id": 9, "canTrade": False}]}) is None
    assert PX.pick_tradable_account(None) is None


def test_projectx_pick_contract_for_execution_symbol():
    import bltd_projectx as PX
    resp = {"contracts": [{"id": "CON.F.US.EP.U25", "name": "ESU5"},
                          {"id": "CON.F.US.ENQ.U25", "name": "NQU5"}]}
    assert PX.pick_contract(resp, "NQU5")["id"] == "CON.F.US.ENQ.U25"
    assert PX.pick_contract(resp, "ESU5")["id"] == "CON.F.US.EP.U25"


def test_ticks_between_and_tick_size():
    assert X.tick_size("ESU6") == 0.25 and X.tick_size("CLF26") == 0.01 and X.tick_size("EURUSD") is None
    assert X.ticks_between("ESU6", 5000.0, 4990.0) == 40
    assert X.ticks_between("EURUSD", 1.08, 1.07) is None


if __name__ == "__main__":
    import sys
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    failed = 0
    for fn in fns:
        try:
            fn(); print(f"  ok   {fn.__name__}")
        except AssertionError as e:
            failed += 1; print(f"  FAIL {fn.__name__}: {e}")
        except Exception as e:  # noqa: BLE001
            failed += 1; print(f"  ERR  {fn.__name__}: {type(e).__name__}: {e}")
    print(f"\n{len(fns) - failed} passed, {failed} failed")
    sys.exit(1 if failed else 0)
