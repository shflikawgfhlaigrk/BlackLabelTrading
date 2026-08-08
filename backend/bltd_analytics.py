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

import concurrent.futures
import math
import multiprocessing
import os

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
    if engine in S.DUPLICATE_ENGINE_ALIASES:
        return {
            "ok": False, "engine": engine,
            "reason": (f"retired duplicate hypothesis; use canonical engine "
                       f"'{S.DUPLICATE_ENGINE_ALIASES[engine]}'"),
            "stats": _stats([]), "curve": [], "enoughBars": False,
        }
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
    requested_symbols = S.scoped_symbols(symbols)
    requested_engines = [
        e for e in engines
        if e in S.PROVERS and e not in S.DUPLICATE_ENGINE_ALIASES
    ]
    try:
        discovered_symbols = S.scoped_symbols(store.symbols().get("backtestable", []))
    except Exception:  # noqa: BLE001 — small test/fallback stores may expose only ohlc()
        discovered_symbols = []
    family_symbols = S.scoped_symbols([*discovered_symbols, *requested_symbols])
    family_engines = [e for e in S.FDR_ENGINE_FAMILY if e in S.PROVERS]
    series = {sym: store.ohlc(sym) for sym in family_symbols}
    canonical_engines = []
    for engine in family_engines:
        canonical = S.DUPLICATE_ENGINE_ALIASES.get(engine, engine)
        if canonical not in canonical_engines:
            canonical_engines.append(canonical)
    cells_to_run = [
        (engine, symbol)
        for symbol in family_symbols
        for engine in canonical_engines
        if len(series.get(symbol, [])) >= lookback + 2
    ]
    verdict_cache = {}
    if len(cells_to_run) > 1 and sum(len(series[symbol]) for _, symbol in cells_to_run) >= 10_000:
        try:
            workers = min(len(cells_to_run), os.cpu_count() or 1)
            with concurrent.futures.ProcessPoolExecutor(
                    max_workers=workers,
                    mp_context=multiprocessing.get_context("spawn"),
                    initializer=_gate_pool_init,
                    initargs=(series, cfg)) as pool:
                for engine, symbol, verdict in pool.map(_gate_pool_worker, cells_to_run):
                    verdict_cache[(engine, symbol)] = verdict
        except Exception:  # noqa: BLE001 — process spawning is an optimization; truth falls back serially
            verdict_cache = {}
    for engine, symbol in cells_to_run:
        if (engine, symbol) not in verdict_cache:
            verdict_cache[(engine, symbol)] = S.PROVERS[engine](series[symbol], cfg)

    rows = []
    testable = []                                         # (row_index, pEdge) for the BH family
    for sym in family_symbols:
        ohlc = series[sym]
        bars = len(ohlc)
        for eng in family_engines:
            if bars < lookback + 2:
                if eng in S.DUPLICATE_ENGINE_ALIASES:
                    continue
                rows.append({"engine": eng, "symbol": sym, "edge": False, "warming": True,
                             "bars": bars, "winRate": 0.0, "netPts": 0.0, "expectancyR": 0.0,
                             "trades": 0, "pEdge": 1.0, "reason": f"warming ({bars} bars, arms at {lookback + 2})"})
                continue
            # A retired alias is historical multiplicity debt, not current evidence. Cloning the
            # canonical p-value here is anti-conservative: two copies of p=.02 advance to BH rank 2
            # and can pass a nine-test q=.10 family even though the lone canonical p=.02 fails at
            # rank 1. Charge the alias as a fixed null p=1.0 instead, with no live/output row.
            if eng in S.DUPLICATE_ENGINE_ALIASES:
                testable.append((None, 1.0))
                continue
            canonical = S.DUPLICATE_ENGINE_ALIASES.get(eng, eng)
            cache_key = (canonical, sym)
            v = verdict_cache[cache_key]
            row = {"engine": eng, "symbol": sym, "edge": bool(v.get("ok")), "warming": False,
                   "bars": bars, "winRate": v.get("winRate", 0.0), "netPts": v.get("netPts", 0.0),
                   "expectancyR": v.get("expectancyR", 0.0), "trades": v.get("trades", 0),
                   "pEdge": v.get("pEdge", 1.0), "reason": v.get("reason", "")}
            rows.append(row)
            # A completed zero-trade cell is still a tested hypothesis. Count its p=1 placeholder so
            # changing engine activity or a parameter cannot shrink the historical family.
            testable.append((len(rows) - 1, v.get("pEdge", 1.0)))
    # Grid-wide FDR control: among per-test-significant cells, keep only those that also survive BH.
    survivors = _benjamini_hochberg([p for (_, p) in testable], q)
    kept = {testable[i][0] for i in survivors if testable[i][0] is not None}
    m = len(testable)
    for ri, row in enumerate(rows):
        if row["edge"] and ri not in kept:               # per-test sig but rejected family-wide
            row["edge"] = False
            row["reason"] = (f"per-test significant (p={row.get('pEdge', 1.0):.3f}) but rejected by "
                             f"grid-wide FDR control across {m} tests (q={q:.2f})")
    rows.sort(key=lambda r: (not r["edge"], r["warming"], -r["netPts"]))
    requested_symbol_set = set(requested_symbols or family_symbols)
    requested_engine_set = (
        set(requested_engines)
        if engines else
        {e for e in family_engines if e not in S.DUPLICATE_ENGINE_ALIASES}
    )
    return [r for r in rows
            if r["symbol"] in requested_symbol_set and r["engine"] in requested_engine_set]


def instruments(store, cfg=None) -> dict:
    """First-class multi-asset catalog (TR-05): enumerate the instruments actually present in the
    buyer's OWN captured bars, classify each honestly, and state which ES-tuned modules apply. This
    reads the real store — it NEVER surfaces an instrument the buyer doesn't have. When the buyer has
    only ES captured, the catalog says so honestly (onlyES=True) rather than pretending to cover more.

    Every instrument is judged on ITS OWN bars — the fleet edge-gate (gate_rerun) and every factor run
    per-instrument, never pooled across instruments (pooling ES+NQ+SPY into one verdict would be a lie).
    """
    cfg = cfg or store.config()
    cat = store.symbols()  # {backtestable, live, liveTicks, busiest} — all derived from the bars table
    live_set = set(cat.get("live", []) or []) | set(cat.get("liveTicks", []) or [])
    bt_set = set(cat.get("backtestable", []) or [])

    universe, seen = [], set()
    for key in ("liveTicks", "live", "backtestable"):
        for s in (cat.get(key, []) or []):
            if s and s not in seen:
                seen.add(s); universe.append(s)
    busiest = cat.get("busiest")
    if busiest and busiest not in seen:
        seen.add(busiest); universe.append(busiest)

    items, es_family_n, non_es_n = [], 0, 0
    for s in universe:
        info = S.classify_instrument(s)
        try:
            n = len(store.ohlc(s))
        except Exception:
            n = 0
        info["bars"] = n
        info["live"] = s in live_set
        info["backtestable"] = s in bt_set
        items.append(info)
        if info["esFamily"]:
            es_family_n += 1
        else:
            non_es_n += 1
    # Order by depth so the most-analyzable instrument leads the picker.
    items.sort(key=lambda x: (-x["bars"], x["display"]))

    return {
        "kind": "instruments",
        "available": bool(items),
        "count": len(items),
        "esFamilyCount": es_family_n,
        "nonEsCount": non_es_n,
        # onlyES is an HONEST cold/thin state: the buyer has captured ES-family instruments and nothing
        # else. The picker shows a "connect your feed and capture NQ/YM/CL/… to analyze them here" note.
        "onlyES": bool(items) and non_es_n == 0 and es_family_n > 0,
        "label": ("Instruments captured from YOUR own feed — the full engine fleet and the edge-gate "
                  "run per-instrument, never pooled. Points shown; dollars only where the contract spec "
                  "is known."),
        "esModulesNote": ("Session and SMT are ES-tuned modules. On non-ES instruments they are labeled "
                          "ES-only and never run with wrong math — every other module is instrument-agnostic."),
        "instruments": items,
        "reason": (None if items else
                   "no instruments captured yet — connect your feed and let bars accumulate"),
    }


_GATE_SERIES = None
_GATE_CFG = None


def _gate_pool_init(series, cfg):
    global _GATE_SERIES, _GATE_CFG
    _GATE_SERIES, _GATE_CFG = series, cfg


def _gate_pool_worker(cell):
    engine, symbol = cell
    return engine, symbol, S.PROVERS[engine](_GATE_SERIES[symbol], _GATE_CFG)


def gate_rerun(store, symbols, engines, cfg=None) -> dict:
    """Re-run the SHIPPED edge-gate provers (bltd_store.PROVERS, SIG_MIN_N=30, one-sided
    realized-mean-R p<0.05) over the buyer's OWN captured bars, on demand, and return a fully
    reproducible verdict:
    per (engine, contract) the OOS trade count n, wins/losses, net points, max-drawdown-R, and the
    return-based p-value, stamped with the prover-source sha256 so the buyer can reproduce it with
    `shasum -a 256 bltd_store.py`. NO cherry-picking (every scoped symbol × every engine is run and
    reported), NO aggregate win-rate / equity / $ claim, NO performance promise. When a series has
    < SIG_MIN_N OOS trades it is reported honestly as 'insufficient' — significance is NOT assessed
    and the engine is never 'proven'. Same math the reference artifact and the live fleet use; this
    just runs it live on the buyer's data and surfaces the underlying statistics.

    An engine's status is honest: 'candidate' only if it clears the prover floor, per-test return
    significance AND a grid-wide Benjamini–Hochberg FDR correction across every (engine,contract)
    cell (the SAME family-wide guard the live fleet applies, so a re-run can never surface more
    spurious 'candidates' than the fleet does); else 'no_edge' if any contract had a sufficient
    sample; else 'insufficient' (not enough bars/trades to judge)."""
    cfg = cfg or store.config()
    lookback = cfg.get("lookback", S.LOOKBACK)
    q = cfg.get("fdrQ", 0.10)
    requested_syms = S.scoped_symbols(symbols)
    try:
        discovered_syms = S.scoped_symbols(store.symbols().get("backtestable", []))
    except Exception:  # noqa: BLE001 — test stores may expose only an analysis reader
        discovered_syms = []
    syms = S.scoped_symbols([*discovered_syms, *requested_syms])
    # This endpoint advertises a no-cherry-picking rerun. Ignore a narrowed engine request and run
    # the immutable historical family; requested subsets are a display concern, not a correction.
    engines = [e for e in S.FDR_ENGINE_FAMILY if e in S.PROVERS]
    # Load each immutable analysis snapshot once. Evaluating nine pure-Python walkers serially over
    # ~30k bars made the button block for ~90 seconds; large runs fan the independent cells across a
    # spawn-safe process pool and fall back explicitly to serial if the host cannot spawn.
    analysis_reader = getattr(store, "ohlc_between", store.ohlc)
    series = {sym: analysis_reader(sym) for sym in syms}
    compute_engines = [
        eng for eng in engines
        if eng in S.PROVERS and eng not in S.DUPLICATE_ENGINE_ALIASES
    ]
    cells_to_run = [(eng, sym) for eng in compute_engines for sym in syms
                    if len(series.get(sym, [])) >= lookback + 2]
    verdicts = {}
    compute = "serial"
    if len(cells_to_run) > 1 and sum(len(series[s]) for _, s in cells_to_run) >= 10_000:
        try:
            workers = min(len(cells_to_run), os.cpu_count() or 1)
            with concurrent.futures.ProcessPoolExecutor(
                    max_workers=workers,
                    mp_context=multiprocessing.get_context("spawn"),
                    initializer=_gate_pool_init,
                    initargs=(series, cfg)) as pool:
                for eng, sym, verdict in pool.map(_gate_pool_worker, cells_to_run):
                    verdicts[(eng, sym)] = verdict
            compute = f"process-pool ({workers} workers)"
        except Exception as exc:  # noqa: BLE001 — honest, deterministic serial fallback
            verdicts = {}
            compute = f"serial (pool unavailable: {type(exc).__name__})"
    if not verdicts:
        for eng, sym in cells_to_run:
            verdicts[(eng, sym)] = S.PROVERS[eng](series[sym], cfg)
    engine_reports = []
    # (contract_dict-or-None, pEdge) across the whole grid, for BH-FDR. None entries are retired
    # historical hypotheses: they consume multiplicity at conservative p=1.0 but can never appear
    # as a current contract, candidate, or live engine row.
    testable = []
    for eng in engines:
        if eng not in S.PROVERS or eng in S.DUPLICATE_ENGINE_ALIASES:
            continue
        contracts = []
        for sym in syms:
            # On-demand research reruns use the complete bounded analysis history. The continuously
            # running live screen intentionally uses Store.ohlc()'s newest 5k window.
            ohlc = series.get(sym, [])
            bars = len(ohlc)
            if bars < lookback + 2:
                contracts.append({
                    "symbol": sym, "bars": bars, "trades": 0, "wins": 0, "losses": 0,
                    "winRate": 0.0, "netPts": 0.0, "expectancyR": 0.0, "maxDrawdownR": 0.0,
                    "pEdge": 1.0, "proven": False, "insufficient": True,
                    "reason": f"warming — only {bars} bars captured (arms at {lookback + 2})"})
                continue
            v = verdicts[(eng, sym)]
            trades = int(v.get("trades", 0))
            insufficient = trades < S.SIG_MIN_N
            # Per-test candidacy: clears the return significance gate (p<alpha, n>=SIG_MIN_N) AND
            # the prover's own edge floor. Family-wide FDR (below) can only DEMOTE this, never add.
            per_test = bool(v.get("edgeProven")) and bool(v.get("ok"))
            c = {
                "symbol": sym, "bars": bars, "trades": trades,
                "wins": int(v.get("wins", 0)), "losses": int(v.get("losses", 0)),
                "winRate": round(float(v.get("winRate", 0.0)), 4),
                "netPts": round(float(v.get("netPts", 0.0)), 4),
                "expectancyR": round(float(v.get("expectancyR", 0.0)), 4),
                "maxDrawdownR": round(float(v.get("maxDrawdownR", 0.0)), 4),
                "pEdge": v.get("pEdge", 1.0), "proven": per_test, "insufficient": insufficient,
                "reason": ""}
            contracts.append(c)
            testable.append((c, v.get("pEdge", 1.0)))
        if contracts:
            engine_reports.append({"engine": eng, "status": None, "contracts": contracts})

    retired_debt_n = 0
    for alias in S.DUPLICATE_ENGINE_ALIASES:
        if alias not in engines:
            continue
        for sym in syms:
            if len(series.get(sym, [])) >= lookback + 2:
                testable.append((None, 1.0))
                retired_debt_n += 1

    # Grid-wide FDR control across every testable cell — a per-test candidate that does not survive
    # the family-wide correction is demoted to no-edge, honestly labeled.
    survivors = _benjamini_hochberg([p for (_, p) in testable], q)
    kept = {id(testable[i][0]) for i in survivors if testable[i][0] is not None}
    m = len(testable)
    for c in (c for (c, _) in testable if c is not None):
        if c["proven"] and id(c) not in kept:
            c["proven"] = False
            c["fdrRejected"] = True

    # Finalize each contract's honest reason string + roll up each engine's status.
    candidate_n = no_edge_n = insufficient_n = 0
    for e in engine_reports:
        for c in e["contracts"]:
            if c["insufficient"]:
                c["reason"] = (f"insufficient sample — {c['trades']} OOS trades, need ≥{S.SIG_MIN_N} "
                               f"before significance can be assessed")
            elif c["proven"]:
                c["reason"] = (f"OOS candidate — win {c['winRate'] * 100:.1f}% / net "
                               f"{c['netPts']:+.2f} pts on {c['trades']} trades (p={c['pEdge']:.3f}); "
                               f"research only, live verification required")
            elif c.get("fdrRejected"):
                c["reason"] = (f"per-test significant (p={c['pEdge']:.3f}) but rejected by grid-wide "
                               f"FDR control across {m} tests (q={q:.2f})")
            else:
                c["reason"] = (f"no edge — win {c['winRate'] * 100:.1f}% / net {c['netPts']:+.2f} pts "
                               f"on {c['trades']} OOS trades (p={c['pEdge']:.3f}, need p<{S.SIG_ALPHA})")
        any_proven = any(c["proven"] for c in e["contracts"])
        any_sufficient = any(not c["insufficient"] for c in e["contracts"])
        e["status"] = "candidate" if any_proven else ("no_edge" if any_sufficient else "insufficient")
        if e["status"] == "candidate":
            candidate_n += 1
        elif e["status"] == "no_edge":
            no_edge_n += 1
        else:
            insufficient_n += 1

    return {
        "kind": "gate_rerun",
        "available": bool(engine_reports),
        "label": ("Re-run of the edge-gate on YOUR captured bars — reproducible, not a promise, no "
                  "performance guaranteed."),
        "source": "your own captured bars (this Mac's store)",
        "compute": compute,
        "prover_sha": S.prover_source_sha(),
        "sigMinN": S.SIG_MIN_N,
        "alpha": S.SIG_ALPHA,
        "test": "one-sided realized-mean-R Student-t with Newey-West serial-dependence variance",
        "symbols": syms,
        "engineCount": len(engine_reports),
        "fdrHypothesisCount": m,
        "fdrRetiredDebtCount": retired_debt_n,
        "candidateCount": candidate_n,
        "noEdgeCount": no_edge_n,
        "insufficientCount": insufficient_n,
        "engines": engine_reports,
        "reason": (None if engine_reports else
                   "no bars captured yet — connect your feed and let bars accumulate, then re-run"),
    }


def _lab_fold(engine, ohlc, cfg, lookback, index, start_ts=None, end_ts=None) -> dict:
    """Run the SHIPPED prover on ONE contiguous fold of bars and surface only honest OOS statistics:
    the trade count n, wins/losses, net points, max-drawdown-R and the one-sided return p-value.
    A fold with < SIG_MIN_N OOS trades is 'insufficient' — significance is NOT assessed and it is
    never 'proven'. NO aggregate win-rate/$ headline is derived here."""
    bars = len(ohlc)
    base = {"fold": index, "bars": bars, "startTs": start_ts, "endTs": end_ts,
            "trades": 0, "wins": 0, "losses": 0, "winRate": 0.0, "netPts": 0.0,
            "expectancyR": 0.0, "maxDrawdownR": 0.0, "pEdge": 1.0,
            "proven": False, "insufficient": True, "reason": ""}
    if bars < lookback + 2:
        base["reason"] = (f"insufficient bars — {bars} in this fold, prover arms at "
                          f"{lookback + 2}")
        return base
    v = S.PROVERS[engine](ohlc, cfg)
    trades = int(v.get("trades", 0))
    insufficient = trades < S.SIG_MIN_N
    proven = (not insufficient) and bool(v.get("edgeProven")) and bool(v.get("ok"))
    win_rate = round(float(v.get("winRate", 0.0)), 4)
    net_pts = round(float(v.get("netPts", 0.0)), 4)
    p_edge = v.get("pEdge", 1.0)
    if insufficient:
        reason = (f"insufficient sample — {trades} OOS trades, need ≥{S.SIG_MIN_N} before "
                  f"significance can be assessed")
    elif proven:
        reason = (f"OOS candidate — win {win_rate * 100:.1f}% / net {net_pts:+.2f} pts on "
                  f"{trades} trades (p={p_edge:.3f}); research only, live verification required")
    else:
        reason = (f"no edge — win {win_rate * 100:.1f}% / net {net_pts:+.2f} pts on {trades} "
                  f"OOS trades (p={p_edge:.3f}, need p<{S.SIG_ALPHA})")
    base.update({"trades": trades, "wins": int(v.get("wins", 0)), "losses": int(v.get("losses", 0)),
                 "winRate": win_rate, "netPts": net_pts,
                 "expectancyR": round(float(v.get("expectancyR", 0.0)), 4),
                 "maxDrawdownR": round(float(v.get("maxDrawdownR", 0.0)), 4), "pEdge": p_edge,
                 "proven": proven, "insufficient": insufficient, "reason": reason})
    return base


def backtest_lab(store, engine: str, symbol: str, start_ts=None, end_ts=None,
                 folds: int = 1, cfg=None) -> dict:
    """No-code backtest lab (item 10): run the SAME SHIPPED prover (bltd_store.PROVERS[engine]) on
    ONE (engine, symbol) over the buyer's OWN captured bars, optionally restricted to the epoch-second
    window [start_ts, end_ts] and split into `folds` contiguous, non-overlapping folds. Returns per
    fold the OOS trade count n / wins / losses / net points / max-drawdown-R / one-sided mean-R
    p-value, plus one whole-range row, stamped with the prover-source sha256 so the buyer can
    reproduce it (`shasum -a 256 bltd_store.py`). A fold with < SIG_MIN_N OOS trades is reported
    honestly as 'insufficient' (significance not assessed, never 'proven'). NO aggregate win-rate /
    equity / $ figure is produced — this is the buyer's own edge math on their own chosen slice.
    Nothing is downloaded or invented; an empty / too-thin store yields an honest empty verdict."""
    cfg = cfg or store.config()
    lookback = cfg.get("lookback", S.LOOKBACK)
    label = "Run of the SHIPPED edge-gate prover on YOUR captured bars only — reproducible, not a promise, no performance guaranteed."
    head = {"kind": "backtest_lab", "available": False, "engine": engine, "symbol": symbol,
            "label": label, "source": "your own captured bars (this Mac's store)",
            "prover_sha": S.prover_source_sha(), "sigMinN": S.SIG_MIN_N, "alpha": S.SIG_ALPHA,
            "test": "one-sided realized-mean-R Student-t with Newey-West serial-dependence variance",
            "startTs": start_ts, "endTs": end_ts, "folds": [], "whole": None, "reason": ""}
    if engine not in S.PROVERS:
        head["reason"] = f"unknown engine '{engine}'"
        return head
    if engine in S.DUPLICATE_ENGINE_ALIASES:
        head["reason"] = (f"'{engine}' is a retired duplicate hypothesis; use canonical engine "
                          f"'{S.DUPLICATE_ENGINE_ALIASES[engine]}'")
        return head
    if not S.in_scope(symbol):
        head["reason"] = f"'{symbol}' is not a recognized instrument"
        return head
    try:
        nfolds = max(1, min(8, int(folds)))
    except (TypeError, ValueError):
        nfolds = 1
    ohlc = store.ohlc_between(symbol, start_ts, end_ts)
    total = len(ohlc)
    head["totalBars"] = total
    head["foldCount"] = nfolds
    if total < lookback + 2:
        head["reason"] = (f"insufficient bars — only {total} captured for {symbol} in this range "
                          f"(prover arms at {lookback + 2}); connect your feed and let bars accumulate")
        return head
    head["available"] = True
    # Whole-range row (one fold spanning everything the buyer selected).
    head["whole"] = _lab_fold(engine, ohlc, cfg, lookback, 0, start_ts, end_ts)
    # Contiguous, non-overlapping folds across the selected range.
    size = total // nfolds
    fold_rows = []
    if nfolds == 1 or size < lookback + 2:
        # Too few bars to split meaningfully — one honest fold rather than a wall of 'insufficient'.
        fold_rows.append(dict(head["whole"], fold=1))
        head["foldCount"] = 1
    else:
        for i in range(nfolds):
            lo = i * size
            hi = total if i == nfolds - 1 else (i + 1) * size
            fold_rows.append(_lab_fold(engine, ohlc[lo:hi], cfg, lookback, i + 1))
    head["folds"] = fold_rows
    provenN = sum(1 for f in fold_rows if f["proven"])
    head["provenFolds"] = provenN
    head["status"] = ("candidate" if head["whole"]["proven"] else
                      ("insufficient" if head["whole"]["insufficient"] else "no_edge"))
    return head


# ===========================================================================
# TR-19 — own-silicon parameter-sweep backtest FARM
# ===========================================================================
# A parallel parameter sweep over the buyer's OWN captured bars, reusing the SHIPPED provers
# (bltd_store.PROVERS) with ZERO new edge math — every cell is just the same gate math run under a
# different hyperparameter set. Runs entirely on this Mac's cores (concurrent.futures); no cloud, no
# CME data fee, no network egress during compute. Its whole reason to exist is HONEST over-fit
# transparency: best-of-N parameter search inflates significance, so every p we surface is
# Benjamini–Hochberg FDR-corrected across ALL N cells tried and we never show a raw best-cell p.
# A cell with < SIG_MIN_N OOS trades is 'insufficient' (never a fabricated p); no aggregate
# win-rate / equity / $ figure is produced anywhere. "On your captured bars only — NOT a promise."

import concurrent.futures as _futures  # noqa: E402
import itertools as _itertools          # noqa: E402
import os as _os                         # noqa: E402

# Per-engine exploratory grids. These are intentionally the same predeclared cells used by the
# bounded nested optimizer. The farm is a SELECTION screen on one captured slice; it is not
# confirmation evidence and cannot adopt or enable a strategy.
_FARM_GRIDS = {
    "meanrev":  {"lookback": [10, 20], "mrZ": [1.5, 2.0, 2.5],
                 "mrTgtFrac": [0.4, 0.6, 0.8], "mrStopMult": [6.0, 8.0, 10.0]},
    "breakout": {"lookback": [10, 20, 30, 40], "bkTargetR": [1.0, 1.5, 2.0, 2.5, 3.0]},
}
# The consensus family shares one effective knob. `oosFrac` is deliberately absent: the farm already
# receives an isolated series, and sweeping it produced duplicate cells with identical trades.
_FARM_GRID_CONSENSUS = {"lookback": [8, 12, 20, 30]}
_FARM_MAX_CELLS = 256  # hard ceiling on grid size so a farm run is always bounded


def _farm_grid(engine: str, base_cfg: dict):
    """The list of cfg-override dicts (the cells) for one engine — the Cartesian product of its sweep
    grid, deterministically ordered, capped at _FARM_MAX_CELLS. Returns (cells, full_grid_size)."""
    grid = _FARM_GRIDS.get(engine, _FARM_GRID_CONSENSUS)
    keys = sorted(grid.keys())
    combos = list(_itertools.product(*(grid[k] for k in keys)))
    full = len(combos)
    cells = [dict(zip(keys, combo)) for combo in combos[:_FARM_MAX_CELLS]]
    return cells, full


def _bh_adjusted_pvalues(pvals):
    """Benjamini–Hochberg step-up ADJUSTED p-values (a.k.a. BH q-values) for a family of raw p's.
    adj[i] = min over ranks k>=rank(i) of (m/k)*p(k), clamped to [0,1] and enforced monotone. A cell
    survives family-wide FDR control at level q iff its adjusted p <= q — the SAME guard the live
    screener/gate_rerun apply, expressed per-cell so the farm can show an honest corrected p for every
    parameter set instead of a snooped best-cell raw p. Returns a list aligned to the input order."""
    m = len(pvals)
    if m == 0:
        return []
    order = sorted(range(m), key=lambda i: pvals[i])   # ascending p
    adj = [1.0] * m
    running = 1.0
    # walk from the largest p down to the smallest, keeping the running minimum of (m/rank)*p
    for rank in range(m, 0, -1):
        idx = order[rank - 1]
        val = min(1.0, (m / rank) * pvals[idx])
        running = min(running, val)
        adj[idx] = running
    return adj


# ── process-pool worker (module-level so it is picklable under spawn) ──────────
_FARM_OHLC = None
_FARM_ENGINE = None
_FARM_BASE_CFG = None


def _farm_eval(prover, ohlc, cfg_override, base_cfg) -> dict:
    """Run ONE cell: the SHIPPED prover under base_cfg + this cell's overrides. Pure — no I/O."""
    cfg = dict(base_cfg)
    cfg.update(cfg_override)
    v = prover(ohlc, cfg)
    trades = int(v.get("trades", 0))
    return {
        "params": cfg_override,
        "trades": trades,
        "wins": int(v.get("wins", 0)),
        "losses": int(v.get("losses", 0)),
        "winRate": round(float(v.get("winRate", 0.0)), 4),
        "netPts": round(float(v.get("netPts", 0.0)), 4),
        "expectancyR": round(float(v.get("expectancyR", 0.0)), 4),
        "maxDrawdownR": round(float(v.get("maxDrawdownR", 0.0)), 4),
        "_pRaw": float(v.get("pEdge", 1.0)),          # internal only — NEVER surfaced as significance
        "_edgeFloor": bool(v.get("edgeProven")) and bool(v.get("ok")),
        "insufficient": trades < S.SIG_MIN_N,
    }


def _farm_pool_init_full(ohlc, engine, base_cfg):
    """Pool initializer: hand each worker the bar series + engine + base cfg ONCE (not per cell)."""
    global _FARM_OHLC, _FARM_ENGINE, _FARM_BASE_CFG
    _FARM_OHLC, _FARM_ENGINE, _FARM_BASE_CFG = ohlc, engine, base_cfg


def _farm_pool_worker(cfg_override):
    """ProcessPoolExecutor task body — evaluates one cell against the initializer-seeded series."""
    from bltd_store import PROVERS  # re-import in the spawned worker
    return _farm_eval(PROVERS[_FARM_ENGINE], _FARM_OHLC, cfg_override, _FARM_BASE_CFG)


def backtest_farm(store, engine: str, symbol: str, start_ts=None, end_ts=None,
                  workers: int | None = None, cfg=None) -> dict:
    """Parallel parameter-sweep FARM for ONE (engine, symbol) over the buyer's OWN captured bars.

    Reuses the SHIPPED prover (bltd_store.PROVERS[engine]) unchanged for every cell — zero new edge
    math — and fans the engine's hyperparameter grid across this Mac's cores. Returns, for every cell
    TRIED, the honest OOS statistics (n / wins / losses / net points / max-drawdown-R) and a
    Benjamini–Hochberg FDR-corrected p (`pEdgeAdj`) computed across the WHOLE grid. It NEVER surfaces
    a raw best-cell p — that would be a multiple-comparisons lie. A cell with < SIG_MIN_N OOS trades
    is 'insufficient' (significance not assessed). A surviving cell is only a screening hit; it must
    pass the separately reserved nested-confirmation protocol before it is even a research candidate.
    NO aggregate win-rate / equity / $
    figure. Stamped with prover_sha so the buyer can reproduce it. Nothing is downloaded or invented;
    an empty / too-thin store yields an honest empty verdict.

    `workers`: None -> use the machine's cores; 1 -> serial (deterministic, no pool). On any pool
    failure the farm falls back to serial and says so in `compute` (never a silent lie)."""
    cfg = cfg or store.config()
    base_cfg = dict(cfg)
    lookback = cfg.get("lookback", S.LOOKBACK)
    q = cfg.get("fdrQ", 0.10)
    label = ("Selection-only parameter sweep of the SHIPPED edge-gate prover on YOUR captured bars — "
             "reproducible, NOT a promise, never live-adopted.")
    overfit_note = ("Best-of-N parameter search inflates significance. Every p below is "
                    "Benjamini–Hochberg FDR-corrected across all cells tried; a raw best-cell "
                    "p is never shown. A screening hit still requires independent nested confirmation.")
    head = {"kind": "backtest_farm", "available": False, "engine": engine, "symbol": symbol,
            "label": label, "overfitNote": overfit_note,
            "source": "your own captured bars (this Mac's store)",
            "prover_sha": S.prover_source_sha(), "sigMinN": S.SIG_MIN_N, "alpha": S.SIG_ALPHA,
            "fdrQ": q,
            "test": ("one-sided realized-mean-R Student-t with Newey-West serial-dependence "
                     "variance, BH-FDR corrected across the grid"),
            "cores": _os.cpu_count() or 1, "startTs": start_ts, "endTs": end_ts,
            "cells": [], "best": None, "cellsTried": 0, "reason": ""}
    if engine not in S.PROVERS:
        head["reason"] = f"unknown engine '{engine}'"
        return head
    if engine in S.DUPLICATE_ENGINE_ALIASES:
        head["reason"] = (f"'{engine}' is a retired duplicate hypothesis; use canonical engine "
                          f"'{S.DUPLICATE_ENGINE_ALIASES[engine]}'")
        return head
    if not S.in_scope(symbol):
        head["reason"] = f"'{symbol}' is not a recognized instrument"
        return head
    ohlc = store.ohlc_between(symbol, start_ts, end_ts)
    total = len(ohlc)
    head["totalBars"] = total
    cells_cfg, full_grid = _farm_grid(engine, base_cfg)
    head["gridSize"] = full_grid
    head["gridTruncated"] = full_grid > len(cells_cfg)
    if total < lookback + 2:
        head["reason"] = (f"insufficient bars — only {total} captured for {symbol} in this range "
                          f"(prover arms at {lookback + 2}); connect your feed and let bars accumulate")
        return head

    # ── run the grid (parallel across cores, serial fallback) ──────────────────
    prover = S.PROVERS[engine]
    n_workers = (_os.cpu_count() or 1) if workers is None else max(1, int(workers))
    n_workers = min(n_workers, len(cells_cfg))
    results = None
    compute = "serial"
    if n_workers > 1:
        try:
            with _futures.ProcessPoolExecutor(
                    max_workers=n_workers, initializer=_farm_pool_init_full,
                    initargs=(ohlc, engine, base_cfg)) as ex:
                results = list(ex.map(_farm_pool_worker, cells_cfg))
            compute = f"process-pool ({n_workers} workers)"
        except Exception as exc:  # noqa: BLE001 — BrokenProcessPool / spawn issues -> honest fallback
            results = None
            compute = f"serial (pool unavailable: {type(exc).__name__})"
    if results is None:
        results = [_farm_eval(prover, ohlc, c, base_cfg) for c in cells_cfg]
    head["compute"] = compute

    # ── family-wide BH-FDR correction across every cell's raw p ────────────────
    adj = _bh_adjusted_pvalues([r["_pRaw"] for r in results])
    cells = []
    selection_n = insuff_n = suff_n = 0
    for r, a in zip(results, adj):
        insufficient = r["insufficient"]
        selection_hit = (not insufficient) and r["_edgeFloor"] and (a <= q)
        if insufficient:
            insuff_n += 1
            reason = (f"insufficient sample — {r['trades']} OOS trades, need ≥{S.SIG_MIN_N} "
                      f"before significance can be assessed")
        else:
            suff_n += 1
            if selection_hit:
                selection_n += 1
                reason = (f"selection-screen hit — {r['trades']} OOS trades "
                          f"(FDR-adj p={a:.3f}); independent nested confirmation required, "
                          "not adopted for live use")
            else:
                reason = (f"no screening hit — {r['trades']} OOS trades "
                          f"(FDR-adj p={a:.3f} > q={q:.2f})")
        cells.append({
            "params": r["params"], "trades": r["trades"], "wins": r["wins"], "losses": r["losses"],
            "winRate": r["winRate"], "netPts": r["netPts"], "expectancyR": r["expectancyR"],
            "maxDrawdownR": r["maxDrawdownR"], "pEdgeAdj": round(a, 6),
            "selectionHit": selection_hit, "insufficient": insufficient, "reason": reason,
        })
    # deterministic order: selection-screen hits first, then sufficient, then adjusted p ascending.
    cells.sort(key=lambda c: (not c["selectionHit"], c["insufficient"], c["pEdgeAdj"]))
    head["cells"] = cells
    head["cellsTried"] = len(cells)
    head["selectionHits"] = selection_n
    head["cellsInsufficient"] = insuff_n
    head["cellsSufficient"] = suff_n
    head["available"] = True

    # ── the best cell: honest either way, always by ADJUSTED p ─────────────────
    sufficient_cells = [c for c in cells if not c["insufficient"]]
    if selection_n > 0:
        head["best"] = cells[0]
        head["status"] = "screening_hit"
        head["reason"] = ("selection screen found one or more cells; independent nested confirmation "
                          "is required and no strategy was adopted")
    elif sufficient_cells:
        best = min(sufficient_cells, key=lambda c: c["pEdgeAdj"])
        head["best"] = best
        head["status"] = "no_edge"
        head["reason"] = (f"no parameter set beat the family-wide FDR correction across "
                          f"{len(cells)} cells tried — best FDR-adj p={best['pEdgeAdj']:.3f} (need ≤{q:.2f})")
    else:
        head["best"] = None
        head["status"] = "insufficient"
        head["reason"] = (f"every one of the {len(cells)} cells had < {S.SIG_MIN_N} OOS trades on this "
                          f"slice — capture more bars before the farm can judge an edge")
    return head


# ── claim-linter hook: render farm payloads so the zero-claims linter has teeth over them ──────────
def render_farm_payload(report: dict) -> str:
    """Render a farm report to the buyer-facing TEXT surface (what a share/alert would emit), honestly
    and with NO aggregate win-rate/$ headline. claim_linter scans this so a forbidden figure that
    reaches the farm's text — even a computed one — fails the build, not just a source literal. Cells
    are described by trade COUNT + FDR-adjusted p + verdict word; percentages/$ are deliberately not
    composed into a claim shape."""
    if not report.get("available"):
        return f"Backtest farm ({report.get('engine')} on {report.get('symbol')}): {report.get('reason', 'no data')}"
    lines = [f"Black Label Trading — parameter-sweep farm ({report['engine']} on {report['symbol']})",
             f"{report['cellsTried']} cells tried on your captured bars only — NOT a promise.",
             report["overfitNote"]]
    best = report.get("best")
    status = report.get("status")
    if status == "screening_hit" and best:
        lines.append(f"Best cell: selection-screen hit on {best['trades']} OOS trades "
                     f"(FDR-adj p={best['pEdgeAdj']:.3f}) — independent nested confirmation "
                     "required; not adopted.")
    elif status == "no_edge" and best:
        lines.append(f"Verdict: NO EDGE — no parameter set beat the correction "
                     f"(best FDR-adj p={best['pEdgeAdj']:.3f} on {best['trades']} trades).")
    else:
        lines.append("Verdict: INSUFFICIENT — not enough OOS trades to judge; capture more bars.")
    return "\n".join(lines)


def farm_sample_payloads() -> list[str]:
    """Representative rendered farm payloads for the claim linter — a screening-hit case, a no-edge case,
    and an insufficient case. Mirrors bltd_alerts.linter_sample_payloads: the linter renders these so
    a fabricated figure reaching the farm's text surface fails the build."""
    screening = {"available": True, "engine": "meanrev", "symbol": "ES", "cellsTried": 54,
                 "overfitNote": ("Best-of-N parameter search inflates significance. Every p is "
                                 "Benjamini–Hochberg FDR-corrected; a raw best-cell p is never shown."),
                 "status": "screening_hit",
                 "best": {"trades": 42, "pEdgeAdj": 0.031}}
    no_edge = {"available": True, "engine": "breakout", "symbol": "NQ", "cellsTried": 20,
               "overfitNote": screening["overfitNote"], "status": "no_edge",
               "best": {"trades": 61, "pEdgeAdj": 0.184}}
    insufficient = {"available": True, "engine": "regime", "symbol": "CL", "cellsTried": 12,
                    "overfitNote": screening["overfitNote"], "status": "insufficient", "best": None}
    return [render_farm_payload(screening), render_farm_payload(no_edge), render_farm_payload(insufficient)]


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
