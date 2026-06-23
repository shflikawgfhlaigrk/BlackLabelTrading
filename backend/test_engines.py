"""Black Label Trading — backend engine test suite (pure stdlib; pytest-optional).

TDD for the engine roster (momentum/structure/regime/channel/context_a/context_b) + the shared
OHLC indicator helpers and the trade-generator registry. Each engine asserts: a deterministic
synthetic OHLC series that SHOULD prove edge does; one that should NOT doesn't; and empty bars
yield an honest empty result (no fabrication). Runnable via `python3 -m pytest test_engines.py`
or plain `python3 test_engines.py`.
"""
import bltd_store as S


def approx(a, b, t=1e-6):
    return abs(a - b) <= t


# ---- deterministic synthetic series helpers --------------------------------
def _trend_series(n=120, start=100.0, step=0.5):
    # steady uptrend; closes only (o=h=l=c) so every generator is well-defined
    return [(start + i * step,) * 4 for i in range(n)]


def _consensus_uptrend(n=160):
    return [(100.0 + i * 0.7,) * 4 for i in range(n)]


def _downtrend(n=160):
    return [(200.0 - i * 0.7,) * 4 for i in range(n)]


def _chop(n=160):
    return [(100.0 + (1.0 if i % 2 else -1.0),) * 4 for i in range(n)]


# ===========================================================================
# Task 1 — shared OHLC indicator helpers
# ===========================================================================
def test_ema_seed_and_trend():
    assert approx(S._ema([5.0] * 10, 4)[-1], 5.0)
    e = S._ema([float(i) for i in range(20)], 4)
    assert e[-1] < 19.0 and e[-1] > 15.0


def test_kaufman_er_trend_vs_chop():
    trend = [float(i) for i in range(30)]
    chop = [10.0 + (1.0 if i % 2 else -1.0) for i in range(30)]
    assert S._kaufman_er(trend, 20) > 0.95
    assert S._kaufman_er(chop, 20) < 0.2


def test_stepgma_dir_signs():
    up = [float(i) for i in range(40)]
    dn = [float(40 - i) for i in range(40)]
    assert S._stepgma_dir(up, 5, 20)[0] == "bull"
    assert S._stepgma_dir(dn, 5, 20)[0] == "bear"


def test_ribbon_bull_stacked():
    up = [float(i) for i in range(80)]
    dn = [float(80 - i) for i in range(80)]
    assert S._ribbon_bull(up) is True
    assert S._ribbon_bull(dn) is False


def test_atr_positive_on_range():
    ohlc = [(10.0, 12.0, 9.0, 11.0)] * 20
    assert approx(S._atr(ohlc, 14), 3.0)


def test_fib_pos_bounds():
    closes = [10.0, 20.0, 30.0, 25.0]
    assert approx(S._fib_pos(closes, 4), 0.75)
    assert S._fib_pos([7.0, 7.0, 7.0], 3) is None


# ===========================================================================
# Task 2 — trade-generator registry + analytics dispatch
# ===========================================================================
def test_engine_trades_dispatch_matches_inline():
    ohlc = _trend_series()
    legacy = S._bk_trades(ohlc, 20, S.CONFIG_DEFAULTS)            # canonical breakout walk
    viareg = S.engine_trades("breakout", ohlc, 20, S.CONFIG_DEFAULTS)
    assert legacy == viareg
    assert S.engine_trades("nonexistent", ohlc, 20, S.CONFIG_DEFAULTS) == []


def test_analytics_trades_for_matches_gate():
    # The full-backtest report and the gate must walk the SAME OOS trades.
    import bltd_analytics as A
    ohlc = _consensus_uptrend(220)
    cfg = S.CONFIG_DEFAULTS
    trades, split = A._trades_for("breakout", ohlc, cfg)
    oos = ohlc[int(len(ohlc) * (1.0 - cfg["oosFrac"])):]
    assert trades == S._bk_trades(oos, cfg["lookback"], cfg)


# ===========================================================================
# Task 3 — momentum engine (clean symmetric momentum consensus)
# ===========================================================================
def test_momentum_proves_on_trend():
    r = S.prove_momentum(_consensus_uptrend(), S.CONFIG_DEFAULTS)
    assert {"ok", "reason", "trades", "winRate", "netPts", "expectancyR"}.issubset(r)
    assert r["ok"] is True
    assert r["netPts"] > 0


def test_momentum_no_edge_on_chop():
    r = S.prove_momentum(_chop(), S.CONFIG_DEFAULTS)
    assert r["ok"] is False


def test_momentum_empty_is_honest():
    r = S.prove_momentum([], S.CONFIG_DEFAULTS)
    assert r["ok"] is False and r["trades"] == 0


def test_momentum_signal_long_on_uptrend():
    ohlc = _consensus_uptrend()
    sig = S._momentum_signal([b[3] for b in ohlc], ohlc, 20, S.CONFIG_DEFAULTS)
    assert sig is not None and sig["direction"] == "long"


# ===========================================================================
# Task 4 — structure engine (guarded short-biased counter-trend)
# ===========================================================================
def test_structure_blocks_longs():
    trades = S._structure_trades(_consensus_uptrend(), 20, S.CONFIG_DEFAULTS)
    assert all(t["dir"] == "short" for t in trades)


def test_structure_proves_on_downtrend():
    r = S.prove_structure(_downtrend(), S.CONFIG_DEFAULTS)
    assert r["ok"] is True and r["netPts"] > 0


def test_structure_signal_never_long():
    ohlc = _consensus_uptrend()
    sig = S._structure_signal([b[3] for b in ohlc], ohlc, 20, S.CONFIG_DEFAULTS)
    assert sig is None or sig["direction"] == "short"


def test_structure_empty_is_honest():
    r = S.prove_structure([], S.CONFIG_DEFAULTS)
    assert r["ok"] is False and r["trades"] == 0


# ===========================================================================
# Task 5 — regime engine (regime-router trend-continuation)
# ===========================================================================
def test_regime_class_trend_vs_range():
    up = _consensus_uptrend()
    ch = _chop()
    assert S._regime_class([b[3] for b in up], up, 20) == "TREND"
    assert S._regime_class([b[3] for b in ch], ch, 20) == "RANGE"


def test_regime_flat_in_range():
    ch = _chop()
    sig = S._regime_signal([b[3] for b in ch], ch, 20, S.CONFIG_DEFAULTS)
    assert sig is None


def test_regime_proves_on_trend():
    r = S.prove_regime(_consensus_uptrend(), S.CONFIG_DEFAULTS)
    assert r["ok"] is True and r["netPts"] > 0


def test_regime_empty_is_honest():
    r = S.prove_regime([], S.CONFIG_DEFAULTS)
    assert r["ok"] is False and r["trades"] == 0


# ===========================================================================
# Task 6 — channel engine (consensus + Fibonacci golden-pocket gate)
# ===========================================================================
def _trend_with_pullbacks(n=260):
    series = []
    p = 100.0
    for i in range(n):
        p += 0.8 if i % 5 else -1.6   # net up with a 1-in-5 pullback into the retracement band
        series.append((p,) * 4)
    return series


def test_channel_verdict_is_internally_consistent():
    r = S.prove_channel(_trend_with_pullbacks(), S.CONFIG_DEFAULTS)
    assert {"ok", "trades", "netPts", "expectancyR"}.issubset(r)
    # whenever the gate says edge, it MUST be backed by positive expectancy + enough trades
    assert (r["ok"] is False) or (r["expectancyR"] > 0 and r["trades"] >= S.MIN_TRADES)


def test_channel_fib_gate_filters_a_pure_ramp():
    # a pure ramp keeps fib_pos pinned at the swing top (~1.0), outside the long golden pocket
    # [0.34,0.42] -> channel takes far fewer entries than the unguarded momentum consensus.
    ramp = _consensus_uptrend(200)
    channel = S._channel_trades(ramp, 20, S.CONFIG_DEFAULTS)
    momentum = S._momentum_trades(ramp, 20, S.CONFIG_DEFAULTS)
    assert len(channel) < len(momentum)


def test_channel_empty_is_honest():
    r = S.prove_channel([], S.CONFIG_DEFAULTS)
    assert r["ok"] is False and r["trades"] == 0


# ===========================================================================
# Task 7 — context_a + context_b (A/B context-strictness split)
# ===========================================================================
def test_context_a_proves_on_trend():
    r = S.prove_context_a(_consensus_uptrend(), S.CONFIG_DEFAULTS)
    assert r["ok"] is True and r["netPts"] > 0


def test_context_b_stricter_than_a():
    # context_b's stricter gate -> never MORE trades than context_a on the same series
    a = S._context_a_trades(_consensus_uptrend(), 20, S.CONFIG_DEFAULTS)
    b = S._context_b_trades(_consensus_uptrend(), 20, S.CONFIG_DEFAULTS)
    assert len(b) <= len(a)


def test_context_b_proves_on_strong_trend():
    r = S.prove_context_b(_consensus_uptrend(), S.CONFIG_DEFAULTS)
    assert {"ok", "trades", "netPts"}.issubset(r)


def test_context_empty_is_honest():
    for fn in (S.prove_context_a, S.prove_context_b):
        r = fn([], S.CONFIG_DEFAULTS)
        assert r["ok"] is False and r["trades"] == 0


# ===========================================================================
# Task 8 — full-roster registration + capture live-fire dispatch
# ===========================================================================
ROSTER = ["meanrev", "breakout", "research", "momentum", "structure", "regime",
          "channel", "context_a", "context_b"]


def test_roster_registered_everywhere():
    for e in ROSTER:
        assert e in S.PROVERS, f"{e} missing from PROVERS"
        assert e in S.ENGINE_TRADES, f"{e} missing from ENGINE_TRADES"
        assert e in S._KNOWN_ENGINES, f"{e} missing from _KNOWN_ENGINES"
        assert e in S.CONFIG_DEFAULTS["engines"], f"{e} missing from default engines"


def test_capture_signal_dispatch_covers_roster():
    import bltd_capture as C
    assert set(C.ENGINES) == set(ROSTER)
    for e in C.ENGINES:
        assert e in S.PROVERS


def test_capture_signal_produces_each_new_engine_direction():
    # The live-fire _signal path must yield a real signal (or honest None) for every engine
    # on a series that triggers it — never crash, never an unknown-engine surprise.
    import bltd_capture as C

    class _StubStore:
        def config(self):
            return S.CONFIG_DEFAULTS

    cap = C.Capture(_StubStore(), bar_seconds=15, lookback=20, edge_gate=True)
    up = _consensus_uptrend()
    dn = _downtrend()
    # momentum/regime/context_* go long on the uptrend; structure goes short on the downtrend
    assert cap._signal("momentum", up)["direction"] == "long"
    assert cap._signal("regime", up)["direction"] == "long"
    assert cap._signal("context_a", up)["direction"] == "long"
    bsig = cap._signal("structure", dn)
    assert bsig is not None and bsig["direction"] == "short"
    assert cap._signal("structure", up) is None or cap._signal("structure", up)["direction"] == "short"


def _capture_stub_store():
    class _StubStore:
        def config(self): return {}
        def record_tick(self, *a, **k): pass
        def record_bars(self, *a, **k): return 0
        def ohlc(self, *a, **k): return []
    return _StubStore()


def test_stream_once_rehooks_on_silent_stall():
    # ROOT-CAUSE LOCK: when the WC hook goes silent (frames stop arriving) while still
    # "connected", stream_once must STOP — so main() re-hooks on a FRESH attach — instead of
    # spinning on a dead socket forever (which froze the store ~21 min and dropped the chart to
    # "connected · quiet"). WC streams candles continuously while a chart is open (even a flat
    # market prints repeat candles), so "no candle for stall_seconds" reliably means a dead hook.
    import bltd_capture as C
    state = {"t": 0.0, "silent": False}

    def clock():
        state["t"] += 100.0 if state["silent"] else 1.0
        return state["t"]

    frames = ["C", "C", "C"]                       # three candles, then silence forever

    class _WS:
        def __init__(self): self.i = 0
        def recv_text(self):
            if self.i < len(frames):
                self.i += 1
                return frames[self.i - 1]
            state["silent"] = True                 # hook has gone quiet
            return None
        def close(self): pass

    orig = C._frame_candle
    C._frame_candle = lambda raw: {"symbol": "CM.ESU6", "close": 1.0, "epoch": None} if raw == "C" else None
    try:
        res = C.stream_once(_capture_stub_store(), stall_seconds=45, _ws=_WS(), _clock=clock)
    finally:
        C._frame_candle = orig
    assert res.get("stalled") is True, f"silent hook must trigger a re-hook, got {res}"
    assert res["candles"] == 3, res


def test_stream_once_no_false_stall_while_candles_flow():
    # A healthy, streaming feed must NOT trip the watchdog (no false re-hook mid-stream).
    import bltd_capture as C
    state = {"t": 0.0}

    def clock():
        state["t"] += 1.0
        return state["t"]

    frames = ["C"] * 10

    class _WS:
        def __init__(self): self.i = 0
        def recv_text(self):
            if self.i < len(frames):
                self.i += 1
                return frames[self.i - 1]
            return None
        def close(self): pass

    orig = C._frame_candle
    C._frame_candle = lambda raw: {"symbol": "CM.ESU6", "close": 1.0, "epoch": None} if raw == "C" else None
    try:
        res = C.stream_once(_capture_stub_store(), stall_seconds=45, max_seconds=5, _ws=_WS(), _clock=clock)
    finally:
        C._frame_candle = orig
    assert not res.get("stalled"), f"healthy stream must not trip the watchdog: {res}"


def test_config_sanitizes_to_known_engines_only():
    clean = S._sanitize({"engines": ["momentum", "bogus", "regime"]})
    assert clean["engines"] == ["momentum", "regime"]   # unknown dropped, known kept in order


# ---- WC candle frame parsing (BOTH live shapes WC actually sends) -----------
# WC's realtime feed sends two candle frame variants on the same socket:
#   1. the historical/realtime bar shape with a real Unix epoch in `cepoch`
#   2. the intraday tick shape that carries `cts` (exchange-session seconds, NOT a Unix
#      epoch) and no `cepoch`. Both are genuine candles for the same symbol; dropping the
#      `cts` shape (the prior bug) silently starved the store of every live tick whenever WC
#      was emitting the tick variant -> the chart never filled. We must accept both, never
#      fabricate a timestamp, and let the capture loop stamp the no-embedded-epoch ticks with
#      their real arrival wall-clock.
def test_parse_candle_cepoch_shape():
    frame = ('{"cmd":"feed","data":{"type":"candle","c":"US.SPY","candle":'
             '{"co":100.0,"cM":101.0,"cm":99.0,"cc":100.5,"cepoch":1781045182,"type":"rt"}}}')
    cd = S.parse_candle(frame)
    assert cd is not None
    assert cd["symbol"] == "US.SPY" and cd["close"] == 100.5
    assert cd["epoch"] == 1781045182          # real embedded epoch preserved


def test_parse_candle_cts_shape_kept_with_no_epoch():
    # The exact intraday tick shape observed live on app.wealthcharts.com (cts, no cepoch).
    frame = ('{"cmd":"feed","data":{"type":"candle","c":"CM.ESU6","candle":'
             '{"cnu":1,"co":7546.50,"cm":7546.50,"cM":7546.50,"cc":7546.50,"cts":72427,"cq":"x"}}}')
    cd = S.parse_candle(frame)
    assert cd is not None, "cts-shape candle must NOT be dropped"
    assert cd["symbol"] == "CM.ESU6" and cd["close"] == 7546.50
    assert cd["epoch"] is None                # no real epoch -> None (never fabricated)


def test_parse_candle_drops_valueless_and_nonfeed():
    assert S.parse_candle('{"cmd":"keepalive","ref":1}') is None
    # candle with neither a close nor an epoch is junk -> dropped
    assert S.parse_candle('{"cmd":"feed","data":{"type":"candle","c":"X","candle":{}}}') is None
    # bidask frame is not a candle
    assert S.parse_candle('{"cmd":"feed","data":{"type":"bidask","c":"X"}}') is None


def test_on_candle_uses_arrival_when_epoch_missing():
    # A cts-shape candle (epoch None) must be persisted as a tick stamped at its ARRIVAL time,
    # not crash and not be dropped. Proves the store actually receives the live price.
    import bltd_capture as C

    recorded = {}

    class _StubStore:
        def config(self):
            return S.CONFIG_DEFAULTS

        def record_tick(self, sym, price, ep):
            recorded[sym] = (price, ep)

        def record_bars(self, *a, **k):
            return 0

        def ohlc(self, *a, **k):
            return []

    cap = C.Capture(_StubStore(), bar_seconds=15, lookback=20, edge_gate=True)
    arrival = 1781853600.0
    cap.on_candle({"symbol": "CM.ESU6", "close": 7546.5, "epoch": None}, arrival=arrival)
    assert "CM.ESU6" in recorded, "no-epoch candle must still record a live tick"
    price, ep = recorded["CM.ESU6"]
    assert price == 7546.5
    assert ep == int(arrival)                 # stamped at the real arrival wall-clock


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
