"""Fail-closed, cost-aware nested validation for the shipped Trading engines.

This module does not promote a best-looking backtest cell. It selects parameters only on an
inner validation slice, purges an embargo, evaluates the selection on sequential untouched outer
folds, corrects the complete engine×parameter×contract×cost family, and requires every contract,
cost band, and outer fold to pass. It is intentionally separate from the live gate: an optimizer
report is research evidence until a later release process explicitly adopts a frozen configuration.
"""
from __future__ import annotations

import hashlib
import itertools
import json
import math
import os
import random
from types import MappingProxyType
from typing import Callable

import bltd_store as S

FROZEN_MAX_HOLDING_BARS = 80
FROZEN_RESEARCH_TICK_SIZE = 0.25
MIN_EMBARGO_BARS = FROZEN_MAX_HOLDING_BARS
DEFAULT_COST_BANDS = (0.25, 0.50, 1.00)
REQUIRED_OUTER_FOLDS = 3
REQUIRED_FDR_Q = 0.10
MAX_BARS_PER_CONTRACT = 30_000
MAX_GRID_CELLS = 64
# Already-spent hypothesis budget: 18 default reference cells plus the historical 166-cell farm
# over two contracts (332 cells). Retired aliases remain counted. Every later CLI reservation is
# added to this floor; a new process never gets to reset multiplicity to zero.
DEFAULT_PRIOR_FAMILY_SIZE = 350

# The optimizer never inherits execution geometry from buyer settings. Every config value that can
# reach ENGINE_TRADES but is not supplied by a canonical parameter-grid cell is frozen here.
FROZEN_RESEARCH_CONFIG = MappingProxyType({
    "bkMaxHold": FROZEN_MAX_HOLDING_BARS,
    "researchTickSize": FROZEN_RESEARCH_TICK_SIZE,
    "fdrQ": REQUIRED_FDR_Q,
})


def effective_research_config() -> dict:
    """Return the complete fixed (non-grid) research config for one validation cell."""
    return dict(FROZEN_RESEARCH_CONFIG)


def _grid(values: dict) -> list[dict]:
    keys = sorted(values)
    return [dict(zip(keys, combo)) for combo in itertools.product(*(values[k] for k in keys))]


# Predeclared grids only. `oosFrac` is deliberately absent: engine_trades consumes an already
# isolated slice, so sweeping oosFrac created three duplicate hypotheses with identical trades.
CANONICAL_GRIDS = {
    "meanrev": _grid({
        "lookback": [10, 20],
        "mrStopMult": [6.0, 8.0, 10.0],
        "mrTgtFrac": [0.4, 0.6, 0.8],
        "mrZ": [1.5, 2.0, 2.5],
    }),
    "breakout": _grid({
        "bkTargetR": [1.0, 1.5, 2.0, 2.5, 3.0],
        "lookback": [10, 20, 30, 40],
    }),
    "momentum": _grid({"lookback": [8, 12, 20, 30]}),
    "structure": _grid({"lookback": [8, 12, 20, 30]}),
    "regime": _grid({"lookback": [8, 12, 20, 30]}),
    "channel": _grid({"lookback": [8, 12, 20, 30]}),
    "context_b": _grid({"lookback": [8, 12, 20, 30]}),
}

# Each trade generator must receive every variable input explicitly from either this key-complete
# grid cell or FROZEN_RESEARCH_CONFIG. That prevents an omitted key from falling through to a
# mutable store default.
GRID_BOUND_CONFIG_KEYS = {
    "meanrev": frozenset({"lookback", "mrStopMult", "mrTgtFrac", "mrZ"}),
    "breakout": frozenset({"bkTargetR", "lookback"}),
    "momentum": frozenset({"lookback"}),
    "structure": frozenset({"lookback"}),
    "regime": frozenset({"lookback"}),
    "channel": frozenset({"lookback"}),
    "context_b": frozenset({"lookback"}),
}


def _canonical_hash(value) -> str:
    raw = json.dumps(value, sort_keys=True, separators=(",", ":"), default=str).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()


def _series_hash(ohlc) -> str:
    digest = hashlib.sha256()
    for row in ohlc:
        # Hash the full supplied snapshot row, including its required timestamp. Two series with
        # identical prices at different times are different research inputs and must get new run ids.
        try:
            encoded = "|".join(f"{float(x):.17g}" for x in row).encode("ascii")
        except (TypeError, ValueError, OverflowError):
            # Invalid snapshots are rejected below, but their diagnostic report must still be
            # deterministic rather than crashing while provenance is being constructed.
            encoded = json.dumps(row, sort_keys=True, separators=(",", ":"), default=str).encode("utf-8")
        digest.update(encoded + b"\n")
    return digest.hexdigest()


def optimizer_source_sha() -> str:
    try:
        with open(__file__, "rb") as handle:
            return hashlib.sha256(handle.read()).hexdigest()
    except OSError:
        return "unknown"


def _trade_points(trade: dict) -> float:
    entry = float(trade.get("entry", 0.0))
    exit_price = float(trade.get("exit", entry))
    return exit_price - entry if trade.get("dir") == "long" else entry - exit_price


def adjust_for_costs(trades, round_trip_points: float) -> list[dict]:
    """Return cost-adjusted copies while preserving chronological order and gross provenance."""
    cost = max(0.0, float(round_trip_points))
    out = []
    for trade in trades or []:
        gross_points = _trade_points(trade)
        gross_r = float(trade.get("r", 0.0))
        try:
            stop = float(trade["stop"])
            entry = float(trade["entry"])
            risk_points = abs(entry - stop)
        except (KeyError, TypeError, ValueError, OverflowError):
            risk_points = abs(gross_points / gross_r) if gross_r else 0.0
        net_points = gross_points - cost
        cost_r_available = math.isfinite(risk_points) and risk_points > 0
        # A zero/unknown risk denominator cannot support a cost-adjusted R claim. Mark it invalid;
        # summarize_costed fails the cell rather than silently treating cost as 0R.
        net_r = (net_points / risk_points) if cost_r_available else 0.0
        row = dict(trade)
        row.update({
            "grossPoints": round(gross_points, 8),
            "costPoints": cost,
            "netPoints": round(net_points, 8),
            "grossR": gross_r,
            "r": round(net_r, 8),
            "costRAvailable": cost_r_available,
        })
        out.append(row)
    return out


def _max_drawdown(values) -> float:
    peak = total = drawdown = 0.0
    for value in values:
        total += value
        peak = max(peak, total)
        drawdown = max(drawdown, peak - total)
    return round(drawdown, 6)


def _block_bootstrap_lower(values, *, samples=200, block=5, seed=0) -> float:
    """Deterministic 5th-percentile moving-block bootstrap of mean R."""
    values = [float(v) for v in values]
    if not values:
        return 0.0
    if samples <= 0:
        return min(values)
    n = len(values)
    width = max(1, min(int(block), n))
    starts = list(range(0, n - width + 1))
    rng = random.Random(seed)
    means = []
    for _ in range(int(samples)):
        draw = []
        while len(draw) < n:
            start = rng.choice(starts)
            draw.extend(values[start:start + width])
        means.append(sum(draw[:n]) / n)
    means.sort()
    return round(means[max(0, int(0.05 * len(means)) - 1)], 8)


def summarize_costed(trades, cost_points: float, *, min_trades=S.SIG_MIN_N,
                     bootstrap_samples=200, seed=0) -> dict:
    adjusted = adjust_for_costs(trades, cost_points)
    rs = [float(t["r"]) for t in adjusted]
    points = [float(t["netPoints"]) for t in adjusted]
    n = len(adjusted)
    cost_r_complete = bool(adjusted) and all(t["costRAvailable"] for t in adjusted)
    wins = sum(r > 0 for r in rs)
    expectancy = (sum(rs) / n) if n else 0.0
    net_points = sum(points)
    p_edge = S._edge_pvalue(adjusted, wins, n, expectancy, min_trades, target_r=None)
    lower = _block_bootstrap_lower(
        rs, samples=bootstrap_samples, block=max(2, int(math.sqrt(max(1, n)))),
        seed=seed)
    sufficient = n >= max(int(min_trades), S.SIG_MIN_N)
    statistical_pass = bool(
        sufficient and cost_r_complete and expectancy > 0 and net_points > 0
        and p_edge < S.SIG_ALPHA and lower > 0)
    return {
        "trades": n,
        "wins": wins,
        "losses": n - wins,
        "expectancyR": round(expectancy, 8),
        "netPoints": round(net_points, 8),
        "maxDrawdownR": _max_drawdown(rs),
        "pEdge": round(float(p_edge), 10),
        "bootstrapLowerR": lower,
        "costPoints": round(float(cost_points), 8),
        "costRComplete": cost_r_complete,
        "sufficient": sufficient,
        "statisticalPass": statistical_pass,
    }


def bh_adjusted(pvalues, prior_family_size: int = 0) -> list[float]:
    """BH-adjusted p-values; prior tested hypotheses remain in the family as conservative nulls."""
    current = [max(0.0, min(1.0, float(p))) for p in pvalues]
    all_values = current + [1.0] * max(0, int(prior_family_size))
    m = len(all_values)
    if not current:
        return []
    order = sorted(range(m), key=lambda i: all_values[i])
    adjusted = [1.0] * m
    running = 1.0
    for rank in range(m, 0, -1):
        idx = order[rank - 1]
        running = min(running, min(1.0, all_values[idx] * m / rank))
        adjusted[idx] = running
    return adjusted[:len(current)]


def anchored_slices(length: int, folds: int, embargo: int, min_train: int) -> list[dict]:
    """Growing train windows followed by a purge/embargo and an untouched sequential test."""
    folds = max(1, int(folds))
    embargo = max(MIN_EMBARGO_BARS, int(embargo))
    min_train = max(1, int(min_train))
    available = int(length) - min_train - folds * embargo
    test_size = available // folds if folds else 0
    if test_size < S.SIG_MIN_N:
        return []
    out = []
    for index in range(folds):
        train_end = min_train + index * (embargo + test_size)
        test_start = train_end + embargo
        test_end = int(length) if index == folds - 1 else test_start + test_size
        if test_end <= test_start:
            return []
        out.append({
            "fold": index + 1,
            "train": (0, train_end),
            "embargo": (train_end, test_start),
            "test": (test_start, test_end),
        })
    return out


def _default_grids(engines, base_cfg):
    return {engine: list(CANONICAL_GRIDS.get(engine, [])) for engine in engines}


def _engine_trades(engine, bars, cfg, trade_fn):
    # Optimizer snapshots carry a fifth timestamp column for provenance. Shipped engine walkers
    # deliberately consume only OHLC; passing five columns through breaks tuple-unpacking in the
    # real (non-test) path and made the CLI unusable.
    ohlc = [tuple(row[:4]) for row in bars]
    return trade_fn(engine, ohlc, int(cfg.get("lookback", S.LOOKBACK)), cfg)


def nested_validate(series_by_contract: dict, engines=None, grids=None, base_cfg=None, *,
                    costs=DEFAULT_COST_BANDS, outer_folds=3, embargo=MIN_EMBARGO_BARS,
                    min_train_bars=None, prior_family_size=DEFAULT_PRIOR_FAMILY_SIZE,
                    bootstrap_samples=200,
                    trade_fn: Callable | None = None) -> dict:
    """Run the fixed release research protocol.

    A completed report can identify a cross-contract research confirmation candidate. It never
    changes live configuration and is never, by itself, eligible for live adoption.
    """
    requested_cfg = dict(S.CONFIG_DEFAULTS if base_cfg is None else base_cfg)
    requested_engines = requested_cfg.get("engines", []) if engines is None else engines
    engines = [e for e in requested_engines if e in S.ENGINE_TRADES]
    cfg0 = effective_research_config()
    contracts = sorted(k for k, v in (series_by_contract or {}).items() if v)
    costs = sorted({max(0.0, float(c)) for c in costs})
    trade_fn = trade_fn or S.engine_trades
    grids = grids or _default_grids(engines, cfg0)
    protocol = {
        "engines": engines,
        "contracts": contracts,
        "costBandsPoints": costs,
        "outerFolds": int(outer_folds),
        "embargoBars": max(MIN_EMBARGO_BARS, int(embargo)),
        "maxHoldingBars": FROZEN_MAX_HOLDING_BARS,
        "priorFamilySize": max(0, int(prior_family_size)),
        "fdrQ": REQUIRED_FDR_Q,
        "bootstrapSamples": max(0, int(bootstrap_samples)),
        "minTrainBarsRequested": (None if min_train_bars is None else int(min_train_bars)),
        "researchConfigSource": "frozen_protocol_not_buyer_config",
        "effectiveResearchConfig": dict(cfg0),
        "gridBoundConfigKeys": {
            engine: sorted(GRID_BOUND_CONFIG_KEYS.get(engine, ())) for engine in engines
        },
        "parameterGrid": grids,
        "activeEngineFamily": list(S.ACTIVE_ENGINE_FAMILY),
        "historicalFdrEngineFamily": list(S.FDR_ENGINE_FAMILY),
        "retiredAliases": dict(S.DUPLICATE_ENGINE_ALIASES),
        "optimizerSha256": optimizer_source_sha(),
        "proverSha": S.prover_source_sha(),
        "proverSha256": S.prover_source_sha256(),
        "configSha256": _canonical_hash(cfg0),
        "gridSha256": _canonical_hash(grids),
    }
    provenance = {
        **protocol,
        "inputs": {name: {"bars": len(series_by_contract[name]),
                          "sha256": _series_hash(series_by_contract[name])}
                   for name in contracts},
    }
    provenance["runId"] = _canonical_hash(provenance)
    head = {
        "kind": "nested_strategy_validation",
        "available": False,
        "label": ("Anchored nested walk-forward with purged outer folds, cost bands, global "
                  "BH-FDR, and cross-contract confirmation. Research only."),
        "contracts": contracts,
        "engines": engines,
        "costBandsPoints": costs,
        "outerFolds": int(outer_folds),
        "embargoBars": max(MIN_EMBARGO_BARS, int(embargo)),
        "priorFamilySize": max(0, int(prior_family_size)),
        "provenance": provenance,
        "folds": [],
        "researchCandidates": [],
        "eligibleForLive": False,
        "adopted": False,
        "reason": "",
    }
    if len(contracts) < 2:
        head["reason"] = "release research requires at least two independent contracts"
        return head
    input_digests = [provenance["inputs"][contract]["sha256"] for contract in contracts]
    if len(set(input_digests)) != len(input_digests):
        head["reason"] = (
            "cross-contract confirmation requires distinct timestamped input histories")
        return head
    if len(engines) != 1:
        head["reason"] = "run exactly one canonical engine per reserved hypothesis family"
        return head
    if engines[0] in S.DUPLICATE_ENGINE_ALIASES or engines[0] not in S.ACTIVE_ENGINE_FAMILY:
        canonical = S.DUPLICATE_ENGINE_ALIASES.get(engines[0])
        head["reason"] = (f"'{engines[0]}' is a retired alias; use canonical engine '{canonical}'"
                          if canonical else f"'{engines[0]}' is not an active canonical engine")
        return head
    if int(outer_folds) != REQUIRED_OUTER_FOLDS:
        head["reason"] = f"release research requires exactly {REQUIRED_OUTER_FOLDS} outer folds"
        return head
    if tuple(costs) != tuple(DEFAULT_COST_BANDS):
        head["reason"] = f"release research requires fixed positive cost bands {DEFAULT_COST_BANDS}"
        return head
    if int(getattr(S, "MR_MAX_HOLD", -1)) != FROZEN_MAX_HOLDING_BARS:
        head["reason"] = (
            f"research engine holding horizon must remain frozen at "
            f"{FROZEN_MAX_HOLDING_BARS} bars")
        return head
    if int(embargo) < FROZEN_MAX_HOLDING_BARS:
        head["reason"] = (
            f"embargo must be at least the {FROZEN_MAX_HOLDING_BARS}-bar maximum "
            "holding horizon")
        return head
    if int(prior_family_size) < DEFAULT_PRIOR_FAMILY_SIZE:
        head["reason"] = f"prior family cannot reset below {DEFAULT_PRIOR_FAMILY_SIZE}"
        return head
    try:
        fdr_q = float(requested_cfg.get("fdrQ", REQUIRED_FDR_Q))
    except (TypeError, ValueError, OverflowError):
        fdr_q = float("nan")
    if not math.isfinite(fdr_q) or not math.isclose(fdr_q, REQUIRED_FDR_Q):
        head["reason"] = f"release research requires fixed FDR q={REQUIRED_FDR_Q:.2f}"
        return head
    expected_grid = CANONICAL_GRIDS.get(engines[0], [])
    if grids.get(engines[0]) != expected_grid or set(grids) != {engines[0]}:
        head["reason"] = "only the predeclared canonical parameter grid is accepted"
        return head
    required_grid_keys = GRID_BOUND_CONFIG_KEYS.get(engines[0], frozenset())
    if any(not isinstance(cell, dict) or set(cell) != required_grid_keys
           for cell in expected_grid):
        head["reason"] = (
            "canonical grid must explicitly bind every variable research config value")
        return head
    if not expected_grid or len(expected_grid) > MAX_GRID_CELLS:
        head["reason"] = "canonical grid is empty or exceeds the release cell cap"
        return head
    for contract in contracts:
        rows = series_by_contract[contract]
        if len(rows) > MAX_BARS_PER_CONTRACT:
            head["reason"] = f"{contract} exceeds the {MAX_BARS_PER_CONTRACT}-bar snapshot cap"
            return head
        if any(not isinstance(row, (list, tuple)) or len(row) < 5 for row in rows):
            head["reason"] = f"{contract} is missing timestamped OHLC provenance"
            return head
        prior_ts = None
        for row in rows:
            try:
                values = [float(value) for value in row[:5]]
            except (TypeError, ValueError, OverflowError):
                head["reason"] = f"{contract} contains non-numeric OHLC/timestamp data"
                return head
            if not all(math.isfinite(value) for value in values):
                head["reason"] = f"{contract} contains non-finite OHLC/timestamp data"
                return head
            timestamp = values[4]
            if prior_ts is not None and timestamp <= prior_ts:
                head["reason"] = f"{contract} timestamps must be strictly increasing"
                return head
            prior_ts = timestamp
    if not contracts or not engines or not costs:
        head["reason"] = "contracts, engines, and cost bands are required"
        return head
    shortest = min(len(series_by_contract[c]) for c in contracts)
    min_train = int(min_train_bars or max(240, shortest // 2))
    slices_by_contract = {
        contract: anchored_slices(
            len(series_by_contract[contract]), outer_folds, embargo,
            min(min_train, max(1, len(series_by_contract[contract]) // 2)))
        for contract in contracts
    }
    if any(len(v) != int(outer_folds) for v in slices_by_contract.values()):
        head["reason"] = "insufficient bars for the requested anchored folds and embargo"
        return head

    outer_cells = []
    selected_by_engine = {engine: [] for engine in engines}
    family_tests = max(0, int(prior_family_size))

    for fold_index in range(int(outer_folds)):
        # Inner validation family: every engine×parameter×contract×cost band is counted.
        inner_cells = []
        for engine in engines:
            for param_index, params in enumerate(grids.get(engine, [])):
                cell_cfg = dict(cfg0)
                cell_cfg.update(params)
                for contract in contracts:
                    bars = series_by_contract[contract]
                    train_end = slices_by_contract[contract][fold_index]["train"][1]
                    inner_cut = max(1, int(train_end * 0.70))
                    inner_start = min(train_end, inner_cut + head["embargoBars"])
                    validation = bars[inner_start:train_end]
                    trades = _engine_trades(engine, validation, cell_cfg, trade_fn)
                    for cost in costs:
                        summary = summarize_costed(
                            trades, cost, min_trades=S.SIG_MIN_N,
                            bootstrap_samples=bootstrap_samples,
                            seed=fold_index * 1_000_003 + param_index * 101
                            + contracts.index(contract))
                        inner_cells.append({
                            "engine": engine, "paramIndex": param_index, "params": params,
                            "contract": contract, "costPoints": cost, **summary,
                        })
        adjusted = bh_adjusted(
            [c["pEdge"] for c in inner_cells],
            prior_family_size=family_tests)
        family_tests += len(inner_cells)
        for cell, p_adj in zip(inner_cells, adjusted):
            cell["pEdgeAdj"] = round(p_adj, 10)
            cell["selectionPass"] = bool(
                cell["statisticalPass"] and p_adj <= cfg0.get("fdrQ", 0.10))

        selections = {}
        for engine in engines:
            candidates = []
            for param_index, params in enumerate(grids.get(engine, [])):
                group = [c for c in inner_cells
                         if c["engine"] == engine and c["paramIndex"] == param_index]
                expected = len(contracts) * len(costs)
                if len(group) == expected and all(c["selectionPass"] for c in group):
                    candidates.append((
                        max(c["pEdgeAdj"] for c in group),
                        -min(c["expectancyR"] for c in group),
                        param_index, params,
                    ))
            if candidates:
                candidates.sort(key=lambda row: (row[0], row[1], row[2]))
                selections[engine] = {"paramIndex": candidates[0][2], "params": candidates[0][3]}
                selected_by_engine[engine].append(candidates[0][2])
            else:
                selected_by_engine[engine].append(None)

        fold_report = {
            "fold": fold_index + 1,
            "slices": {c: slices_by_contract[c][fold_index] for c in contracts},
            "innerFamilyTests": len(inner_cells),
            "selected": selections,
            "outer": [],
        }
        for engine, selected in selections.items():
            cell_cfg = dict(cfg0)
            cell_cfg.update(selected["params"])
            for contract in contracts:
                lo, hi = slices_by_contract[contract][fold_index]["test"]
                untouched = series_by_contract[contract][lo:hi]
                trades = _engine_trades(engine, untouched, cell_cfg, trade_fn)
                for cost in costs:
                    summary = summarize_costed(
                        trades, cost, min_trades=S.SIG_MIN_N,
                        bootstrap_samples=bootstrap_samples,
                        seed=9_000_001 + fold_index * 10_007 + contracts.index(contract))
                    row = {
                        "fold": fold_index + 1, "engine": engine,
                        "paramIndex": selected["paramIndex"], "params": selected["params"],
                        "contract": contract, "costPoints": cost, **summary,
                    }
                    outer_cells.append(row)
                    fold_report["outer"].append(row)
        head["folds"].append(fold_report)

    outer_adjusted = bh_adjusted(
        [c["pEdge"] for c in outer_cells],
        prior_family_size=family_tests)
    family_tests += len(outer_cells)
    for cell, p_adj in zip(outer_cells, outer_adjusted):
        cell["pEdgeAdj"] = round(p_adj, 10)
        cell["confirmationPass"] = bool(
            cell["statisticalPass"] and p_adj <= cfg0.get("fdrQ", 0.10))

    confirmed = []
    for engine in engines:
        choices = selected_by_engine[engine]
        stable_choice = choices[0] if choices and all(c == choices[0] for c in choices) else None
        expected = int(outer_folds) * len(contracts) * len(costs)
        confirmations = [c for c in outer_cells if c["engine"] == engine]
        if stable_choice is not None and len(confirmations) == expected \
                and all(c["confirmationPass"] for c in confirmations):
            confirmed.append({
                "engine": engine,
                "paramIndex": stable_choice,
                "params": grids[engine][stable_choice],
                "worstCostPoints": max(costs),
                "worstExpectancyR": min(c["expectancyR"] for c in confirmations),
                "worstAdjustedP": max(c["pEdgeAdj"] for c in confirmations),
            })
    head["available"] = True
    head["familyTestsThisRun"] = family_tests - max(0, int(prior_family_size))
    head["familyTestsCumulative"] = family_tests
    head["researchCandidates"] = confirmed
    head["reason"] = (
        "RESEARCH CONFIRMATION CANDIDATE — NOT ADOPTED; separate forward evidence is required"
        if confirmed else
        "NO CONFIRMED RESEARCH CANDIDATE — no engine passed every untouched fold, contract, "
        "cost band, bootstrap floor, and global correction")
    return head
