"""Edge-gate logic verification (stdlib unittest, no deps).

These tests prove the PRODUCT'S OWN edge gate (bltd_store PROVERS / Store.edge_ok) is HONEST:
it declares edge_proven == True ONLY when a genuinely edge-bearing series clears the OOS split
AND the minimum-sample floor, and refuses (False) on no-edge series, tiny samples, and cold
stores. The synthetic series here are deterministic GATE-LOGIC fixtures — they verify the
machinery, they are NOT a market track record and are never presented as performance.

Run:  python3 backend/test_edge_gate.py
"""
import os
import random
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import bltd_store as bs  # noqa: E402


def ou_series(n, base=100.0, pull=0.5, noise=4.0, seed=7):
    """Ornstein-Uhlenbeck-style mean-reverting series: price is pulled back toward `base`, so
    z-score extremes revert -> a real (constructed) mean-reversion edge exists."""
    random.seed(seed)
    val = base
    out = []
    for _ in range(n):
        val += -pull * (val - base) + random.gauss(0, noise)
        out.append((val, val + 0.2, val - 0.2, val))
    return out


def trend_series(n, base=100.0, drift=0.5, noise=0.4, seed=3):
    """Persistent up-drift -> a real momentum/breakout edge exists."""
    random.seed(seed)
    val = base
    out = []
    for _ in range(n):
        val += drift + random.gauss(0, noise)
        out.append((val, val + 0.1, val - 0.1, val))
    return out


def random_walk(n, base=100.0, noise=1.0, seed=11):
    """Driftless random walk -> NO persistent edge for either engine."""
    random.seed(seed)
    val = base
    out = []
    for _ in range(n):
        val += random.gauss(0, noise)
        out.append((val, val + 0.1, val - 0.1, val))
    return out


class EdgeGateLogic(unittest.TestCase):
    def test_meanrev_proves_on_genuine_meanreverting_series(self):
        v = bs.prove_meanrev(ou_series(2000))
        self.assertTrue(v["ok"], f"gate should prove edge on a mean-reverting OOS tail: {v}")
        self.assertGreaterEqual(v["trades"], bs.MIN_TRADES)
        self.assertGreater(v["netPts"], 0)

    def test_meanrev_refuses_on_random_walk(self):
        v = bs.prove_meanrev(random_walk(2000))
        self.assertFalse(v["ok"], f"gate must NOT prove edge on a driftless random walk: {v}")

    def test_breakout_refuses_on_random_walk(self):
        v = bs.prove_breakout(random_walk(2000))
        self.assertFalse(v["ok"], f"breakout must NOT prove edge on a random walk: {v}")

    def test_min_trades_floor_refuses_tiny_but_winning_sample(self):
        # A short mean-reverting series can show 100% win on a handful of trades — the gate must
        # still REFUSE because the sample is below MIN_TRADES (the core anti-overfit guard).
        v = bs.prove_meanrev(ou_series(300, pull=0.6, noise=3.0))
        self.assertLess(v["trades"], bs.MIN_TRADES)
        self.assertFalse(v["ok"], f"gate must refuse a sub-min_trades sample even if win-rate is high: {v}")

    def test_store_edge_ok_refuses_cold_store(self):
        with tempfile.TemporaryDirectory() as d:
            st = bs.Store(os.path.join(d, "t.sqlite3"), config_path=os.path.join(d, "c.json"))
            v = st.edge_ok("meanrev", "ANY")
            self.assertFalse(v["ok"])
            self.assertIn("insufficient", v["reason"].lower())

    def test_store_edge_ok_refuses_unknown_engine(self):
        with tempfile.TemporaryDirectory() as d:
            st = bs.Store(os.path.join(d, "t.sqlite3"), config_path=os.path.join(d, "c.json"))
            v = st.edge_ok("nope", "ANY")
            self.assertFalse(v["ok"])
            self.assertIn("unknown engine", v["reason"].lower())

    def test_store_edge_ok_fires_on_seeded_meanreverting_bars(self):
        # End-to-end through the Store: persist a genuinely mean-reverting series, then the gate
        # (which runs the OOS split internally) should declare edge_proven == True.
        with tempfile.TemporaryDirectory() as d:
            st = bs.Store(os.path.join(d, "t.sqlite3"), config_path=os.path.join(d, "c.json"))
            ohlc = ou_series(2000)
            rows = [(1_700_000_000 + i * 900, o, h, l, c) for i, (o, h, l, c) in enumerate(ohlc)]
            st.record_bars("TEST.OU", rows)
            v = st.edge_ok("meanrev", "TEST.OU")
            self.assertTrue(v["ok"], f"Store.edge_ok should fire on a seeded mean-reverting symbol: {v}")
            self.assertGreaterEqual(v["trades"], bs.MIN_TRADES)

    def test_no_trades_series_is_honest_empty(self):
        # A perfectly flat series triggers no entries -> honest 0-trade verdict, never a fabricated win.
        flat = [(100.0, 100.0, 100.0, 100.0) for _ in range(500)]
        v = bs.prove_meanrev(flat)
        self.assertFalse(v["ok"])
        self.assertEqual(v["trades"], 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
