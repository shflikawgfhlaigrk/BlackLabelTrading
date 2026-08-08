#!/usr/bin/env python3
"""Deterministic regression locks for cost-aware nested strategy validation."""
from __future__ import annotations

import math
import sys

import bltd_optimizer as O


def _trade(direction="long", points=2.0, risk=1.0):
    if direction == "long":
        return {"dir": "long", "entry": 100.0, "exit": 100.0 + points,
                "stop": 100.0 - risk, "r": points / risk}
    return {"dir": "short", "entry": 100.0, "exit": 100.0 - points,
            "stop": 100.0 + risk, "r": points / risk}


def test_anchored_slices_are_sequential_purged_and_never_overlap():
    folds = O.anchored_slices(2_000, folds=3, embargo=80, min_train=800)
    assert len(folds) == 3
    prior_test_end = 0
    for index, fold in enumerate(folds):
        train_lo, train_hi = fold["train"]
        embargo_lo, embargo_hi = fold["embargo"]
        test_lo, test_hi = fold["test"]
        assert train_lo == 0
        assert train_hi == embargo_lo
        assert embargo_hi == test_lo
        assert embargo_hi - embargo_lo >= 80
        assert train_hi < test_lo < test_hi
        if index:
            assert train_hi > folds[index - 1]["train"][1]
            assert test_lo >= prior_test_end
        prior_test_end = test_hi


def test_cost_adjustment_can_flip_a_gross_positive_strategy():
    gross = [_trade(points=0.20) for _ in range(40)]
    no_cost = O.summarize_costed(gross, 0.0, bootstrap_samples=20)
    realistic = O.summarize_costed(gross, 0.25, bootstrap_samples=20)
    assert no_cost["netPoints"] > 0 and no_cost["expectancyR"] > 0
    assert realistic["netPoints"] < 0 and realistic["expectancyR"] < 0
    assert realistic["statisticalPass"] is False


def test_bh_correction_counts_prior_research_instead_of_resetting_history():
    assert math.isclose(O.bh_adjusted([0.01])[0], 0.01)
    assert O.bh_adjusted([0.01], prior_family_size=99)[0] >= 0.99


def _marker_trade_fn(engine, bars, lookback, cfg):
    # Positive-marker slices are a strong, non-degenerate return edge even after the 1-point cost
    # band; negative-marker slices are all losses. Mixed returns keep the return/HAC statistic real.
    positive = bool(bars) and sum(float(row[3]) for row in bars) / len(bars) > 0
    strong_mixed_returns = [4.0, -1.0, 3.0, 4.0, 3.0] * 8
    return ([_trade(points=value) for value in strong_mixed_returns] if positive
            else [_trade(points=-1.0) for _ in range(40)])


def _series(prefix_positive=True, outer_positive=True, n=3_000, timestamp_offset=0):
    rows = []
    for i in range(n):
        marker = 1.0 if (i < 2_480 and prefix_positive) or (i >= 2_480 and outer_positive) else -1.0
        rows.append((marker, marker, marker, marker, timestamp_offset + i))
    return rows


def test_nested_validator_never_confirms_when_one_untouched_contract_fails():
    report = O.nested_validate(
        {"A": _series(True, True), "B": _series(True, False)},
        engines=["meanrev"],
        embargo=80,
        min_train_bars=1_200,
        bootstrap_samples=20,
        trade_fn=_marker_trade_fn,
    )
    assert report["available"] is True
    assert report["folds"][0]["selected"], "inner data should select the planted strong cell"
    assert report["researchCandidates"] == []
    b_outer = [c for f in report["folds"] for c in f["outer"] if c["contract"] == "B"]
    assert b_outer and any(not c["confirmationPass"] for c in b_outer)


def test_nested_validator_confirms_only_unanimous_untouched_research():
    report = O.nested_validate(
        {"A": _series(True, True), "B": _series(True, True, timestamp_offset=10_000)},
        engines=["meanrev"],
        embargo=80,
        min_train_bars=1_200,
        bootstrap_samples=20,
        trade_fn=_marker_trade_fn,
    )
    assert len(report["researchCandidates"]) == 1
    assert report["researchCandidates"][0]["engine"] == "meanrev"
    assert report["eligibleForLive"] is False and report["adopted"] is False
    assert report["provenance"]["runId"]
    assert all(v["sha256"] for v in report["provenance"]["inputs"].values())


def test_cross_contract_confirmation_rejects_byte_identical_histories():
    duplicated = _series(True, True)
    report = O.nested_validate(
        {"A": duplicated, "B": list(duplicated)},
        engines=["meanrev"],
        embargo=80,
        min_train_bars=1_200,
        bootstrap_samples=5,
        trade_fn=_marker_trade_fn,
    )
    assert report["available"] is False
    assert report["researchCandidates"] == []
    assert "distinct timestamped input histories" in report["reason"]
    inputs = report["provenance"]["inputs"]
    assert inputs["A"]["sha256"] == inputs["B"]["sha256"]


def test_release_protocol_rejects_shortcuts_and_retired_aliases():
    two = {"A": _series(), "B": _series(timestamp_offset=10_000)}
    assert "at least two" in O.nested_validate({"A": _series()}, engines=["meanrev"])["reason"]
    assert "exactly 3" in O.nested_validate(two, engines=["meanrev"], outer_folds=1)["reason"]
    assert "fixed positive cost" in O.nested_validate(two, engines=["meanrev"], costs=[0.0])["reason"]
    assert "maximum holding horizon" in O.nested_validate(
        two, engines=["meanrev"], embargo=O.FROZEN_MAX_HOLDING_BARS - 1)["reason"]
    assert "retired alias" in O.nested_validate(two, engines=["research"])["reason"]
    assert "predeclared" in O.nested_validate(
        two, engines=["meanrev"], grids={"meanrev": [{"lookback": 20}]})["reason"]
    assert "cannot reset" in O.nested_validate(
        two, engines=["meanrev"], prior_family_size=0)["reason"]
    loose = dict(O.S.CONFIG_DEFAULTS)
    loose["fdrQ"] = 0.20
    assert "fixed FDR" in O.nested_validate(
        two, engines=["meanrev"], base_cfg=loose)["reason"]


def test_nested_validation_uses_only_serialized_frozen_research_config():
    hostile = dict(O.S.CONFIG_DEFAULTS)
    hostile.update({"bkMaxHold": 10_000, "researchTickSize": 7.0})
    seen = []

    def capture_config(engine, bars, lookback, cfg):
        seen.append(dict(cfg))
        return _marker_trade_fn(engine, bars, lookback, cfg)

    series = {"A": _series(), "B": _series(timestamp_offset=10_000)}
    hostile_report = O.nested_validate(
        series,
        engines=["breakout"],
        base_cfg=hostile,
        min_train_bars=1_200,
        bootstrap_samples=1,
        trade_fn=capture_config,
    )
    baseline_report = O.nested_validate(
        series,
        engines=["breakout"],
        base_cfg=dict(O.S.CONFIG_DEFAULTS),
        min_train_bars=1_200,
        bootstrap_samples=1,
        trade_fn=capture_config,
    )

    effective = O.effective_research_config()
    assert seen
    assert hostile_report["available"] is True and baseline_report["available"] is True
    assert effective == {
        "bkMaxHold": 80,
        "researchTickSize": 0.25,
        "fdrQ": 0.10,
    }
    assert all(item["bkMaxHold"] == 80 for item in seen)
    assert all(item["researchTickSize"] == 0.25 for item in seen)
    assert all(set(item) == set(effective) | {"lookback", "bkTargetR"} for item in seen)
    provenance = hostile_report["provenance"]
    assert provenance["maxHoldingBars"] == 80
    assert provenance["embargoBars"] >= provenance["maxHoldingBars"]
    assert provenance["effectiveResearchConfig"] == effective
    assert provenance["gridBoundConfigKeys"] == {
        "breakout": ["bkTargetR", "lookback"],
    }
    assert provenance["parameterGrid"] == {"breakout": O.CANONICAL_GRIDS["breakout"]}
    assert provenance["configSha256"] == O._canonical_hash(effective)
    assert provenance["runId"] == baseline_report["provenance"]["runId"]


def test_run_id_binds_costs_protocol_source_and_timestamps():
    base = {"A": _series(), "B": _series(timestamp_offset=10_000)}
    first = O.nested_validate(base, engines=["meanrev"], bootstrap_samples=1)
    changed_time = {"A": _series(timestamp_offset=1), "B": _series(timestamp_offset=10_000)}
    second = O.nested_validate(changed_time, engines=["meanrev"], bootstrap_samples=1)
    changed_cost = O.nested_validate(base, engines=["meanrev"], costs=[1.0], bootstrap_samples=1)
    changed_bootstrap = O.nested_validate(base, engines=["meanrev"], bootstrap_samples=2)
    assert first["provenance"]["runId"] != second["provenance"]["runId"]
    assert first["provenance"]["runId"] != changed_cost["provenance"]["runId"]
    assert first["provenance"]["runId"] != changed_bootstrap["provenance"]["runId"]
    assert len(first["provenance"]["optimizerSha256"]) == 64


def test_unknown_risk_cannot_hide_cost_in_r():
    flat = [{"dir": "long", "entry": 100.0, "exit": 100.0, "r": 0.0} for _ in range(40)]
    summary = O.summarize_costed(flat, 0.25, bootstrap_samples=5)
    assert summary["costRComplete"] is False
    assert summary["statisticalPass"] is False
    assert summary["netPoints"] == -10.0


def test_timestamped_snapshot_is_stripped_to_ohlc_for_real_engine_walkers():
    rows = [(100.0 + i, 101.0 + i, 99.0 + i, 100.5 + i, 1_700_000_000 + i)
            for i in range(80)]
    trades = O._engine_trades("meanrev", rows, dict(O.S.CONFIG_DEFAULTS), O.S.engine_trades)
    assert isinstance(trades, list)


def test_invalid_or_non_monotonic_snapshot_fails_closed_without_crashing():
    valid = _series(timestamp_offset=10_000)
    malformed = _series()
    malformed[5] = ("bad", 1.0, 1.0, 1.0, 5)
    report = O.nested_validate({"A": malformed, "B": valid}, engines=["meanrev"])
    assert report["available"] is False and "non-numeric" in report["reason"]

    reversed_time = _series()
    reversed_time[10] = (*reversed_time[10][:4], reversed_time[9][4])
    report = O.nested_validate({"A": reversed_time, "B": valid}, engines=["meanrev"])
    assert report["available"] is False and "strictly increasing" in report["reason"]


def test_report_language_and_fields_never_claim_live_adoption():
    report = O.nested_validate(
        {"A": _series(True, True), "B": _series(True, True)},
        engines=["meanrev"], min_train_bars=1_200, bootstrap_samples=5,
        trade_fn=_marker_trade_fn)
    import json
    text = json.dumps(report, sort_keys=True).lower()
    assert report["eligibleForLive"] is False and report["adopted"] is False
    assert "promoted" not in text and '"candidate":' not in text


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    failed = 0
    for test in tests:
        try:
            test()
            print(f"ok {test.__name__}")
        except Exception as exc:  # noqa: BLE001
            failed += 1
            print(f"FAIL {test.__name__}: {type(exc).__name__}: {exc}")
    print(f"\n{len(tests) - failed} passed, {failed} failed")
    sys.exit(1 if failed else 0)
