#!/usr/bin/env python3
"""REGRESSION LOCK (trading-qa, 2026-07-21) — the shipped reference artifact must actually
apply the BH-FDR correction it advertises.

Bug this locks: backend/gen_reference.py stamps
    significance.test = "one-sided binomial vs R-geometry breakeven, BH-FDR at grid level"
into reference_oos.json but never calls a Benjamini-Hochberg correction. It takes
`proven = prover(...)["ok"]` — a RAW per-test p vs alpha — so context_b @ CM.ESU6 with a raw
pEdge of 0.049508 shipped to buyers as "OOS candidate (cleared significance)" and
candidateCount=1. Over the m=18-cell grid, BH rejects it at every q the codebase uses
(q=0.05 -> rank-1 threshold 0.002778; q=0.10 -> 0.005556), so the honest count is 0.

The live buyer-data path (bltd_analytics.py) DOES apply the correction and demotes with
`fdrRejected`; only the bundled reference artifact skips it, while bltd_analytics.py's own
docstring claims "Same math the reference artifact and the live fleet use".

This test FAILS on the shipped artifact and must stay in the suite after the fix.
Run standalone:  python3 backend/test_reference_fdr.py
"""
import hashlib
import json
import os
import re
import sys
import types
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
ARTIFACT = os.path.join(HERE, "reference_oos.json")
GENERATOR = os.path.join(HERE, "gen_reference.py")

# Every q level the codebase uses for grid-wide FDR control. The artifact must survive the
# one it declares; we also check the analytics default so a q-swap can't quietly re-open this.
Q_LEVELS = (0.05, 0.10)


def _bh_survivors(pvals, q):
    """Indices surviving Benjamini-Hochberg step-up at level q (same rule as
    bltd_analytics._benjamini_hochberg)."""
    m = len(pvals)
    if m == 0:
        return set()
    order = sorted(range(m), key=lambda i: pvals[i])
    cutoff = -1
    for rank, i in enumerate(order, start=1):
        if pvals[i] <= rank / m * q:
            cutoff = rank
    return set(order[:cutoff]) if cutoff > 0 else set()


def _cells(doc):
    return [(e["engine"], c) for e in doc["engines"] for c in e["contracts"]]


class ReferenceArtifactFDR(unittest.TestCase):
    def setUp(self):
        with open(ARTIFACT) as fh:
            self.doc = json.load(fh)

    def test_generator_applies_a_real_bh_correction(self):
        """The generator must CALL a BH correction, not just describe one in a string."""
        with open(GENERATOR) as fh:
            src = fh.read()
        code = "\n".join(
            line for line in src.splitlines()
            if not line.lstrip().startswith("#")
        )
        called = re.search(r"_benjamini_hochberg\s*\(|bh_adjust\s*\(|fdr\w*\s*\(", code, re.I)
        self.assertTrue(
            called,
            "gen_reference.py advertises 'BH-FDR at grid level' in significance.test but never "
            "calls a Benjamini-Hochberg correction; `proven` comes straight from the prover's "
            "raw per-test p vs alpha.",
        )

    def test_every_shipped_candidate_survives_bh_across_the_grid(self):
        cells = _cells(self.doc)
        pvals = [float(c["pEdge"]) for _, c in cells]
        m = len(pvals)
        claimed = [(eng, c["symbol"], float(c["pEdge"]))
                   for eng, c in cells if c.get("proven")]
        for q in Q_LEVELS:
            keep = _bh_survivors(pvals, q)
            spurious = [(eng, c["symbol"], float(c["pEdge"]))
                        for i, (eng, c) in enumerate(cells)
                        if c.get("proven") and i not in keep]
            self.assertEqual(
                spurious, [],
                f"reference_oos.json ships {len(claimed)} 'cleared significance' verdict(s) that "
                f"do NOT survive BH-FDR across the m={m}-cell grid at q={q} "
                f"(rank-1 threshold {1 / m * q:.6f}): {spurious}",
            )

    def test_candidate_count_matches_bh_corrected_truth(self):
        cells = _cells(self.doc)
        pvals = [float(c["pEdge"]) for _, c in cells]
        q = float(self.doc["significance"]["fdrQ"])
        keep = _bh_survivors(pvals, q)
        honest_engines = {eng for i, (eng, _) in enumerate(cells) if i in keep}
        self.assertEqual(
            int(self.doc["candidateCount"]), len(honest_engines),
            f"candidateCount={self.doc['candidateCount']} but only {len(honest_engines)} "
            f"engine(s) survive BH-FDR at q={q} over m={len(pvals)} tests.",
        )

    def test_fdr_rejected_cells_are_labeled(self):
        """A per-test-significant cell demoted by BH must say so, the way the live path does."""
        cells = _cells(self.doc)
        pvals = [float(c["pEdge"]) for _, c in cells]
        q = float(self.doc["significance"]["fdrQ"])
        keep = _bh_survivors(pvals, q)
        alpha = float(self.doc["significance"]["alpha"])
        unlabeled = [
            (eng, c["symbol"], float(c["pEdge"]))
            for i, (eng, c) in enumerate(cells)
            if float(c["pEdge"]) < alpha and i not in keep and not c.get("fdrRejected")
        ]
        self.assertEqual(
            unlabeled, [],
            "cells that are per-test significant but BH-rejected must carry fdrRejected=True "
            f"(and an honest reason string), like bltd_analytics.py does: {unlabeled}",
        )

    def test_retired_aliases_are_explicit_p1_debt_not_cloned_evidence(self):
        retired = {"research", "context_a"}
        by_engine = {row["engine"]: row for row in self.doc["engines"]}
        self.assertTrue(retired.issubset(by_engine))
        debt_cells = []
        for alias in retired:
            engine = by_engine[alias]
            self.assertTrue(engine.get("retired"))
            self.assertEqual(engine["status"], "retired")
            for cell in engine["contracts"]:
                debt_cells.append(cell)
                self.assertTrue(cell.get("retired") and cell.get("fdrDebt"))
                self.assertEqual(float(cell["pEdge"]), 1.0)
                self.assertEqual(int(cell["trades"]), 0)
                self.assertFalse(cell.get("proven"))
                self.assertIn("multiplicity debt", cell["verdict"])
        self.assertEqual(
            int(self.doc["significance"]["retiredDebtCells"]),
            len(debt_cells),
        )


class GeneratorDemotesUnearnedCandidates(unittest.TestCase):
    """BEHAVIORAL lock (trading-engineer, 2026-07-21) on the generator itself.

    The tests above check the shipped ARTIFACT. These check the CODE PATH that writes it, so the
    lock stays red if someone re-introduces a raw `proven = prover(...)["ok"]` verdict even before
    a stale artifact is regenerated. They run without Postgres — synthetic cells only.
    """

    def setUp(self):
        sys.path.insert(0, HERE)
        import gen_reference
        self.G = gen_reference

    def _grid(self, n=18):
        """A realistic family: n-1 hopeless cells plus one caller-controlled cell at index 0."""
        return [{"symbol": f"S{i}", "trades": 100, "pEdge": 0.9, "proven": False}
                for i in range(n)]

    def test_planted_unearned_candidate_is_demoted(self):
        """POSITIVE CONTROL: a per-test-significant cell that BH cannot support MUST be demoted."""
        cells = self._grid()
        cells[0].update(pEdge=0.049508, proven=True)      # the exact cell that shipped green
        m = self.G._apply_grid_fdr(cells, 0.10)
        self.assertEqual(m, 18, "every cell with trades>0 belongs to the BH family")
        self.assertFalse(cells[0]["proven"],
                         "gen_reference set proven=True on a cell BH-FDR rejects (p=0.049508 vs "
                         "rank-1 threshold 0.005556 over m=18) — the shipped-green bug is back")
        self.assertTrue(cells[0].get("fdrRejected"),
                        "a BH-demoted cell must be labeled fdrRejected, like the live path")

    def test_genuinely_earned_candidate_survives(self):
        """NEGATIVE CONTROL: the lock must not pass by demoting everything unconditionally."""
        cells = self._grid()
        cells[0].update(pEdge=0.0001, proven=True)
        self.G._apply_grid_fdr(cells, 0.10)
        self.assertTrue(cells[0]["proven"],
                        "_apply_grid_fdr must only DEMOTE unsupported cells, never blanket-reject "
                        "— a p=0.0001 cell clears BH at q=0.10 over m=18")
        self.assertFalse(cells[0].get("fdrRejected"))

    def test_zero_trade_cells_remain_conservative_members_of_the_predeclared_family(self):
        """Completed zero-trade cells are fixed p=1 nulls; activity cannot shrink historical m."""
        cells = self._grid()
        cells.append({"symbol": "WARM", "trades": 0, "pEdge": 1.0, "proven": False})
        self.assertEqual(self.G._apply_grid_fdr(cells, 0.10), 19)

    def test_retired_aliases_are_p1_debt_and_cannot_rescue_a_canonical_p02(self):
        """Build must never execute or clone retired alias evidence.

        In a nine-engine family, one p=.02 and eight p=1 null/debt slots yields no survivor at
        q=.10. Duplicating .02 into one retired alias would incorrectly rescue both at rank 2.
        """
        patched = {}
        calls = {engine: 0 for engine in self.G.S.ACTIVE_ENGINE_FAMILY}

        def controlled(engine):
            def run(_ohlc, _cfg=None):
                calls[engine] += 1
                p = 0.02 if engine == "breakout" else 1.0
                return {
                    "ok": p < self.G.S.SIG_ALPHA,
                    "trades": 50 if p < 1.0 else 0,
                    "winRate": 0.6 if p < 1.0 else 0.0,
                    "expectancyR": 0.2 if p < 1.0 else 0.0,
                    "netPts": 1.0 if p < 1.0 else 0.0,
                    "maxDrawdownR": 1.0 if p < 1.0 else 0.0,
                    "pEdge": p,
                    "reason": "synthetic controlled verdict",
                }
            return run

        def alias_must_not_run(_ohlc, _cfg=None):
            raise AssertionError("retired alias prover was executed")

        for engine in self.G.S.ACTIVE_ENGINE_FAMILY:
            patched[engine] = controlled(engine)
        for alias in self.G.S.DUPLICATE_ENGINE_ALIASES:
            patched[alias] = alias_must_not_run

        fake_psycopg = types.SimpleNamespace(connect=lambda *_args, **_kwargs: object())
        loaded = (
            [(100.0, 100.0, 100.0, 100.0)] * 80,
            (1_700_000_000.0, 1_700_001_200.0),
            "a" * 64,
        )
        with mock.patch.dict(sys.modules, {"psycopg": fake_psycopg}), \
                mock.patch.object(self.G, "_load", return_value=loaded), \
                mock.patch.object(self.G.S, "PROVERS", patched):
            symbols = ["CM.ESU6", "CM.ESM6"]
            doc = self.G.build("unused", symbols)

        self.assertEqual(
            doc["significance"]["gridCells"],
            len(self.G.S.FDR_ENGINE_FAMILY) * len(symbols),
        )
        self.assertEqual(
            doc["significance"]["retiredDebtCells"],
            len(self.G.S.DUPLICATE_ENGINE_ALIASES) * len(symbols),
        )
        self.assertEqual(doc["candidateCount"], 0)
        self.assertEqual(calls, {
            engine: len(symbols) for engine in self.G.S.ACTIVE_ENGINE_FAMILY
        })

        by_engine = {row["engine"]: row for row in doc["engines"]}
        breakout = by_engine["breakout"]["contracts"][0]
        self.assertEqual(breakout["pEdge"], 0.02)
        self.assertFalse(breakout["proven"])
        self.assertTrue(breakout.get("fdrRejected"))
        for alias in self.G.S.DUPLICATE_ENGINE_ALIASES:
            debt_engine = by_engine[alias]
            self.assertEqual(debt_engine["status"], "retired")
            debt = debt_engine["contracts"][0]
            self.assertTrue(debt["retired"] and debt["fdrDebt"])
            self.assertEqual(debt["pEdge"], 1.0)
            self.assertEqual(debt["trades"], 0)
            self.assertFalse(debt["proven"])

    def test_shipped_significance_string_matches_the_code_that_ran(self):
        """The claim string must describe the correction actually applied, at the real q and m."""
        with open(ARTIFACT) as fh:
            doc = json.load(fh)
        sig = doc["significance"]
        cells = [c for _, c in _cells(doc)]
        self.assertEqual(int(sig["gridCells"]), len(cells),
                         "significance.gridCells must equal the testable cells in the artifact")
        self.assertRegex(sig["test"], r"(?i)benjamini[- ]hochberg",
                         "significance.test must name the correction the generator runs")
        self.assertIn(f"q={sig['fdrQ']}", sig["test"])
        self.assertIn(f"m={sig['gridCells']}", sig["test"])

    def test_reference_pins_exact_inputs_and_drawdown_not_just_dates(self):
        """A mutable DB date range is not reproducible evidence; every source series needs a digest."""
        with open(ARTIFACT) as fh:
            doc = json.load(fh)
        inputs = doc.get("source_inputs")
        self.assertIsInstance(inputs, list)
        self.assertGreaterEqual(len(inputs), 1)
        expected_snapshot = hashlib.sha256(
            json.dumps(inputs, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest()
        self.assertEqual(doc.get("source_snapshot_sha256"), expected_snapshot)
        by_symbol = {row["symbol"]: row for row in inputs}
        for row in inputs:
            self.assertRegex(row.get("input_sha256", ""), r"^[0-9a-f]{64}$")
            self.assertGreater(int(row.get("bars", 0)), 0)
        for _, cell in _cells(doc):
            self.assertIn(cell["symbol"], by_symbol)
            self.assertEqual(cell.get("input_sha256"), by_symbol[cell["symbol"]]["input_sha256"])
            self.assertGreaterEqual(float(cell.get("maxDrawdownR", -1)), 0.0)

    def test_prover_sha_pins_the_module_that_actually_ran(self):
        """GAP 4: a stale artifact must not ride along on a fresh commit sha."""
        with open(ARTIFACT) as fh:
            doc = json.load(fh)
        with open(os.path.join(HERE, doc["prover_file"]), "rb") as fh:
            live = hashlib.sha256(fh.read()).hexdigest()[:16]
        self.assertEqual(doc["prover_sha"], live,
                         f"reference_oos.json was generated by {doc['prover_file']}@"
                         f"{doc['prover_sha']} but that file is now {live} — the artifact is STALE; "
                         f"re-run: ~/.utah/venv/bin/python backend/gen_reference.py")


if __name__ == "__main__":
    # run-tests.sh aggregates a "N passed, M failed" summary line per file; unittest prints only
    # "OK"/"FAILED", so emit the convention explicitly or this file's 9 tests vanish from the
    # backend total (a silently-undercounted suite is how a dead lock hides).
    _r = unittest.main(verbosity=2, exit=False).result
    _bad = len(_r.failures) + len(_r.errors)
    print(f"\n{_r.testsRun - _bad} passed, {_bad} failed")
    raise SystemExit(1 if _bad else 0)
