"""TR-10 teeth test for the zero-claims linter (claim_linter.py).

Proves the linter actually BITES — the same discipline the Front Desk guardrails test uses: plant a
forbidden claim in a temp tree copy and assert the linter fails it (exit != 0); and assert the
product's own HONEST prose ("no win-rate shown", "never a 100% win-rate") does NOT trip it. A linter
with no teeth is worse than none — it reads as "claims are gated" when they are not.

Runnable via `python3 -m pytest test_claim_linter.py` or plain `python3 test_claim_linter.py`.
"""
import os
import tempfile

import claim_linter as L


def _tree(files: dict) -> str:
    """Materialise a temp repo tree {relpath: content} and return its root."""
    root = tempfile.mkdtemp(prefix="bltd-linter-")
    for rel, content in files.items():
        p = os.path.join(root, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8") as fh:
            fh.write(content)
    return root


# ── TEETH: a planted forbidden claim must FAIL the build (exit != 0) ─────────
def test_planted_exact_figure_trips_the_linter():
    root = _tree({"Sources/Fake.swift": 'let headline = "Cumulative account P&L: $791,123"\n'})
    assert L.main(["--root", root]) == 1, "a planted $791,123 fabrication must fail the linter"


def test_planted_winrate_claim_trips_the_linter():
    root = _tree({"Sources/Fake.swift": 'Text("Our engine wins at an 82.0% win rate")\n'})
    assert L.main(["--root", root]) == 1, "a planted 82.0% win-rate claim must fail the linter"


def test_planted_pnl_and_return_claims_trip_the_linter():
    root = _tree({
        "backend/bltd_fake.py": 'BANNER = "Members earned a profit of $1,434,082 last quarter"\n',
        "Sources/Ret.swift": 'let s = "241% return, every year"\n',
    })
    assert L.main(["--root", root]) == 1, "planted P&L + return claims must fail the linter"


def test_each_exact_figure_is_individually_caught():
    for planted in ("$791,123", "1,434,082", "82.0%", "241% return", "648W", "789,123"):
        hits = L.scan_text(f"marketing copy says {planted} here")
        assert hits, f"exact fabrication {planted!r} must be caught"


# ── PRECISION: honest copy and buyer-own-data identifiers must NOT trip ──────
def test_honest_prose_does_not_trip():
    honest = [
        "no win-rate shown — this is not a track record",
        "a lucky trade never renders as a 100% win-rate / huge profit-factor headline",
        "8 no_edge, 1 unarmed candidate; NO EDGE on your bars today",
        "we show zero aggregate $/win-rate figures",
        "Cancel anytime. Human support at info@blacklabelbots.com.",
        "9 edge-gated signal engines, 13 risk gates, 2-of-8 multi-TF consensus",
        "signals appear only when a proven edge is present",   # honest edge-gate vocabulary
        "chart axis label $30,000 and a $50,000 prop-firm account",
        "let longWinRate = winRate(longs)  // buyer's own journal stat",
    ]
    for s in honest:
        assert not L.scan_text(s), f"honest copy tripped the linter: {s!r}"


def test_clean_tree_passes():
    root = _tree({
        "Sources/Ok.swift": 'Text("No edge today. This is not a track record.")\n',
        "backend/bltd_ok.py": '"""Signals-only; never a win-rate headline."""\n',
    })
    assert L.main(["--root", root]) == 0, "a clean tree must pass the linter"


def test_negation_guard_only_spares_negated_claims():
    # The SAME numeric shape trips when affirmative but is spared when the product negates it.
    assert not L.scan_text("we never show a 90% win rate"), "negated claim is honest — spared"
    assert L.scan_text("we deliver a 90% win rate"), "affirmative claim is caught"


def test_real_shipped_surface_is_clean():
    # The live repo product surface must itself be clean (this is the standing invariant TR-10 holds).
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    assert L.main(["--root", repo]) == 0, "the shipped Trading surface must be claim-clean"


# ── TR-06 PAYLOAD TEETH: a forbidden figure in a RENDERED alert payload must fail ────────────
def test_rendered_alert_payloads_are_clean():
    # The real TR-06 alert payloads (bltd_alerts.linter_sample_payloads) must carry no forbidden
    # aggregate figure — this is the standing invariant the build gate holds.
    assert L.scan_alert_payloads() == [], "the shipped alert payloads must be claim-clean"


def test_planted_winrate_in_a_payload_trips_the_linter():
    # A win-rate injected into the render path (even a computed one) must be caught by scanning the
    # RENDERED payload, not just source. We inject a poisoned render_fn and assert teeth.
    poisoned = lambda: ["Black Label Trading — edge-gate verdict\nOur engine wins at an 82.0% win rate"]
    assert L.scan_alert_payloads(render_fn=poisoned), "a planted payload win-rate must be caught"


def test_planted_pnl_in_a_payload_trips_the_linter():
    poisoned = lambda: ["No edge today.", "Members earned a profit of $1,434,082 this quarter"]
    assert L.scan_alert_payloads(render_fn=poisoned), "a planted payload P&L must be caught"


def test_main_fails_when_payloads_are_poisoned(monkeypatch=None):
    # End-to-end: main() must return exit 1 when the payload render path emits a forbidden figure,
    # even on an otherwise-clean tree. We swap scan_alert_payloads' default source via the module hook.
    import bltd_alerts
    orig = bltd_alerts.linter_sample_payloads
    bltd_alerts.linter_sample_payloads = lambda: ["a win rate of 90%"]
    try:
        root = _tree({"Sources/Ok.swift": 'Text("clean")\n'})
        assert L.main(["--root", root]) == 1, "poisoned payloads must fail the whole linter"
    finally:
        bltd_alerts.linter_sample_payloads = orig


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
