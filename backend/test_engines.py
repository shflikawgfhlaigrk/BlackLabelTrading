"""Black Label Trading — backend engine test suite (pure stdlib; pytest-optional).

TDD for the ported engine roster (bible/apex/perp/barber/ctx_alpha/ctx_bravo) + the shared
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
# Task 3 — perp engine (clean symmetric momentum consensus)
# ===========================================================================
def test_perp_proves_on_trend():
    r = S.prove_perp(_consensus_uptrend(), S.CONFIG_DEFAULTS)
    assert {"ok", "reason", "trades", "winRate", "netPts", "expectancyR"}.issubset(r)
    assert r["ok"] is True
    assert r["netPts"] > 0


def test_perp_no_edge_on_chop():
    r = S.prove_perp(_chop(), S.CONFIG_DEFAULTS)
    assert r["ok"] is False


def test_perp_empty_is_honest():
    r = S.prove_perp([], S.CONFIG_DEFAULTS)
    assert r["ok"] is False and r["trades"] == 0


def test_perp_signal_long_on_uptrend():
    ohlc = _consensus_uptrend()
    sig = S._perp_signal([b[3] for b in ohlc], ohlc, 20, S.CONFIG_DEFAULTS)
    assert sig is not None and sig["direction"] == "long"


# ===========================================================================
# Task 4 — bible engine (guarded short-biased sniper)
# ===========================================================================
def test_bible_blocks_longs():
    trades = S._bible_trades(_consensus_uptrend(), 20, S.CONFIG_DEFAULTS)
    assert all(t["dir"] == "short" for t in trades)


def test_bible_proves_on_downtrend():
    r = S.prove_bible(_downtrend(), S.CONFIG_DEFAULTS)
    assert r["ok"] is True and r["netPts"] > 0


def test_bible_signal_never_long():
    ohlc = _consensus_uptrend()
    sig = S._bible_signal([b[3] for b in ohlc], ohlc, 20, S.CONFIG_DEFAULTS)
    assert sig is None or sig["direction"] == "short"


def test_bible_empty_is_honest():
    r = S.prove_bible([], S.CONFIG_DEFAULTS)
    assert r["ok"] is False and r["trades"] == 0


# ===========================================================================
# Task 5 — apex engine (regime-router trend-continuation)
# ===========================================================================
def test_apex_regime_trend_vs_range():
    up = _consensus_uptrend()
    ch = _chop()
    assert S._apex_regime([b[3] for b in up], up, 20) == "TREND"
    assert S._apex_regime([b[3] for b in ch], ch, 20) == "RANGE"


def test_apex_flat_in_range():
    ch = _chop()
    sig = S._apex_signal([b[3] for b in ch], ch, 20, S.CONFIG_DEFAULTS)
    assert sig is None


def test_apex_proves_on_trend():
    r = S.prove_apex(_consensus_uptrend(), S.CONFIG_DEFAULTS)
    assert r["ok"] is True and r["netPts"] > 0


def test_apex_empty_is_honest():
    r = S.prove_apex([], S.CONFIG_DEFAULTS)
    assert r["ok"] is False and r["trades"] == 0


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
