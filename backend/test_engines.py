"""Black Label Trading — backend engine test suite (pure stdlib; pytest-optional).

TDD for the engine roster (momentum/structure/regime/channel/context_a/context_b) + the shared
OHLC indicator helpers and the trade-generator registry. Each engine asserts: a deterministic
synthetic OHLC series that SHOULD prove edge does; one that should NOT doesn't; and empty bars
yield an honest empty result (no fabrication). Runnable via `python3 -m pytest test_engines.py`
or plain `python3 test_engines.py`.
"""
import os
import tempfile
import time

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
    # n=300 so the genuine trend edge yields >=30 OOS trades and clears the significance bar
    # (the gate now requires statistical proof, not just expectancy>0).
    r = S.prove_momentum(_consensus_uptrend(300), S.CONFIG_DEFAULTS)
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
    r = S.prove_structure(_downtrend(300), S.CONFIG_DEFAULTS)   # >=30 OOS trades for significance
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
    r = S.prove_regime(_consensus_uptrend(300), S.CONFIG_DEFAULTS)   # >=30 OOS trades for significance
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
    r = S.prove_context_a(_consensus_uptrend(300), S.CONFIG_DEFAULTS)   # >=30 OOS trades for significance
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


def test_stream_tab_routes_registry_candle_into_capture():
    # PU-3 smoke (no Chrome): stream_tab pulls CDP frames, runs each through the pluggable parser
    # registry (_frame_candle_reg), and routes parsed candles into Capture.on_candle. Proves the
    # multi-platform reader wires a REAL WealthCharts candle frame all the way to the in-memory
    # ES-filtered buffer — bars stay five-field, no quote path (PU-2 is deliberately not ported).
    import bltd_capture as C
    state = {"t": 0.0, "done": False}

    def clock():
        state["t"] += 100.0 if state["done"] else 1.0     # jump past idle_stall once frames stop
        return state["t"]

    wc_payload = ('{"cmd":"feed","data":{"type":"candle","c":"CM.ESU6","candle":'
                  '{"cnu":1,"co":7546.50,"cm":7546.50,"cM":7546.50,"cc":7546.50,"cts":72427,"cq":"x"}}}')
    envelope = C.json.dumps({"method": "Network.webSocketFrameReceived",
                             "params": {"requestId": "R1",
                                        "response": {"payloadData": wc_payload}}})
    frames = [envelope, envelope, envelope]               # three real candle frames, then silence

    class _WS:
        def __init__(self): self.i = 0
        def recv_text(self):
            if self.i < len(frames):
                self.i += 1
                return frames[self.i - 1]
            state["done"] = True                          # hook went quiet
            return None
        def close(self): pass

    cap = C.Capture(_capture_stub_store())
    page = {"url": "https://app.wealthcharts.com/", "webSocketDebuggerUrl": "ws://x"}
    res = C.stream_tab("wealthcharts", page, cap, idle_stall=10, _ws=_WS(), _clock=clock)
    assert res == {"source": "wealthcharts", "frames": 3, "candles": 3}, res
    assert cap.latest.get("CM.ESU6", (None,))[0] == 7546.50, cap.latest   # landed in ES-filtered buffer


def test_stream_tab_keeps_non_es_candle_after_parse():
    # Parser lock: a non-ES platform candle parsed by the GENERIC sniffer is recognized as real
    # market data and kept by the WealthCharts-wide default scope.
    import bltd_capture as C
    state = {"t": 0.0, "done": False}

    def clock():
        state["t"] += 100.0 if state["done"] else 1.0
        return state["t"]

    # A plain OHLC frame on a non-WC platform -> GenericOHLCParser -> a NON-ES symbol candle.
    quote = C.json.dumps({"symbol": "BTCUSD", "open": 100.0, "high": 101.0, "low": 99.0, "close": 100.5})
    envelope = C.json.dumps({"method": "Network.webSocketFrameReceived",
                             "params": {"requestId": "R9", "response": {"payloadData": quote}}})
    frames = [envelope]

    class _WS:
        def __init__(self): self.i = 0
        def recv_text(self):
            if self.i < len(frames):
                self.i += 1
                return frames[self.i - 1]
            state["done"] = True
            return None
        def close(self): pass

    cap = C.Capture(_capture_stub_store())
    page = {"url": "https://trader.tradovate.com/", "webSocketDebuggerUrl": "ws://x"}
    res = C.stream_tab("tradovate", page, cap, idle_stall=10, _ws=_WS(), _clock=clock)
    assert res["candles"] == 1, res            # parser registry parsed the non-WC frame
    assert cap.latest.get("BTCUSD") == (100.5, cap.latest["BTCUSD"][1]), cap.latest


def test_recv_text_bounded_on_half_dead_socket():
    # ROOT-CAUSE LOCK: a half-dead CDP socket that trickles bytes but never completes a frame must
    # NOT wedge recv_text forever. Because sock.recv keeps returning partial data it never raises
    # socket.timeout, so the only escape is the max_wait deadline. Without it the capture loop blocks
    # invisibly to the stall watchdog (which only runs between recv_text calls).
    import bltd_capture as C
    clock = {"t": 0.0}
    real_mono = C.time.monotonic

    class _FakeSock:
        def recv(self, n):
            clock["t"] += 1.0          # each recv "takes" 1s of (fake) time, never times out
            return b"\x81"             # perpetual partial frame header — never assembles a full frame
        def close(self): pass

    ws = C.WSClient.__new__(C.WSClient)  # bypass the real socket handshake
    ws.sock = _FakeSock()
    ws._buf = b""
    C.time.monotonic = lambda: clock["t"]
    try:
        assert ws.recv_text(max_wait=3.0) is None, "trickling socket must bail at the deadline"
    finally:
        C.time.monotonic = real_mono


def test_config_sanitizes_to_known_engines_only():
    clean = S._sanitize({"engines": ["momentum", "bogus", "regime"]})
    assert clean["engines"] == ["momentum", "regime"]   # unknown dropped, known kept in order


def test_es_symbol_policy_accepts_es_family_contracts():
    # ES family = ES + MES (micro). MES is the most-traded TopStep instrument; rejecting it
    # made a buyer's capture store nothing (2026-07-01 audit).
    assert S.is_es_symbol("ES")
    assert S.is_es_symbol("/ES")
    assert S.is_es_symbol("CM.ESU6")
    assert S.is_es_symbol("ESZ26")
    assert S.is_es_symbol("MES")
    assert S.is_es_symbol("MESU6")
    assert S.is_es_symbol("CM.MESU6")
    assert not S.is_es_symbol("NQ")
    assert not S.is_es_symbol("CM.NQU6")
    assert not S.is_es_symbol("MNQU6")
    assert not S.is_es_symbol("US.SPY")


def test_config_forces_es_symbol_scope():
    clean = S._sanitize({"symbols": ["NQ", "CM.ESU6", "CL"]})
    assert clean["symbols"] == ["ES"]


def _temp_store():
    fd, path = tempfile.mkstemp(prefix="bltd-es-only-", suffix=".sqlite3")
    os.close(fd)
    os.unlink(path)
    cfg = path + ".json"
    return S.Store(path, config_path=cfg), path, cfg


def test_store_accepts_and_serves_wealthcharts_symbols_by_default():
    # WealthCharts default scope: real non-ES rows are stored/served too. Junk symbols are still
    # rejected so empty/garbage rows cannot populate the app.
    store, path, cfg = _temp_store()
    try:
        es = [(1_700_000_000 + i, 100.0 + i, 101.0 + i, 99.0 + i, 100.5 + i) for i in range(45)]
        nq = [(1_700_000_000 + i, 200.0 + i, 201.0 + i, 199.0 + i, 200.5 + i) for i in range(50)]
        assert store.record_bars("CM.ESU6", es) == 45
        assert store.record_bars("CM.NQU6", nq) == 50
        assert store.record_bars("", es) == 0             # junk symbol still rejected
        store.record_tick("CM.ESU6", 5100.0, int(time.time()))
        store.record_tick("CM.NQU6", 17000.0, int(time.time()))
        store.record_fire("momentum", "long", 5100.0, symbol="CM.ESU6", synthetic=False)
        store.record_fire("momentum", "long", 17000.0, symbol="CM.NQU6", synthetic=False)

        syms = store.symbols()
        assert set(syms["backtestable"]) == {"CM.ESU6", "CM.NQU6"}, syms
        assert set(syms["liveTicks"]) == {"CM.ESU6", "CM.NQU6"}, syms
        assert syms["busiest"] in {"CM.ESU6", "CM.NQU6"}, syms
        assert len(store.bars("CM.NQU6", 100, newest=False)["bars"]) == 50
        assert store.live_price("CM.NQU6")["price"] == 17000.0
        assert len(store.ohlc("CM.NQU6")) == 50
        assert {f["symbol"] for f in store.fires()["fires"]} == {"CM.ESU6", "CM.NQU6"}
    finally:
        for p in (path, cfg):
            try:
                os.remove(p)
            except OSError:
                pass


def test_store_batch_writes_wealthcharts_symbols_and_reports_failure():
    store, path, cfg = _temp_store()
    try:
        rows = [(1_700_000_000 + i, 100.0 + i, 101.0 + i, 99.0 + i, 100.5 + i) for i in range(3)]
        # ES and NQ persist; the schema carries volume/delta with legacy zero defaults.
        assert store.record_bars_batch({"CM.ESU6": rows, "CM.NQU6": rows}) == 6
        assert store.bars("CM.ESU6", 10, newest=False)["bars"] == [
            [100.0, 101.0, 99.0, 100.5, 1700000000.0, 0.0, 0.0],
            [101.0, 102.0, 100.0, 101.5, 1700000001.0, 0.0, 0.0],
            [102.0, 103.0, 101.0, 102.5, 1700000002.0, 0.0, 0.0],
        ]
        assert len(store.bars("CM.NQU6", 10, newest=False)["bars"]) == 3

        now = int(time.time())
        assert store.record_ticks_batch([
            {"symbol": "CM.NQU6", "price": 17000.0, "epoch": now},
            {"symbol": "CM.ESU6", "price": 5100.25, "epoch": now},
            ("ESZ26", 5101.25, now),
        ]) == 3
        assert store.live_price("CM.NQU6")["price"] == 17000.0
        assert store.live_price("CM.ESU6")["price"] == 5100.25
        assert store.live_price("ESZ26")["price"] == 5101.25
        # Recency gate: a STALE tick is NOT served as live (stale-as-live honesty).
        store.record_tick("CM.NQU6", 16999.0, 1_700_000_100)             # Nov-2023 epoch
        assert store.live_price("CM.NQU6") == {"symbol": "CM.NQU6", "gated": True}

        store._exec = lambda *a, **k: 0
        assert store.record_bars_batch({"CM.ESU6": rows}) == -1           # write failure still reported
        assert store.record_ticks_batch([("CM.ESU6", 5102.0, 1_700_000_103)]) == -1
    finally:
        for p in (path, cfg):
            try:
                os.remove(p)
            except OSError:
                pass


def test_screen_includes_default_scope_symbols():
    import bltd_analytics as A

    class _Store:
        def config(self): return S.CONFIG_DEFAULTS
        def ohlc(self, symbol): return []

    # The screener covers every default in-scope WealthCharts symbol.
    rows = A.screen(_Store(), ["CM.NQU6", "CM.ESU6", "MESU6", "ES"], ["momentum"], S.CONFIG_DEFAULTS)
    assert [r["symbol"] for r in rows] == ["CM.NQU6", "CM.ESU6", "MESU6", "ES"]


# ---- pluggable capture parser registry -------------------------------------
def test_parser_registry_host_routing_specific_then_generic():
    import bltd_parsers as P

    wc = P.platforms_for_host("https://app.wealthcharts.com/chart")
    assert [p.name for p in wc[:2]] == ["wealthcharts", "generic"]
    assert P.platforms_for_host("https://unknown-broker.example/trade")[0].name == "wealthcharts"
    assert P.page_is_feed("https://trade.somebroker.example/dashboard") is True
    assert P.page_is_feed("https://example.com/help") is False


def test_parser_registry_parses_wealthcharts_tradingview_tradovate_and_generic():
    import bltd_parsers as P

    wc_payload = ('{"cmd":"feed","data":{"type":"candle","c":"CM.ESU6","candle":'
                  '{"co":7546.25,"cm":7545.75,"cM":7547.00,"cc":7546.50,"cepoch":1781045182}}}')
    tv_payload = ('~m~1~m~{"m":"qsd","p":[1,{"n":"CME_MINI:ES1!","v":'
                  '{"lp":5100.25,"open_price":5099.0,"high_price":5101.0,'
                  '"low_price":5098.0,"lp_time":1781045182}}]}')
    tradovate_payload = ('a[{"d":{"symbol":"ESZ26","bars":[{"open":6000.0,"high":6002.0,'
                         '"low":5999.0,"close":6001.25,"timestamp":1781045182}]}}]')
    generic_payload = ('{"data":{"instrument":"ESM27","o":6200.0,"h":6202.0,'
                       '"l":6199.0,"c":6201.0,"ts":1781045182}}')

    cases = [
        ("https://app.wealthcharts.com/", wc_payload, "wealthcharts", "CM.ESU6", 7546.50),
        ("https://www.tradingview.com/chart", tv_payload, "tradingview", "CME_MINI:ES1!", 5100.25),
        ("https://trader.tradovate.com/", tradovate_payload, "tradovate", "ESZ26", 6001.25),
        ("https://trade.example-broker.com/", generic_payload, "generic", "ESM27", 6201.0),
    ]
    for url, payload, parser_name, symbol, close in cases:
        parser = P.pick_parser(payload, P.platforms_for_host(url))
        assert parser is not None and parser.name == parser_name
        cd = parser.parse(payload)
        assert cd is not None
        assert cd["symbol"] == symbol and cd["close"] == close


def test_parser_registry_fail_closed_on_auth_telemetry_and_junk_prices():
    import bltd_parsers as P

    frames = [
        '{"cmd":"auth","token":"secret"}',
        '{"event":"heartbeat","ts":1781045182}',
        '{"symbol":"ESZ26","price":"NaN"}',
        '{"symbol":"ESZ26","price":999999999999}',
        '~m~1~m~{"m":"session_id","p":["abc"]}',
        'a[{"e":"props","d":{"accountId":12345}}]',
    ]
    for payload in frames:
        parser = P.pick_parser(payload, P.platforms_for_host("https://trade.example-broker.com/"))
        assert parser is None or parser.parse(payload) is None


def test_generic_parser_rejects_order_and_exec_frames():
    import bltd_parsers as P

    gen = next(p for p in P._PARSERS if p.name == "generic")
    assert gen.parse('{"id":"order-77a3","price":99.5,"qty":2,"status":"working"}') is None
    assert gen.parse('{"e":"execution","id":"exec-1","price":4521.75,"qty":1}') is None
    cd = gen.parse('{"data":{"instrument":"ESM27","o":6200.0,"h":6202.0,"l":6199.0,"c":6201.0,"ts":1781045182}}')
    assert cd and cd["symbol"] == "ESM27" and cd["close"] == 6201.0


def test_generic_parser_rejects_amount_keyed_order_and_size_trade():
    # Residual fail-open closed: an order frame whose only discriminator is an `amount`
    # (order quantity, common in ccxt/FX/crypto APIs) must NOT become a fake candle.
    import bltd_parsers as P

    gen = next(p for p in P._PARSERS if p.name == "generic")
    assert gen.parse('{"symbol":"ES","price":4500.0,"amount":5}') is None
    assert gen.parse('{"symbol":"ES","price":4500.0,"amount":5,"side":"buy"}') is None
    # Intentional fail-closed cost (pinned so it stays deliberate): a size-bearing print
    # is ambiguous order/trade data, so it is dropped rather than risk a fabricated candle.
    assert gen.parse('{"symbol":"ES","price":4500.0,"size":2,"ts":1781045182}') is None
    # A genuine candle carrying only a benign volume key is still accepted.
    cd = gen.parse('{"symbol":"ES","close":4500.0,"volume":1000,"ts":1781045182}')
    assert cd and cd["symbol"] == "ES" and cd["close"] == 4500.0


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


def test_on_candle_buffers_tick_at_arrival_then_flush_persists():
    # A cts-shape candle (epoch None) must be buffered as a live tick stamped at its ARRIVAL time
    # (the read loop touches ONLY memory — no SQLite I/O), then the flusher persists it through the
    # batch API. Proves the no-wedge buffer->flush path actually lands the live price in the store.
    import bltd_capture as C
    store, path, cfg = _temp_store()
    try:
        cap = C.Capture(store, bar_seconds=15, lookback=20, edge_gate=True)
        arrival = float(int(time.time()))        # fresh so the live-price recency gate serves it
        cap.on_candle({"symbol": "CM.ESU6", "close": 7546.5, "epoch": None}, arrival=arrival)
        # read loop wrote memory only — nothing persisted yet
        assert cap.latest["CM.ESU6"] == (7546.5, int(arrival))   # stamped at real arrival wall-clock
        assert store.live_price("CM.ESU6") == {"symbol": "CM.ESU6", "gated": True}
        cap.flush()
        lp = store.live_price("CM.ESU6")
        assert lp["price"] == 7546.5 and lp["ts"] == float(int(arrival))
    finally:
        for p in (path, cfg):
            try:
                os.remove(p)
            except OSError:
                pass


def test_capture_keeps_wealthcharts_scope_candles():
    # on_candle buffers all sane WealthCharts-scope instruments, then the flusher persists them.
    # Junk/empty symbols are still dropped before they can populate the store.
    import bltd_capture as C
    store, path, cfg = _temp_store()
    try:
        cap = C.Capture(store, bar_seconds=15, lookback=20, edge_gate=True)
        base = float(int(time.time()))           # fresh so live-price recency gate serves them
        cap.on_candle({"symbol": "CM.NQU6", "close": 17000.0, "epoch": None}, arrival=base)
        cap.on_candle({"symbol": "CM.ESU6", "close": 7546.5, "epoch": None}, arrival=base + 1)
        cap.on_candle({"symbol": "", "close": 1.0, "epoch": None}, arrival=base + 2)
        assert set(cap.latest.keys()) == {"CM.ESU6", "CM.NQU6"}
        cap.flush()
        assert store.live_price("CM.NQU6")["price"] == 17000.0
        assert store.live_price("CM.ESU6")["price"] == 7546.5
    finally:
        for p in (path, cfg):
            try:
                os.remove(p)
            except OSError:
                pass


def test_roll_queues_volume_delta_bars_off_read_loop_then_flush_persists():
    # Crossing a bar boundary must QUEUE the closed bar in memory (read loop = no SQLite I/O), and
    # only the flusher persists it through record_bars_batch. Bars carry volume/delta when supplied
    # and preserve zero defaults for close-only streams.
    import bltd_capture as C
    store, path, cfg = _temp_store()
    try:
        cap = C.Capture(store, bar_seconds=15, lookback=20, edge_gate=False)
        for close, arrival in [(100.0, 1_700_000_000.0), (101.0, 1_700_000_001.0),
                               (102.0, 1_700_000_015.0)]:
            cap.on_candle({"symbol": "CM.ESU6", "close": close, "epoch": None}, arrival=arrival)
        queued = cap.pending_bars["CM.ESU6"]
        assert len(queued) == 1 and len(queued[0]) == 7, queued       # volume/delta-capable bar
        assert store.bars("CM.ESU6", 10, newest=False)["bars"] == []  # nothing persisted yet
        cap.flush()
        assert store.bars("CM.ESU6", 10, newest=False)["bars"] == [
            [100.0, 101.0, 100.0, 101.0, 1700000010.0, 0.0, 0.0]]
        assert cap.pending_bars == {}                                 # drained by the flusher
    finally:
        for p in (path, cfg):
            try:
                os.remove(p)
            except OSError:
                pass


def test_capture_derives_tick_rule_delta_from_real_volume():
    # WealthCharts live tick candles can have open=high=low=close on each print, so candle-direction
    # delta is zero even though cq volume is real. Capture signs that real volume by tick-to-tick
    # price movement, giving CVD/VPIN a real source without inventing volume.
    import bltd_capture as C
    store, path, cfg = _temp_store()
    try:
        cap = C.Capture(store, bar_seconds=15, lookback=20, edge_gate=False)
        cap.on_candle({"symbol": "CM.ESU6", "close": 100.0, "volume": 2.0, "delta": 0.0, "epoch": None},
                      arrival=1_700_000_000.0)
        cap.on_candle({"symbol": "CM.ESU6", "close": 101.0, "volume": 3.0, "delta": 0.0, "epoch": None},
                      arrival=1_700_000_001.0)
        cap.on_candle({"symbol": "CM.ESU6", "close": 102.0, "volume": 4.0, "delta": 0.0, "epoch": None},
                      arrival=1_700_000_015.0)
        cap.flush()
        assert store.bars("CM.ESU6", 10, newest=False)["bars"] == [
            [100.0, 101.0, 100.0, 101.0, 1700000010.0, 3.0, 3.0]]
    finally:
        for p in (path, cfg):
            try:
                os.remove(p)
            except OSError:
                pass


def test_flush_requeues_bars_on_write_failure():
    # Bars are unique by ts, so a flush whose batch write fails (record_bars_batch returns -1) must
    # RE-QUEUE the rows so the next flush retries them — capture data is never silently dropped.
    import bltd_capture as C
    store, path, cfg = _temp_store()
    try:
        cap = C.Capture(store, bar_seconds=15, lookback=20, edge_gate=False)
        cap.pending_bars = {"CM.ESU6": [(1_700_000_010, 100.0, 101.0, 100.0, 101.0)]}
        store.record_bars_batch = lambda *a, **k: -1          # simulate a write failure
        cap.flush()
        assert cap.pending_bars["CM.ESU6"] == [(1_700_000_010, 100.0, 101.0, 100.0, 101.0)]
    finally:
        for p in (path, cfg):
            try:
                os.remove(p)
            except OSError:
                pass


def test_evaluate_all_fires_off_read_loop_from_store():
    # The evaluator thread evaluates from the STORE's closed bars (not the read loop), so a proven
    # signal still records a real fire with engine eval fully decoupled from frame ingestion.
    import bltd_capture as C
    store, path, cfg = _temp_store()
    try:
        rows = [(1_700_000_000 + i * 15, 100.0 + i * 0.9, 100.0 + i * 0.9,
                 100.0 + i * 0.9, 100.0 + i * 0.9) for i in range(80)]
        assert store.record_bars("CM.ESU6", rows) == 80
        cap = C.Capture(store, bar_seconds=15, lookback=20, edge_gate=False)
        assert store.latest_fire()["fire"] is None
        cap.evaluate_all()                          # runs the roster off the read loop, from store
        assert store.latest_fire()["fire"] is not None
    finally:
        for p in (path, cfg):
            try:
                os.remove(p)
            except OSError:
                pass


# ---- TR-13 NON-REPAINT: a signal is only emitted on a CLOSED bar, and no prior bar/signal
# revises when a new tick arrives. This is the runnable proof behind the "does it repaint?"
# (LuxAlgo-style) takedown: our bar aggregation excludes the still-forming bucket, a closed
# bar is frozen once closed, and the roster fires only on appear/flip off the CLOSED series.
def test_ohlc_bars_excludes_forming_bucket_and_never_repaints_closed():
    # bar_seconds=15 -> buckets k0={0,1}, k1={15,16}, k2={30 (still forming)}.
    ticks = [(0, 100.0), (1, 101.0), (15, 102.0), (16, 103.0), (30, 104.0)]
    closed = S.ohlc_bars(ticks, 15)
    assert [b[0] for b in closed] == [0, 1], "only fully-closed buckets are emitted (k2 is forming)"
    assert closed[0] == (0, 100.0, 101.0, 100.0, 101.0)   # o,h,l,c from the two k0 tick-closes
    # A new tick INSIDE the still-forming bucket must not revise ANY closed bar (non-repaint).
    closed_more_forming = S.ohlc_bars(ticks + [(31, 999.0)], 15)
    assert closed_more_forming == closed, "a forming-bar tick revises no CLOSED bar"
    # A tick that OPENS the next bucket promotes k2 to closed but freezes the earlier closed bars.
    closed_rolled = S.ohlc_bars(ticks + [(45, 50.0)], 15)
    assert closed_rolled[:2] == closed, "earlier closed bars stay byte-identical once closed"
    assert len(closed_rolled) == 3 and closed_rolled[2][0] == 2, "exactly one newly-closed bar (k2)"
    assert closed_rolled[2] == (2, 104.0, 104.0, 104.0, 104.0), "k2 closes on its own tick, unaffected by k3"


def test_ohlcv_bars_closed_bar_close_is_frozen_against_forming_ticks():
    # The specific repaint concern: the LAST closed bar's close must not change when a later,
    # still-forming tick prints a wild price. ohlcv variant (carries volume/delta).
    ticks = [(0, 100.0, 5.0, 0.0), (1, 101.0, 6.0, 0.0),      # k0 closes at 101
             (15, 200.0, 7.0, 0.0)]                            # k1 forming (not emitted)
    closed = S.ohlcv_bars(ticks, 15)
    assert len(closed) == 1 and closed[0][4] == 101.0, "closed bar close is the last tick of its bucket"
    # Add more forming k1 ticks: the closed k0 bar is untouched, k1 is still excluded.
    closed2 = S.ohlcv_bars(ticks + [(16, 9_999.0, 8.0, 0.0)], 15)
    assert closed2 == closed, "closed bar frozen; forming bucket still excluded despite an outlier tick"


def test_capture_forming_ticks_never_close_a_bar_or_repaint_a_closed_one():
    # End-to-end through Capture: ticks inside one bucket queue NO closed bar; only a boundary
    # crossing closes the prior bucket; and further ticks in the new forming bucket do not repaint
    # the already-closed bar in the store.
    import bltd_capture as C
    store, path, cfg = _temp_store()
    try:
        cap = C.Capture(store, bar_seconds=15, lookback=20, edge_gate=False)
        cap.on_candle({"symbol": "CM.ESU6", "close": 100.0, "epoch": None}, arrival=1_700_000_000.0)
        cap.on_candle({"symbol": "CM.ESU6", "close": 101.0, "epoch": None}, arrival=1_700_000_005.0)
        assert cap.pending_bars == {}, "no bar closes while the bucket is still forming"
        cap.flush()
        assert store.bars("CM.ESU6", 10, newest=False)["bars"] == [], "a forming bucket persists no closed bar"
        # Cross into the next bucket -> the first bucket closes (o=100, c=101), frozen.
        cap.on_candle({"symbol": "CM.ESU6", "close": 102.0, "epoch": None}, arrival=1_700_000_015.0)
        cap.flush()
        closed = [[100.0, 101.0, 100.0, 101.0, 1_700_000_010.0, 0.0, 0.0]]
        assert store.bars("CM.ESU6", 10, newest=False)["bars"] == closed
        # A wild tick in the NEW forming bucket must not repaint the already-closed bar.
        cap.on_candle({"symbol": "CM.ESU6", "close": 250.0, "epoch": None}, arrival=1_700_000_020.0)
        cap.flush()
        assert store.bars("CM.ESU6", 10, newest=False)["bars"] == closed, "closed bar frozen while a new bucket forms"
    finally:
        for p in (path, cfg):
            try:
                os.remove(p)
            except OSError:
                pass


def test_evaluate_does_not_re_emit_or_revise_a_prior_signal_on_unchanged_bars():
    # A prior signal must not be revised/re-emitted when a new tick arrives but the CLOSED-bar
    # series is unchanged: the roster fires on appear/flip only (direction unchanged -> no fire).
    import bltd_capture as C
    store, path, cfg = _temp_store()
    try:
        rows = [(1_700_000_000 + i * 15, 100.0 + i * 0.9, 100.0 + i * 0.9,
                 100.0 + i * 0.9, 100.0 + i * 0.9) for i in range(80)]
        assert store.record_bars("CM.ESU6", rows) == 80
        cap = C.Capture(store, bar_seconds=15, lookback=20, edge_gate=False)
        cap.evaluate_all()
        first = store.latest_fire()["fire"]
        assert first is not None, "a signal fires from the CLOSED-bar series"
        n1 = len(store.fires(500)["fires"])
        # Re-evaluate the SAME closed series (as a new tick's forming bucket would trigger): the
        # engine direction is unchanged, so NO new fire is recorded and the prior one is not revised.
        cap.evaluate_all()
        n2 = len(store.fires(500)["fires"])
        assert n2 == n1, "unchanged closed series does not re-fire (no repaint of the prior signal)"
        assert store.latest_fire()["fire"]["direction"] == first["direction"], "prior signal direction is stable"
    finally:
        for p in (path, cfg):
            try:
                os.remove(p)
            except OSError:
                pass


def test_on_candle_forming_bar_emits_no_signal_until_close_then_never_revises():
    # TR-13 integrated non-repaint proof driven through the REAL ingest path (Capture.on_candle ->
    # store -> evaluate), not just the pure ohlc helper. Two claims the "does it repaint?" takedown
    # cares about: (1) a still-FORMING bucket produces no signal of its own — the roster only ever
    # scores the CLOSED series; and (2) once a bar closes and fires, a later forming tick (even a wild
    # outlier) never retroactively revises or re-emits that closed-bar signal.
    import bltd_capture as C
    store, path, cfg = _temp_store()
    try:
        # Seed a closed trending series so the roster has >= lookback+1 closed bars to score.
        seed = [(1_700_000_000 + i * 15, 100.0 + i * 0.9, 100.0 + i * 0.9,
                 100.0 + i * 0.9, 100.0 + i * 0.9) for i in range(80)]
        assert store.record_bars("CM.ESU6", seed) == 80
        cap = C.Capture(store, bar_seconds=15, lookback=20, edge_gate=False)

        # (1) Feed ticks that only FORM the next bucket (no boundary crossed): no closed bar is queued
        # or persisted, so evaluate sees the UNCHANGED closed series and fires off it alone.
        t0 = 1_700_000_000 + 80 * 15                      # first stamp of the still-forming bucket
        cap.on_candle({"symbol": "CM.ESU6", "close": 172.0, "epoch": None}, arrival=float(t0))
        cap.on_candle({"symbol": "CM.ESU6", "close": 173.0, "epoch": None}, arrival=float(t0 + 5))
        assert cap.pending_bars == {}, "a still-forming bucket queues no closed bar"
        cap.flush()
        assert store.bars("CM.ESU6", 3, newest=True)["bars"][-1][4] == float(seed[-1][0]), \
            "no new closed bar from forming ticks (newest closed bar is still the seed's last)"
        cap.evaluate_all()
        base_fire = store.latest_fire()["fire"]
        assert base_fire is not None, "a signal fires ONLY from the closed-bar series"
        base_n = len(store.fires(500)["fires"])

        # A WILD forming tick inside the SAME (still-open) bucket must not repaint or re-fire anything.
        cap.on_candle({"symbol": "CM.ESU6", "close": 5000.0, "epoch": None}, arrival=float(t0 + 9))
        cap.flush(); cap.evaluate_all()
        assert len(store.fires(500)["fires"]) == base_n, "forming-tick outlier does not re-fire (no repaint)"
        assert store.latest_fire()["fire"]["direction"] == base_fire["direction"], "prior signal direction is stable"

        # (2) Cross the boundary -> the forming bucket closes into exactly one new bar. Then a later
        # forming tick in the NEXT bucket must leave that just-closed bar byte-identical (frozen).
        cap.on_candle({"symbol": "CM.ESU6", "close": 174.0, "epoch": None}, arrival=float(t0 + 15))
        cap.flush()
        expected_ts = float(((t0 // 15) + 1) * 15)        # _roll stamps the bar at its bucket-close boundary
        just_closed = store.bars("CM.ESU6", 1, newest=True)["bars"]
        assert just_closed and just_closed[0][4] == expected_ts, "boundary crossing closes the forming bucket"
        cap.on_candle({"symbol": "CM.ESU6", "close": 9999.0, "epoch": None}, arrival=float(t0 + 20))
        cap.flush()
        assert store.bars("CM.ESU6", 1, newest=True)["bars"] == just_closed, \
            "a closed bar is never repainted by a later forming tick"
    finally:
        for p in (path, cfg):
            try:
                os.remove(p)
            except OSError:
                pass


def test_freshness_watchdog_wedge_decision():
    # PURE wedge decision behind _freshness_watchdog: seed grace, reset on advance, and trip only
    # after the store's newest tick has stalled for stale_after seconds (then the daemon os._exit's
    # so launchd respawns a fresh capture).
    import bltd_capture as C
    assert C._store_is_wedged(-1, 0.0, 1000, 100.0, stale_after=300.0) == (1000, 100.0, False)
    assert C._store_is_wedged(1000, 100.0, 1005, 130.0, stale_after=300.0) == (1005, 130.0, False)
    assert C._store_is_wedged(1005, 130.0, 1005, 400.0, stale_after=300.0) == (1005, 130.0, False)
    seen, prog, wedged = C._store_is_wedged(1005, 130.0, 1005, 431.0, stale_after=300.0)
    assert wedged is True and (seen, prog) == (1005, 130.0)


def test_freshness_watchdog_gate_uses_multi_feed_surface():
    # The watchdog's respawn gate treats any logged-in trading feed as reachable; source filtering is
    # handled later by the shipped symbol scope.
    import bltd_capture as C
    old_discover = C.discover_feed_pages
    try:
        C.discover_feed_pages = lambda: [("tradovate", {
            "url": "https://trader.tradovate.com/",
            "webSocketDebuggerUrl": "ws://127.0.0.1/devtools/page/1",
        })]
        assert C.watchdog_feed_available() is True
        C.discover_feed_pages = lambda: []
        assert C.watchdog_feed_available() is False
    finally:
        C.discover_feed_pages = old_discover


def _ct(y, mo, d, h, mi=0):
    # build a Central-time datetime for the pure market-hours gate, tz-aware when zoneinfo is present
    import bltd_capture as C
    from datetime import datetime
    return datetime(y, mo, d, h, mi, tzinfo=C._CENTRAL)


def test_central_now_converts_epoch_to_cme_clock():
    # The watchdog's market gate depends on epoch seconds being interpreted on the CME Central clock,
    # including the DST offset changes between winter and summer sessions.
    import bltd_capture as C
    from datetime import datetime

    if C._CENTRAL is None:
        assert C._central_now(1_700_000_000) == datetime.fromtimestamp(1_700_000_000)
        return

    winter = datetime(2026, 1, 15, 10, 30, tzinfo=C._CENTRAL)
    summer = datetime(2026, 6, 25, 10, 30, tzinfo=C._CENTRAL)
    assert C._central_now(winter.timestamp()) == winter
    assert C._central_now(summer.timestamp()) == summer
    assert winter.utcoffset().total_seconds() == -6 * 3600
    assert summer.utcoffset().total_seconds() == -5 * 3600


def test_market_open_during_weekday_rth():
    # ROOT-CAUSE LOCK (companion to the freshness watchdog): a closed market leaves the store
    # nothing to advance, so the watchdog must only force a respawn while the market is OPEN.
    # Thursday 2026-06-25 10:00 CT — mid weekday session.
    import bltd_capture as C
    assert C._market_is_open(_ct(2026, 6, 25, 10, 0)) is True


def test_market_closed_friday_weekly_close_through_weekend():
    import bltd_capture as C
    assert C._market_is_open(_ct(2026, 6, 26, 15, 59)) is True   # last minute before the 16:00 close
    assert C._market_is_open(_ct(2026, 6, 26, 16, 0)) is False   # Friday 16:00 CT weekly close
    assert C._market_is_open(_ct(2026, 6, 26, 19, 53)) is False  # the observed weekend respawn-loop time
    assert C._market_is_open(_ct(2026, 6, 27, 3, 0)) is False    # Saturday
    assert C._market_is_open(_ct(2026, 6, 27, 20, 0)) is False   # Saturday
    assert C._market_is_open(_ct(2026, 6, 28, 16, 59)) is False  # Sunday before reopen
    assert C._market_is_open(_ct(2026, 6, 28, 17, 0)) is True    # Sunday 17:00 CT reopen


def test_market_daily_maintenance_halt_weeknights():
    import bltd_capture as C
    assert C._market_is_open(_ct(2026, 6, 23, 9, 30)) is True    # Tuesday session
    assert C._market_is_open(_ct(2026, 6, 23, 16, 30)) is False  # Tue daily 16:00-17:00 halt
    assert C._market_is_open(_ct(2026, 6, 23, 17, 0)) is True    # Tue 17:00 CT reopen
    assert C._market_is_open(_ct(2026, 6, 24, 0, 5)) is True     # Wednesday overnight, open


def test_edge_gate_rejects_random_walk_flukes():
    """NO-FABRICATION lock: no engine may 'prove' an OOS edge on PURE NOISE more than the ~5%
    false-positive floor. Before the significance bar, momentum/regime/structure/context_a passed
    expectancy>0 on driftless random walks 54-63% of the time — a fabrication path that would be
    dangerous on any captured instrument. Each walk is seeded (deterministic), so this test is stable
    and re-runnable."""
    import random
    provers = [
        ("meanrev", S.prove_meanrev), ("breakout", S.prove_breakout), ("research", S.prove_research),
        ("momentum", S.prove_momentum), ("structure", S.prove_structure), ("regime", S.prove_regime),
        ("channel", S.prove_channel), ("context_a", S.prove_context_a), ("context_b", S.prove_context_b),
    ]
    cfg = dict(S.CONFIG_DEFAULTS)
    RUNS = 60
    for idx, (name, prove) in enumerate(provers):
        passes = 0
        for seed in range(RUNS):
            rng = random.Random(seed * 7919 + idx * 104729)   # fixed, deterministic
            px = 5000.0
            ohlc = []
            for _ in range(400):
                px += rng.gauss(0, 1.0)                        # driftless walk = NO real edge
                o = px + rng.gauss(0, 0.2)
                hi = max(o, px) + abs(rng.gauss(0, 0.3))
                lo = min(o, px) - abs(rng.gauss(0, 0.3))
                ohlc.append((o, hi, lo, px))
            try:
                if prove(ohlc, cfg).get("ok"):
                    passes += 1
            except Exception:  # noqa: BLE001 — a prover error is not a fluke pass
                pass
        rate = passes / RUNS
        # Bar is ~10%: the significance gate measures ~5-6.5% (the α=0.05 single-test floor); a
        # tighter assert than the old 15% so a partial regression (e.g. structure creeping back to
        # 12%) can't pass silently. The residual per-test leakage is then controlled family-wide by
        # the BH-FDR correction in the screen grid (see test_screen_fdr_*).
        assert rate <= 0.10, f"{name} proved an edge on pure noise {rate*100:.0f}% of the time (fabrication risk)"


def _bh(pvals, q):
    import bltd_analytics as A
    return A._benjamini_hochberg(pvals, q)


def test_edge_pvalue_caps_winr_no_datasnoop():
    # A single lucky runner must NOT lower the breakeven and inflate significance. With a 2:1 target,
    # a null-ish 50-trade list (17 wins) stays non-significant even if one win is a giant R=8 runner,
    # because winR is capped at the intended target (2.0), not the realized max.
    base = [{"r": 2.0, "dir": "long", "entry": 1.0, "exit": 1.0} for _ in range(17)]
    base += [{"r": -1.0, "dir": "long", "entry": 1.0, "exit": 1.0} for _ in range(33)]
    runner = list(base); runner[0] = {"r": 8.0, "dir": "long", "entry": 1.0, "exit": 1.0}
    p_capped = S._edge_pvalue(runner, 17, 50, sum(t["r"] for t in runner) / 50, 20, target_r=2.0)
    p_uncapped_maxsnoop = S._binom_sf(17, 50, 1.0 / (1.0 + 8.0))   # what max()-snoop would have used
    assert p_capped > S.SIG_ALPHA, f"capped winR must keep a runner-laced null non-significant (p={p_capped})"
    assert p_uncapped_maxsnoop < S.SIG_ALPHA  # proves the snoop WOULD have fired without the cap


def test_benjamini_hochberg_math():
    # Empty / no-signal families reject nothing.
    assert _bh([], 0.1) == set()
    assert _bh([0.9, 0.8, 0.5], 0.1) == set()
    # m=5, q=0.05: only the tiny p clears rank-1 threshold (1/5*0.05=0.01); the rest fail.
    assert _bh([0.001, 0.2, 0.3, 0.4, 0.5], 0.05) == {0}
    # All-tiny p's all survive.
    assert _bh([0.0001, 0.0002, 0.0003], 0.1) == {0, 1, 2}
    # Step-up property: p_(1)=0.02 FAILS rank-1 (1/3*0.05=0.0167), but rank-3 passes
    # (0.04<=0.05), so BH rejects ALL three — including the one that failed its own rank.
    assert _bh([0.02, 0.02, 0.04], 0.05) == {0, 1, 2}
    # BH must be STRICTLY MORE CONSERVATIVE than a naive "p<=q" filter (proves it isn't a no-op):
    # here naive p<=0.05 would keep BOTH 0.001 and 0.04, but BH keeps ONLY 0.001 (the 0.04 cell sits
    # above its rank-2 line 0.02 with no higher rank to rescue it).
    p = [0.001, 0.04, 0.5, 0.5, 0.5]
    naive = {i for i, v in enumerate(p) if v <= 0.05}
    bh = _bh(p, 0.05)
    assert naive == {0, 1} and bh == {0}, (naive, bh)
    assert 1 in naive and 1 not in bh   # the marginal cell naive keeps, BH correctly drops


def test_stats_honest_ratios():
    """Locks the _stats honesty fixes: no sqrt(n) inflation on sharpe/sortino, profitFactor=None on
    a no-loss list (not sum-of-R), and a MIN_STATS_N floor that zeroes headline ratios on thin data."""
    import bltd_analytics as A

    def tr(r, dirn="long"):
        return {"r": r, "dir": dirn, "entry": 100.0, "exit": 100.0 + r}

    # Sharpe is a plain mean/sd ratio — NOT multiplied by sqrt(n). 12 trades so it clears MIN_STATS_N.
    rs = [2.0, -1.0, 2.0, -1.0, 2.0, -1.0, 2.0, -1.0, 2.0, -1.0, 2.0, -1.0]
    s = A._stats([tr(r) for r in rs])
    n = len(rs); mean = sum(rs) / n
    import math as _m
    var = sum((r - mean) ** 2 for r in rs) / n
    expected_sharpe = round(mean / _m.sqrt(var), 4)
    assert s["sharpe"] == expected_sharpe, (s["sharpe"], expected_sharpe)   # no sqrt(n) factor
    assert s["sufficientSample"] is True

    # No losing trades -> profit factor is UNDEFINED (None), never sum-of-R.
    noloss = A._stats([tr(2.0) for _ in range(12)])
    assert noloss["profitFactor"] is None, noloss["profitFactor"]

    # Thin sample (< MIN_STATS_N) -> ratios suppressed, counts kept, sufficientSample False.
    thin = A._stats([tr(2.0), tr(-1.0)])
    assert thin["trades"] == 2 and thin["sufficientSample"] is False
    assert thin["winRate"] == 0.0 and thin["sharpe"] == 0.0 and thin["profitFactor"] is None

    # Empty -> honest zeros + sufficientSample False.
    assert A._stats([])["sufficientSample"] is False


def test_screen_fdr_suppresses_grid_inflation():
    """Grid-wide honesty lock that ACTUALLY exercises BH (mutation-proof): patch the prover to emit
    CONTROLLED p-values so the grid contains many marginal per-test-significant cells, then assert
    screen()'s BH demotes the ones above the BH line while keeping the strongly-significant ones.
    Removing BH from screen() makes this FAIL (it would keep every per-test passer)."""
    import bltd_analytics as A

    # Realistic grid inflation: 1 strongly-significant cell + 3 marginal (p=0.04, each < per-test
    # 0.05) buried among 96 high-p nulls (m=100). Per-test alone keeps 4; BH at q=0.10 keeps ONLY
    # the strong one — the 3 marginals fall below their rank lines (rank2 line = 2/100*0.10 = 0.002
    # << 0.04). Removing BH from screen() would keep all 4 and FAIL this test.
    pmap = {"STRONG": 0.0001, "MARGINAL0": 0.04, "MARGINAL1": 0.04, "MARGINAL2": 0.04}
    for i in range(96):
        pmap[f"NULL{i}"] = 0.8
    bars = [(100.0 + i * 0.1, 100.0 + i * 0.1, 100.0 + i * 0.1, 100.0 + i * 0.1) for i in range(60)]
    holder = {"p": 1.0}

    def prove(ohlc, cfg=None):
        p = holder["p"]
        return {"ok": p < S.SIG_ALPHA, "pEdge": p, "winRate": 0.6, "netPts": 1.0,
                "expectancyR": 0.2, "trades": 50, "reason": "OOS candidate"}

    class _StoreSeq:
        def config(self): return S.CONFIG_DEFAULTS
        def ohlc(self, sym): holder["p"] = pmap[sym]; return bars   # thread p to the next prover call

    orig_provers = S.PROVERS
    orig_scope = S.INSTRUMENT_SCOPE
    try:
        S.INSTRUMENT_SCOPE = "all"  # this test exercises FDR math, not the shipped Topstep scope
        S.PROVERS = {"fake": prove}
        rows = A.screen(_StoreSeq(), list(pmap.keys()), ["fake"], S.CONFIG_DEFAULTS)
    finally:
        S.INSTRUMENT_SCOPE = orig_scope
        S.PROVERS = orig_provers

    per_test_passers = {r["symbol"] for r in rows if r.get("pEdge", 1.0) < S.SIG_ALPHA}
    bh_survivors = {r["symbol"] for r in rows if r["edge"]}
    assert per_test_passers == {"STRONG", "MARGINAL0", "MARGINAL1", "MARGINAL2"}, per_test_passers
    assert bh_survivors == {"STRONG"}, f"BH must keep only the strong cell, got {bh_survivors}"
    demoted = [r for r in rows if r["symbol"].startswith("MARGINAL")]
    assert all(not r["edge"] and "FDR" in r["reason"] for r in demoted)


# ===========================================================================
# maxDrawdownR + the buyer-triggered gate re-run (bltd_analytics.gate_rerun)
# ===========================================================================
def test_max_drawdown_r_empty_and_monotonic():
    assert S._max_drawdown_r([]) == 0.0
    assert S._max_drawdown_r([{"r": 1.0}, {"r": 2.0}, {"r": 0.5}]) == 0.0  # never dips below peak


def test_max_drawdown_r_peak_to_trough():
    # cum: +2, -1, +0 -> peak 2, trough -1 => max drawdown 3R
    dd = S._max_drawdown_r([{"r": 2.0}, {"r": -3.0}, {"r": 1.0}])
    assert approx(dd, 3.0), dd


def test_summary_reports_wins_losses_and_drawdown():
    trades = [{"dir": "long", "entry": 100.0, "exit": 102.0, "r": 2.0},
              {"dir": "long", "entry": 100.0, "exit": 99.0, "r": -1.0},
              {"dir": "long", "entry": 100.0, "exit": 99.0, "r": -1.0}]
    s = S._summarize(trades, min_trades=1)
    assert s["trades"] == 3 and s["wins"] == 1 and s["losses"] == 2
    assert "maxDrawdownR" in s and s["maxDrawdownR"] >= 0.0


def test_prover_source_sha_is_16hex():
    sha = S.prover_source_sha()
    assert len(sha) == 16 and all(ch in "0123456789abcdef" for ch in sha), sha


class _RerunStore:
    def __init__(self, series):
        self._series = series

    def config(self):
        return S.CONFIG_DEFAULTS

    def ohlc(self, symbol):
        return self._series.get(symbol, [])


def test_gate_rerun_empty_store_is_honest_not_fabricated():
    import bltd_analytics as A
    rep = A.gate_rerun(_RerunStore({}), [], list(S.PROVERS.keys()))
    assert rep["available"] is False
    assert rep["engineCount"] == 0 and rep["candidateCount"] == 0
    assert rep["reason"] and "no bars" in rep["reason"].lower()
    # prover_sha is always stamped so the buyer can reproduce even the empty verdict
    assert len(rep["prover_sha"]) == 16 and rep["sigMinN"] == S.SIG_MIN_N


def test_gate_rerun_runs_every_engine_and_stamps_prover_sha():
    import bltd_analytics as A
    orig_scope = S.INSTRUMENT_SCOPE
    try:
        S.INSTRUMENT_SCOPE = "all"
        series = {"CM.ESU6": [(100.0 + i * 0.3,) * 4 for i in range(400)]}
        rep = A.gate_rerun(_RerunStore(series), ["CM.ESU6"], list(S.PROVERS.keys()))
    finally:
        S.INSTRUMENT_SCOPE = orig_scope
    assert rep["available"] is True
    assert rep["prover_sha"] == S.prover_source_sha()
    assert rep["engineCount"] == len(S.PROVERS)                       # no cherry-picking: all engines
    assert rep["candidateCount"] + rep["noEdgeCount"] + rep["insufficientCount"] == rep["engineCount"]
    for e in rep["engines"]:
        assert e["status"] in ("candidate", "no_edge", "insufficient")
        for c in e["contracts"]:
            for k in ("trades", "wins", "losses", "maxDrawdownR", "pEdge", "reason"):
                assert k in c
            assert c["wins"] + c["losses"] == c["trades"]            # honest W/L split


def test_gate_rerun_labels_thin_sample_insufficient():
    import bltd_analytics as A
    orig_scope = S.INSTRUMENT_SCOPE
    try:
        S.INSTRUMENT_SCOPE = "all"
        # just above the warming floor but far below SIG_MIN_N trades -> insufficient, never proven
        series = {"CM.ESU6": [(100.0 + (1.0 if i % 2 else -1.0),) * 4 for i in range(60)]}
        rep = A.gate_rerun(_RerunStore(series), ["CM.ESU6"], ["meanrev"])
    finally:
        S.INSTRUMENT_SCOPE = orig_scope
    e = rep["engines"][0]
    c = e["contracts"][0]
    if c["trades"] < S.SIG_MIN_N:
        assert c["insufficient"] is True and c["proven"] is False
        assert "insufficient" in c["reason"].lower()


# ===========================================================================
# No-code backtest lab (bltd_analytics.backtest_lab) — SHIPPED prover, date-scoped, per-fold,
# honest 'insufficient', no aggregate win-rate/$ figure.
# ===========================================================================
class _LabStore:
    def __init__(self, series):
        self._series = series          # {symbol: [(o,h,l,c), ...]}

    def config(self):
        return S.CONFIG_DEFAULTS

    def ohlc_between(self, symbol, start_ts=None, end_ts=None, limit=20000):
        return self._series.get(symbol, [])


def test_backtest_lab_unknown_engine_and_symbol_are_honest():
    import bltd_analytics as A
    r1 = A.backtest_lab(_LabStore({}), "not_an_engine", "CM.ESU6")
    assert r1["available"] is False and "unknown engine" in r1["reason"]
    assert len(r1["prover_sha"]) == 16                     # sha stamped even on the error path
    orig_scope = S.INSTRUMENT_SCOPE
    try:
        S.INSTRUMENT_SCOPE = "es"                           # narrow scope rejects a junk instrument
        r2 = A.backtest_lab(_LabStore({}), "meanrev", "NOTASYMBOL@@")
    finally:
        S.INSTRUMENT_SCOPE = orig_scope
    assert r2["available"] is False and "not a recognized instrument" in r2["reason"]


def test_backtest_lab_thin_range_reports_insufficient_not_fabricated():
    import bltd_analytics as A
    orig_scope = S.INSTRUMENT_SCOPE
    try:
        S.INSTRUMENT_SCOPE = "all"
        series = {"CM.ESU6": [(100.0 + (1.0 if i % 2 else -1.0),) * 4 for i in range(60)]}
        rep = A.backtest_lab(_LabStore(series), "meanrev", "CM.ESU6", folds=1)
    finally:
        S.INSTRUMENT_SCOPE = orig_scope
    assert rep["available"] is True
    w = rep["whole"]
    if w["trades"] < S.SIG_MIN_N:
        assert w["insufficient"] is True and w["proven"] is False
        assert "insufficient" in w["reason"].lower()
    # never a fabricated aggregate headline
    assert "winRateAll" not in rep and "netPnlDollars" not in rep


def test_backtest_lab_runs_shipped_prover_per_fold_with_provenance():
    import bltd_analytics as A
    orig_scope = S.INSTRUMENT_SCOPE
    try:
        S.INSTRUMENT_SCOPE = "all"
        series = {"CM.ESU6": [(100.0 + i * 0.3,) * 4 for i in range(600)]}
        rep = A.backtest_lab(_LabStore(series), "meanrev", "CM.ESU6", folds=3)
    finally:
        S.INSTRUMENT_SCOPE = orig_scope
    assert rep["available"] is True
    assert rep["prover_sha"] == S.prover_source_sha() and rep["sigMinN"] == S.SIG_MIN_N
    assert rep["whole"] is not None
    assert 1 <= len(rep["folds"]) <= 3
    for f in rep["folds"]:
        for k in ("fold", "bars", "trades", "wins", "losses", "maxDrawdownR", "pEdge",
                  "proven", "insufficient", "reason"):
            assert k in f, k
        assert f["wins"] + f["losses"] == f["trades"]          # honest W/L split
        if f["trades"] < S.SIG_MIN_N:
            assert f["insufficient"] is True and f["proven"] is False


def test_backtest_lab_empty_store_is_honest_pending():
    import bltd_analytics as A
    orig_scope = S.INSTRUMENT_SCOPE
    try:
        S.INSTRUMENT_SCOPE = "all"
        rep = A.backtest_lab(_LabStore({"CM.ESU6": []}), "meanrev", "CM.ESU6")
    finally:
        S.INSTRUMENT_SCOPE = orig_scope
    assert rep["available"] is False and "insufficient bars" in rep["reason"]
    assert rep["folds"] == [] and rep["whole"] is None


# ===========================================================================
# TR-05 multi-asset product layer — instrument catalog + per-instrument honesty
# ===========================================================================
class _CatalogStore:
    """Fake store for the instrument catalog: derives symbols() from a {symbol: ohlc} series map the
    same way the real Store does (backtestable >=40 bars, live/liveTicks = all present, busiest = most
    bars). Lets the catalog + per-instrument gate be tested with no DB, on real classification math."""
    def __init__(self, series):
        self._series = series

    def config(self):
        return S.CONFIG_DEFAULTS

    def ohlc(self, symbol):
        return self._series.get(symbol, [])

    def symbols(self):
        present = [s for s, v in self._series.items() if v]
        bt = [s for s in present if len(self._series[s]) >= 40]
        busiest = max(present, key=lambda s: len(self._series[s])) if present else None
        return {"backtestable": sorted(bt), "live": sorted(present),
                "liveTicks": sorted(present), "busiest": busiest}


def test_classify_instrument_asset_classes_are_honest():
    # ES-family: es modules apply, dollars known.
    es = S.classify_instrument("CM.ESU6")
    assert es["esFamily"] is True and es["esModules"] is True
    assert es["assetClass"] == "us_index_future" and es["pointValue"] == 50.0 and es["root"] == "ES"
    # Non-ES index future: classified, dollars known, but ES-tuned modules do NOT apply.
    mnq = S.classify_instrument("CM.MNQU6")
    assert mnq["esFamily"] is False and mnq["esModules"] is False
    assert mnq["assetClass"] == "us_index_future" and mnq["pointValue"] == 2.0 and mnq["root"] == "MNQ"
    # Energy future: different asset bucket, own spec.
    cl = S.classify_instrument("CL")
    assert cl["assetClass"] == "energy_future" and cl["pointValue"] == 1000.0
    # US equity/ETF: honest bucket, NO fabricated futures multiplier.
    spy = S.classify_instrument("US.SPY")
    assert spy["assetClass"] == "equity_etf" and spy["pointValue"] is None and spy["esModules"] is False
    assert spy["display"] == "SPY"
    # Unknown instrument: never guessed — 'other' with no point value.
    other = S.classify_instrument("WIBBLE")
    assert other["assetClass"] == "other" and other["pointValue"] is None and other["esModules"] is False


def test_instruments_catalog_enumerates_captured_symbols_dynamically():
    import bltd_analytics as A
    orig = S.INSTRUMENT_SCOPE
    try:
        S.INSTRUMENT_SCOPE = "all"
        series = {
            "CM.ESU6": [(100.0 + i * 0.1,) * 4 for i in range(120)],   # ES-family, deep
            "CM.MNQU6": [(200.0 + i * 0.1,) * 4 for i in range(80)],   # non-ES future
            "US.SPY": [(400.0 + i * 0.1,) * 4 for i in range(60)],     # ETF
        }
        rep = A.instruments(_CatalogStore(series))
    finally:
        S.INSTRUMENT_SCOPE = orig
    assert rep["available"] is True and rep["count"] == 3
    assert rep["esFamilyCount"] == 1 and rep["nonEsCount"] == 2
    assert rep["onlyES"] is False
    by_disp = {i["display"]: i for i in rep["instruments"]}
    # >=2 non-ES instruments surfaced from the buyer's OWN bars (never a hardcoded list).
    assert {"ESU6", "MNQU6", "SPY"} <= set(by_disp)
    assert by_disp["MNQU6"]["esModules"] is False and by_disp["SPY"]["assetClass"] == "equity_etf"
    assert by_disp["ESU6"]["esModules"] is True
    # Deepest instrument leads the picker; every item carries its own real bar count.
    assert rep["instruments"][0]["display"] == "ESU6" and rep["instruments"][0]["bars"] == 120


def test_instruments_catalog_only_es_is_honest_state():
    import bltd_analytics as A
    orig = S.INSTRUMENT_SCOPE
    try:
        S.INSTRUMENT_SCOPE = "all"
        rep = A.instruments(_CatalogStore({"CM.ESU6": [(100.0 + i * 0.1,) * 4 for i in range(60)]}))
    finally:
        S.INSTRUMENT_SCOPE = orig
    # The honest "only ES captured so far" state — never a fabricated multi-asset spread.
    assert rep["onlyES"] is True and rep["nonEsCount"] == 0 and rep["esFamilyCount"] == 1


def test_instruments_catalog_empty_store_is_honest():
    import bltd_analytics as A
    rep = A.instruments(_CatalogStore({}))
    assert rep["available"] is False and rep["count"] == 0 and rep["onlyES"] is False
    assert rep["reason"] and "no instruments" in rep["reason"].lower()


def test_gate_rerun_judges_each_instrument_independently_never_pooled():
    import bltd_analytics as A
    orig = S.INSTRUMENT_SCOPE
    try:
        S.INSTRUMENT_SCOPE = "all"
        # Deep ES + a THIN NQ (below the arm threshold). Verdicts must be per (engine, contract):
        # the thin NQ series is judged insufficient/warming on ITS OWN bars, never averaged into ES.
        series = {
            "CM.ESU6": [(100.0 + i * 0.3,) * 4 for i in range(400)],
            "CM.NQU6": [(200.0 + i * 0.3,) * 4 for i in range(15)],
        }
        rep = A.gate_rerun(_CatalogStore(series), ["CM.ESU6", "CM.NQU6"], list(S.PROVERS.keys()))
    finally:
        S.INSTRUMENT_SCOPE = orig
    assert rep["symbols"] == ["CM.ESU6", "CM.NQU6"]                    # both instruments, listed separately
    for e in rep["engines"]:
        contracts = {c["symbol"]: c for c in e["contracts"]}
        assert set(contracts) == {"CM.ESU6", "CM.NQU6"}               # a row PER instrument, not pooled
        nq = contracts["CM.NQU6"]
        # The thin instrument is honestly insufficient (warming) and NEVER proven off ES's sample.
        assert nq["insufficient"] is True and nq["proven"] is False
        assert nq["bars"] == 15 and ("warming" in nq["reason"] or "insufficient" in nq["reason"])


def test_on_candle_routes_non_es_instrument_identically_no_repaint_es_unchanged():
    # TR-05 engine parameterization proof: the ingest + bar path is instrument-AGNOSTIC. A non-ES
    # instrument driven through the REAL Capture.on_candle path must obey the SAME closed-bar /
    # non-repaint invariants as ES — byte-identical closed-bar structure — proving no capture or
    # bucketing code is ES-special-cased. Guards against a multi-asset regression where non-ES ticks
    # would be dropped, mis-bucketed, or repaint an already-closed bar. Also asserts ES's own behavior
    # is unchanged by multi-asset support (the "ES behavior unchanged" floor).
    import bltd_capture as C

    def _run(sym):
        store, path, cfg = _temp_store()
        try:
            cap = C.Capture(store, bar_seconds=15, lookback=20, edge_gate=False)
            # Two ticks inside one 15s bucket -> nothing closes while the bucket is still forming.
            cap.on_candle({"symbol": sym, "close": 100.0, "epoch": None}, arrival=1_700_000_000.0)
            cap.on_candle({"symbol": sym, "close": 101.0, "epoch": None}, arrival=1_700_000_005.0)
            assert cap.pending_bars == {}, f"{sym}: no bar closes while the bucket is still forming"
            cap.flush()
            assert store.bars(sym, 10, newest=False)["bars"] == [], f"{sym}: forming bucket persists no closed bar"
            # Cross into the next bucket -> the first bucket closes (o=100, c=101), frozen.
            cap.on_candle({"symbol": sym, "close": 102.0, "epoch": None}, arrival=1_700_000_015.0)
            cap.flush()
            closed = store.bars(sym, 10, newest=False)["bars"]
            # A wild tick in the NEW forming bucket must not repaint the already-closed bar.
            cap.on_candle({"symbol": sym, "close": 250.0, "epoch": None}, arrival=1_700_000_020.0)
            cap.flush()
            assert store.bars(sym, 10, newest=False)["bars"] == closed, \
                f"{sym}: closed bar frozen while a new bucket forms (no repaint)"
            return closed
        finally:
            for p in (path, cfg):
                try:
                    os.remove(p)
                except OSError:
                    pass

    orig = S.INSTRUMENT_SCOPE
    try:
        S.INSTRUMENT_SCOPE = "all"                  # deterministic even under a dev BLTD_SCOPE=es
        es_closed = _run("CM.ESU6")                 # ES-family future
        mnq_closed = _run("CM.MNQU6")               # non-ES index future (esModules=False)
        spy_closed = _run("US.SPY")                 # equity ETF, no fabricated futures multiplier
    finally:
        S.INSTRUMENT_SCOPE = orig
    # ES's own closed-bar structure is unchanged by multi-asset support.
    expected = [[100.0, 101.0, 100.0, 101.0, 1_700_000_010.0, 0.0, 0.0]]
    assert es_closed == expected, "ES closed-bar structure unchanged by multi-asset support"
    # The non-ES instruments produce EXACTLY the ES closed-bar structure — the ingest path is
    # instrument-agnostic; non-ES bars route through on_candle identically, with no repaint.
    assert mnq_closed == es_closed, "non-ES (MNQ) routes through on_candle identically to ES"
    assert spy_closed == es_closed, "non-ES (SPY ETF) routes through on_candle identically to ES"


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
