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
import unittest

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
        q = float(self.doc["significance"]["alpha"])
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
        q = float(self.doc["significance"]["alpha"])
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

    def test_zero_trade_cells_are_not_in_the_family(self):
        """Untested cells must not inflate m and weaken the correction for everyone else."""
        cells = self._grid()
        cells.append({"symbol": "WARM", "trades": 0, "pEdge": 1.0, "proven": False})
        self.assertEqual(self.G._apply_grid_fdr(cells, 0.10), 18)

    def test_shipped_significance_string_matches_the_code_that_ran(self):
        """The claim string must describe the correction actually applied, at the real q and m."""
        with open(ARTIFACT) as fh:
            doc = json.load(fh)
        sig = doc["significance"]
        cells = [c for _, c in _cells(doc) if int(c["trades"]) > 0]
        self.assertEqual(int(sig["gridCells"]), len(cells),
                         "significance.gridCells must equal the testable cells in the artifact")
        self.assertRegex(sig["test"], r"(?i)benjamini[- ]hochberg",
                         "significance.test must name the correction the generator runs")
        self.assertIn(f"q={sig['fdrQ']}", sig["test"])
        self.assertIn(f"m={sig['gridCells']}", sig["test"])

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
