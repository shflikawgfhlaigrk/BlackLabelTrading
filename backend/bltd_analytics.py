"""Black Label Trading — analytics spine (full backtest statistics, screener, studies).

SELF-CONTAINED, pure-stdlib. Builds on bltd_store's engine math (same OOS verdict, same bars in)
but adds the *expensive* analytics a paid terminal needs and the cheap store omitted:

  - full_backtest(): a complete report — every OOS trade, the equity curve (cumulative R and
    cumulative points), and the headline stats (win rate, expectancy, profit factor, max
    drawdown, Sharpe, Sortino, avg win/loss, payoff, longest streaks).
  - screen(): run every enabled engine across a set of symbols and rank by proven OOS edge.
  - studies(): chart studies computed from real bars — EMA, VWAP, RSI, Bollinger bands.

ZERO fabrication: every number traces to real captured bars passed in. Empty/insufficient input
yields an explicit "insufficient" report, never an invented stat. Nothing is hardcoded — callers
pass the buyer's tuned config.
"""
from __future__ import annotations

import math

import bltd_store as S


# ===========================================================================
# full backtest report (trades + equity curve + headline stats)
# ===========================================================================
def _trades_for(engine: str, ohlc, cfg):
    """The OOS trade list for an engine on a bar series, using the buyer's config. Dispatches
    through the single canonical per-engine generator registry (bltd_store.engine_trades) so the
    report, the gate and the screener all walk EXACTLY the same OOS trades — no duplication."""
    oos_frac = cfg.get("oosFrac", S.OOS_FRAC)
    lookback = cfg.get("lookback", S.LOOKBACK)
    split = int(len(ohlc) * (1.0 - oos_frac))
    return S.engine_trades(engine, ohlc[split:], lookback, cfg), split


# Headline ratio stats (win-rate / profit-factor / expectancy / risk ratios / payoff) are only
# meaningful on a real sample. Below this many trades they would over-state from 1-2 lucky trades,
# so we keep the descriptive COUNTS but zero the ratios and flag sufficientSample=False (honest).
MIN_STATS_N = 10


def _stats(trades):
    """Headline stats over a trade list. Pure. Returns explicit zeros (not None) on empty, and
    zeroes the ratio stats (with sufficientSample=False) on a sub-threshold sample so a single
    lucky trade never renders as a 100% win-rate / huge profit-factor headline."""
    n = len(trades)
    if n == 0:
        return {"trades": 0, "wins": 0, "losses": 0, "winRate": 0.0, "expectancyR": 0.0,
                "netPts": 0.0, "totalR": 0.0, "profitFactor": 0.0, "maxDrawdownR": 0.0,
                "sharpe": 0.0, "sortino": 0.0, "avgWinR": 0.0, "avgLossR": 0.0, "payoff": 0.0,
                "longestWin": 0, "longestLoss": 0, "sufficientSample": False}
    rs = [t["r"] for t in trades]
    wins_r = [r for r in rs if r > 0]
    loss_r = [r for r in rs if r < 0]
    wins, losses = len(wins_r), len(loss_r)
    total_r = sum(rs)
    expectancy = total_r / n
    gross_win = sum(wins_r)
    gross_loss = -sum(loss_r)
    # Profit factor is gross_win/gross_loss. With zero losing trades it is mathematically
    # UNDEFINED (not "sum of R") — report None so a client renders "—", never an inflated number.
    pf = (gross_win / gross_loss) if gross_loss > 0 else None
    net_pts = sum((t["exit"] - t["entry"]) if t["dir"] == "long" else (t["entry"] - t["exit"]) for t in trades)
    # equity-curve drawdown in R
    peak = cum = 0.0
    mdd = 0.0
    for r in rs:
        cum += r
        peak = max(peak, cum)
        mdd = min(mdd, cum - peak)
    # Sharpe / Sortino on per-trade R — a plain per-trade mean/sd ratio. NO sqrt(n) factor (that is
    # the System Quality Number, a different statistic; multiplying by sqrt(n) inflated both here).
    mean = expectancy
    var = sum((r - mean) ** 2 for r in rs) / n
    sd = math.sqrt(var) if var > 0 else 0.0
    sharpe = (mean / sd) if sd > 0 else 0.0
    downside = [min(0.0, r - 0.0) for r in rs]
    dvar = sum(d * d for d in downside) / n
    dsd = math.sqrt(dvar) if dvar > 0 else 0.0
    sortino = (mean / dsd) if dsd > 0 else 0.0
    avg_win = (gross_win / wins) if wins else 0.0
    avg_loss = (-gross_loss / losses) if losses else 0.0
    payoff = (avg_win / abs(avg_loss)) if avg_loss != 0 else 0.0
    # streaks
    lw = ll = cw = cl = 0
    for r in rs:
        if r > 0:
            cw += 1
            cl = 0
        elif r < 0:
            cl += 1
            cw = 0
        else:
            cw = cl = 0
        lw = max(lw, cw)
        ll = max(ll, cl)
    enough = n >= MIN_STATS_N
    out = {"trades": n, "wins": wins, "losses": losses, "winRate": round(wins / n, 4),
           "expectancyR": round(expectancy, 4), "netPts": round(net_pts, 4),
           "totalR": round(total_r, 4), "profitFactor": (round(pf, 4) if pf is not None else None),
           "maxDrawdownR": round(mdd, 4), "sharpe": round(sharpe, 4), "sortino": round(sortino, 4),
           "avgWinR": round(avg_win, 4), "avgLossR": round(avg_loss, 4), "payoff": round(payoff, 4),
           "longestWin": lw, "longestLoss": ll, "sufficientSample": enough}
    if not enough:
        # too few trades for honest ratios — keep counts, suppress the headline ratios
        for k in ("winRate", "expectancyR", "profitFactor", "sharpe", "sortino", "payoff"):
            out[k] = 0.0 if k != "profitFactor" else None
    return out


def _equity_curve(trades):
    """Cumulative R and cumulative points after each trade — the equity curve points."""
    curve = []
    cum_r = cum_pts = 0.0
    for idx, t in enumerate(trades):
        cum_r += t["r"]
        pts = (t["exit"] - t["entry"]) if t["dir"] == "long" else (t["entry"] - t["exit"])
        cum_pts += pts
        curve.append({"i": idx, "cumR": round(cum_r, 4), "cumPts": round(cum_pts, 4),
                      "r": round(t["r"], 4), "dir": t["dir"]})
    return curve


def full_backtest(engine: str, ohlc, cfg=None) -> dict:
    """A complete OOS backtest report for one engine on a bar series. Honest 'insufficient'
    on too-few bars — never a fabricated stat."""
    cfg = cfg or S.CONFIG_DEFAULTS
    lookback = cfg.get("lookback", S.LOOKBACK)
    if engine not in S.PROVERS:
        return {"ok": False, "engine": engine, "reason": f"unknown engine '{engine}'",
                "stats": _stats([]), "curve": [], "enoughBars": False}
    if len(ohlc) < lookback + 2:
        return {"ok": False, "engine": engine,
                "reason": f"insufficient bars ({len(ohlc)}) — arms at >= {lookback + 2}",
                "stats": _stats([]), "curve": [], "enoughBars": False}
    trades, split = _trades_for(engine, ohlc, cfg)
    stats = _stats(trades)
    verdict = S.PROVERS[engine](ohlc, cfg)
    return {"ok": bool(verdict.get("ok")), "engine": engine, "reason": verdict.get("reason", ""),
            "stats": stats, "curve": _equity_curve(trades), "enoughBars": True,
            "oosSplit": split, "oosBars": len(ohlc) - split, "totalBars": len(ohlc)}


# ===========================================================================
# screener — run engines across symbols, rank by edge
# ===========================================================================
def _benjamini_hochberg(pvals, q) -> set:
    """Indices (into pvals) that survive a Benjamini–Hochberg FDR correction at level q. Controls the
    EXPECTED false-discovery rate across the whole family of tests, so screening many engine×symbol
    cells doesn't inflate the candidate count by ~alpha×grid-size. Returns the indices of the
    rejected nulls (the genuine candidates)."""
    m = len(pvals)
    if m == 0:
        return set()
    order = sorted(range(m), key=lambda i: pvals[i])      # ascending p
    k_max = -1
    for rank, idx in enumerate(order, start=1):           # rank 1..m
        if pvals[idx] <= (rank / m) * q:
            k_max = rank
    if k_max < 0:
        return set()
    return set(order[:k_max])                             # all cells up to the largest passing rank


def screen(store, symbols, engines, cfg=None) -> list[dict]:
    """For every (engine, symbol), run the gate and return a ranked row list. Proven edges first,
    then by net points. Pure read over the store. Honest: rows with too-few bars are flagged
    'warming' rather than dropped, so the screener never lies by omission.

    A cell is a candidate ONLY if it passes BOTH (a) the per-test significance gate AND (b) a
    grid-wide Benjamini–Hochberg FDR correction across every testable cell — so a 20-instrument ×
    9-engine screen can't surface ~5%×180 spurious 'candidates' just from grid size. A cell that is
    per-test significant but rejected by the family-wide correction is shown honestly as such."""
    cfg = cfg or store.config()
    lookback = cfg.get("lookback", S.LOOKBACK)
    q = cfg.get("fdrQ", 0.10)
    rows = []
    testable = []                                         # (row_index, pEdge) for the BH family
    for sym in S.scoped_symbols(symbols):
        ohlc = store.ohlc(sym)
        bars = len(ohlc)
        for eng in engines:
            if eng not in S.PROVERS:
                continue
            if bars < lookback + 2:
                rows.append({"engine": eng, "symbol": sym, "edge": False, "warming": True,
                             "bars": bars, "winRate": 0.0, "netPts": 0.0, "expectancyR": 0.0,
                             "trades": 0, "pEdge": 1.0, "reason": f"warming ({bars} bars, arms at {lookback + 2})"})
                continue
            v = S.PROVERS[eng](ohlc, cfg)
            row = {"engine": eng, "symbol": sym, "edge": bool(v.get("ok")), "warming": False,
                   "bars": bars, "winRate": v.get("winRate", 0.0), "netPts": v.get("netPts", 0.0),
                   "expectancyR": v.get("expectancyR", 0.0), "trades": v.get("trades", 0),
                   "pEdge": v.get("pEdge", 1.0), "reason": v.get("reason", "")}
            rows.append(row)
            if v.get("trades", 0) > 0:
                testable.append((len(rows) - 1, v.get("pEdge", 1.0)))
    # Grid-wide FDR control: among per-test-significant cells, keep only those that also survive BH.
    survivors = _benjamini_hochberg([p for (_, p) in testable], q)
    kept = {testable[i][0] for i in survivors}
    m = len(testable)
    for ri, row in enumerate(rows):
        if row["edge"] and ri not in kept:               # per-test sig but rejected family-wide
            row["edge"] = False
            row["reason"] = (f"per-test significant (p={row.get('pEdge', 1.0):.3f}) but rejected by "
                             f"grid-wide FDR control across {m} tests (q={q:.2f})")
    rows.sort(key=lambda r: (not r["edge"], r["warming"], -r["netPts"]))
    return rows


# ===========================================================================
# chart studies — EMA / VWAP / RSI / Bollinger from real OHLC bars
# ===========================================================================
def ema(values, span):
    if not values:
        return []
    k = 2.0 / (span + 1.0)
    out = [values[0]]
    for v in values[1:]:
        out.append(out[-1] + k * (v - out[-1]))
    return out


def sma(values, window):
    out = []
    for i in range(len(values)):
        if i + 1 < window:
            out.append(None)
        else:
            out.append(sum(values[i + 1 - window:i + 1]) / window)
    return out


def rsi(closes, period=14):
    """Wilder's RSI. Returns a list aligned to closes (None until warmed)."""
    n = len(closes)
    out = [None] * n
    if n < period + 1:
        return out
    gains = losses = 0.0
    for i in range(1, period + 1):
        ch = closes[i] - closes[i - 1]
        gains += max(ch, 0.0)
        losses += max(-ch, 0.0)
    avg_gain = gains / period
    avg_loss = losses / period
    out[period] = 100.0 if avg_loss == 0 else 100.0 - 100.0 / (1.0 + avg_gain / avg_loss)
    for i in range(period + 1, n):
        ch = closes[i] - closes[i - 1]
        avg_gain = (avg_gain * (period - 1) + max(ch, 0.0)) / period
        avg_loss = (avg_loss * (period - 1) + max(-ch, 0.0)) / period
        out[i] = 100.0 if avg_loss == 0 else 100.0 - 100.0 / (1.0 + avg_gain / avg_loss)
    return out


def bollinger(closes, window=20, mult=2.0):
    """(mid, upper, lower) SMA-based Bollinger bands, aligned to closes (None until warmed)."""
    mid = sma(closes, window)
    upper = [None] * len(closes)
    lower = [None] * len(closes)
    for i in range(len(closes)):
        if i + 1 < window:
            continue
        seg = closes[i + 1 - window:i + 1]
        m = mid[i]
        sd = math.sqrt(sum((x - m) ** 2 for x in seg) / window)
        upper[i] = m + mult * sd
        lower[i] = m - mult * sd
    return mid, upper, lower


def vwap(ohlc):
    """Running VWAP from typical price (h+l+c)/3 with uniform volume (volume not in WC bars).
    With no real volume this is the running average of typical price — labeled as such by the UI."""
    out = []
    cum = 0.0
    for i, (o, h, l, c) in enumerate(ohlc):
        tp = (h + l + c) / 3.0
        cum += tp
        out.append(cum / (i + 1))
    return out


def studies(ohlc, cfg=None) -> dict:
    """All chart studies for a bar series, computed from real bars. Returns aligned arrays; the
    UI overlays whichever the buyer enables. None entries mark not-yet-warmed positions."""
    cfg = cfg or S.CONFIG_DEFAULTS
    closes = [b[3] for b in ohlc]
    if not closes:
        return {"emaFast": [], "emaSlow": [], "typicalAvg": [], "rsi": [],
                "bbMid": [], "bbUpper": [], "bbLower": []}
    mid, upper, lower = bollinger(closes, 20, 2.0)
    return {"emaFast": [round(x, 6) for x in ema(closes, 8)],
            "emaSlow": [round(x, 6) for x in ema(closes, 21)],
            # NOT volume-weighted (WC bars carry no volume) — a running typical-price average. Named
            # honestly so a client never renders it as a real VWAP. Real VWAP awaits captured volume.
            "typicalAvg": [round(x, 6) for x in vwap(ohlc)],
            "rsi": [None if x is None else round(x, 3) for x in rsi(closes, 14)],
            "bbMid": [None if x is None else round(x, 6) for x in mid],
            "bbUpper": [None if x is None else round(x, 6) for x in upper],
            "bbLower": [None if x is None else round(x, 6) for x in lower]}
