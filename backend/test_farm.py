"""TR-19 — own-silicon parameter-sweep backtest FARM tests.

The farm reuses the SHIPPED provers (bltd_store.PROVERS) under a hyperparameter sweep, fanned across
this Mac's cores. These tests hold its three honesty invariants:

  1. OVER-FIT TRANSPARENCY — best-of-N search inflates significance, so every surfaced p is
     Benjamini–Hochberg FDR-corrected across ALL cells tried and a raw best-cell p is NEVER exposed.
     On a driftless random walk the farm must NOT manufacture a screening hit from grid size alone.
  2. INSUFFICIENT-HONEST — a cell / slice with < SIG_MIN_N OOS trades is 'insufficient', never a
     fabricated p; a too-thin store yields an honest empty verdict, not a screening hit.
  3. NO AGGREGATE FIGURE + SERIAL==POOL — the rendered payload carries no aggregate win-rate/$ claim
     shape, and the parallel (process-pool) result is identical to the serial result (determinism).

Runnable via `python3 -m pytest test_farm.py` or plain `python3 test_farm.py`.
"""
import math
import random

import bltd_analytics as A
import bltd_store as S


# ── fixtures: an in-memory store that serves a fixed bar series ──────────────
class _FakeStore:
    def __init__(self, ohlc):
        self._o = ohlc

    def config(self):
        return dict(S.CONFIG_DEFAULTS)

    def ohlc_between(self, symbol, start_ts=None, end_ts=None, limit=20000):
        return self._o


def _random_walk(n, seed=7):
    """A driftless random walk — there is NO real edge here. Any 'proven' cell would be over-fit."""
    rng = random.Random(seed)
    px = 5000.0
    out = []
    for _ in range(n):
        px += rng.gauss(0, 2.0)
        o = px
        c = px + rng.gauss(0, 2.0)
        h = max(o, c) + abs(rng.gauss(0, 1.0))
        l = min(o, c) - abs(rng.gauss(0, 1.0))
        out.append((o, h, l, c))
    return out


# ── 1. OVER-FIT TRANSPARENCY ─────────────────────────────────────────────────
def test_farm_reports_cells_tried_and_never_a_raw_best_cell_p():
    store = _FakeStore(_random_walk(800))
    r = A.backtest_farm(store, "meanrev", "ES", workers=1)
    assert r["available"] is True
    assert r["cellsTried"] == len(r["cells"]) > 1, "the farm must try a multi-cell grid"
    assert r["cellsTried"] == r["gridSize"], "meanrev grid fits under the cap — cellsTried==gridSize"
    # every surfaced p is the BH-corrected one; NO raw per-cell p leaks into the payload
    for c in r["cells"]:
        assert "pEdgeAdj" in c and 0.0 <= c["pEdgeAdj"] <= 1.0
        assert "pEdge" not in c and "_pRaw" not in c, "a raw best-cell p must never be surfaced"
    if r.get("best"):
        assert "pEdgeAdj" in r["best"] and "pEdge" not in r["best"]


def test_farm_does_not_manufacture_an_edge_on_a_random_walk():
    # Sweeping many parameter sets over pure noise WILL produce per-test-significant cells by chance.
    # The BH-FDR correction across the whole grid must strip them: 0 selection hits, honest no_edge.
    store = _FakeStore(_random_walk(900, seed=11))
    r = A.backtest_farm(store, "meanrev", "ES", workers=1)
    assert r["selectionHits"] == 0, "grid size alone must not manufacture a screening hit"
    assert r["status"] in ("no_edge", "insufficient")
    if r["status"] == "no_edge":
        assert "beat the family-wide FDR correction" in r["reason"]


def test_bh_adjusted_pvalues_are_monotone_and_bounded_and_dominate_raw():
    raw = [0.001, 0.2, 0.02, 0.5, 0.04]
    adj = A._bh_adjusted_pvalues(raw)
    assert len(adj) == len(raw)
    assert all(0.0 <= a <= 1.0 for a in adj)
    # adjusted p is never smaller than the raw p (correction only inflates)
    assert all(a >= p - 1e-9 for a, p in zip(adj, raw))
    # monotone in rank order: sorting cells by raw p yields non-decreasing adjusted p
    order = sorted(range(len(raw)), key=lambda i: raw[i])
    ranked = [adj[i] for i in order]
    assert all(ranked[i] <= ranked[i + 1] + 1e-9 for i in range(len(ranked) - 1))


# ── 2. INSUFFICIENT-HONEST ───────────────────────────────────────────────────
def test_farm_thin_store_is_insufficient_never_a_screening_hit():
    store = _FakeStore(_random_walk(15))          # below the prover arming floor (lookback+2)
    r = A.backtest_farm(store, "meanrev", "ES", workers=1)
    assert r["available"] is False
    assert "insufficient bars" in r["reason"]
    assert r.get("best") is None


def test_farm_cells_below_sig_min_n_are_insufficient_not_selected():
    store = _FakeStore(_random_walk(300, seed=3))
    r = A.backtest_farm(store, "meanrev", "ES", workers=1)
    for c in r["cells"]:
        if c["trades"] < S.SIG_MIN_N:
            assert c["insufficient"] is True and c["selectionHit"] is False
            assert "insufficient sample" in c["reason"]


def test_farm_unknown_engine_and_symbol_are_honest():
    store = _FakeStore(_random_walk(400))
    assert "unknown engine" in A.backtest_farm(store, "nope", "ES", workers=1)["reason"]
    assert "not a recognized instrument" in A.backtest_farm(store, "meanrev", "@@@", workers=1)["reason"]


# ── 3. NO AGGREGATE FIGURE + DETERMINISM ─────────────────────────────────────
def test_farm_payload_carries_no_aggregate_claim_shape():
    import claim_linter as L
    store = _FakeStore(_random_walk(800))
    r = A.backtest_farm(store, "meanrev", "ES", workers=1)
    text = A.render_farm_payload(r)
    assert "NOT a promise" in text
    assert L.scan_text(text) == [], f"farm payload tripped the claim linter: {text!r}"
    # and the canned sample payloads (what the linter scans) are clean too
    for p in A.farm_sample_payloads():
        assert L.scan_text(p) == []


def test_farm_pool_matches_serial_exactly():
    store = _FakeStore(_random_walk(800, seed=5))
    serial = A.backtest_farm(store, "meanrev", "ES", workers=1)
    pool = A.backtest_farm(store, "meanrev", "ES", workers=4)
    assert "serial" in serial["compute"]
    # pool path either really parallelized or honestly fell back — never a silent lie
    assert pool["compute"].startswith("process-pool") or pool["compute"].startswith("serial")

    def _index(rep):
        return {tuple(sorted(c["params"].items())): (c["pEdgeAdj"], c["trades"], c["selectionHit"])
                for c in rep["cells"]}
    assert _index(serial) == _index(pool), "parallel farm result must equal the serial result"
    assert serial["selectionHits"] == pool["selectionHits"]
    assert serial["status"] == pool["status"]


def test_farm_grid_is_bounded_by_the_cell_cap():
    # No engine grid may exceed the hard ceiling — a farm run is always bounded.
    for eng in S.PROVERS:
        cells, full = A._farm_grid(eng, dict(S.CONFIG_DEFAULTS))
        assert len(cells) <= A._FARM_MAX_CELLS
        assert full >= len(cells)


def test_farm_grid_has_only_effective_predeclared_cells_and_includes_defaults():
    meanrev, mr_full = A._farm_grid("meanrev", dict(S.CONFIG_DEFAULTS))
    assert mr_full == len(meanrev) == 54
    assert {"lookback": 20, "mrStopMult": 8.0, "mrTgtFrac": 0.6, "mrZ": 2.0} in meanrev
    consensus, con_full = A._farm_grid("regime", dict(S.CONFIG_DEFAULTS))
    assert con_full == len(consensus) == 4
    assert all("oosFrac" not in cell for cell in meanrev + consensus)


def test_farm_retired_duplicate_aliases_fail_closed_to_canonical_engine():
    store = _FakeStore(_random_walk(400))
    for alias, canonical in S.DUPLICATE_ENGINE_ALIASES.items():
        r = A.backtest_farm(store, alias, "ES", workers=1)
        assert r["available"] is False
        assert "retired duplicate" in r["reason"]
        assert canonical in r["reason"]


def test_farm_output_is_selection_only_and_never_claims_adoption():
    store = _FakeStore(_random_walk(800))
    r = A.backtest_farm(store, "meanrev", "ES", workers=1)
    assert "selectionHits" in r and "provenCells" not in r
    assert r.get("status") in ("screening_hit", "no_edge", "insufficient")
    for cell in r["cells"]:
        assert "selectionHit" in cell and "proven" not in cell
    rendered = A.render_farm_payload(r).lower()
    assert "candidate" not in rendered and "proven" not in rendered
    assert "not adopted" in rendered or r["status"] != "screening_hit"


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
