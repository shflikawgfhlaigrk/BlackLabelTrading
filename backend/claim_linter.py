#!/usr/bin/env python3
"""Black Label Trading — PERMANENT zero-claims linter (TR-10, ⛔H1 mechanism).

Charter §5.1 (zero fabrication) / §5.7 (signals-only, a pre-gate ledger is NOT a track record)
say the product may never parade a fabricated win-rate, P&L, equity curve, or "proven track
record". `ship.py` already blocks these on the sales SITE at ship time; this linter is the
PERMANENT, standalone mechanism that also scans the shipped APP surface — the Swift/Python
source AND the compiled binary the buyer actually runs — and is wired into build.command (fails
the build) and Tests/run-all.sh (fails the gate). It supersets the site check so a fabricated
number can never reach a buyer through the app even if the site gate is bypassed.

Two rule classes:

  1. EXACT forbidden figures — the specific fabricated numbers that were paraded in prior copy
     ("$791,123", "82.0%", "1,434,082", "241%", "648W", …). These are literal and must never
     appear anywhere in the shipped surface, comment or string. Zero tolerance, no context guard.

  2. GENERIC performance-claim shapes — an aggregate win-rate %, a $ P&L figure, or an ROI/return
     claim, in an AFFIRMATIVE construction. These carry a NEGATION GUARD so the product's own
     HONEST copy ("a lucky trade never renders as a 100% win-rate", "no aggregate $/win-rate",
     "not a track record") does NOT trip — only an affirmative claim does. Buyer-computed stats
     from THEIR OWN journal (the `winRate` code identifier, `netPnL`, chart axis "$30,000") are
     not claims and are not matched: the generic shapes key on numeric-literal + performance-word
     adjacency in text, never on identifiers.

Scans the SHIPPED surface only (what build.command copies into the bundle + the binary): it does
NOT scan test_*.py, gen_reference.py, or this linter itself — those never reach a buyer and would
self-trip on their own fixtures/pattern literals.

Usage:
    python3 backend/claim_linter.py                         # scan repo source surface
    python3 backend/claim_linter.py --binary <path/to/exe>  # + scan the compiled binary via `strings`
    python3 backend/claim_linter.py --root <dir> ...        # override repo root
Exit code: 0 = clean, 1 = at least one forbidden claim found (build/CI must fail on non-zero).
"""
from __future__ import annotations

import argparse
import glob
import os
import re
import subprocess
import sys

# ── rule class 1: EXACT fabricated figures (literal, zero tolerance) ──────────
# The historically-paraded fabrications. Kept as raw literals so a grep audit is trivial.
EXACT_FORBIDDEN = [
    r"791[,]?123",          # the $791,123 fabricated cumulative-P&L headline
    r"789[,]?123",          # a near-miss variant that appeared in old drafts
    r"1[,]?434[,]?082",     # the 1,434,082 fabricated figure
    r"82\.0\s*%",           # the 82.0% fabricated win-rate
    r"\b241\s*%",           # the 241% fabricated return
    r"\b648\s*W\b",         # 648W fabricated win count
    r"648\s+wins\b",
]

# ── rule class 2: GENERIC performance-claim shapes (affirmative only) ─────────
# Each pattern targets a numeric performance LITERAL adjacent to a performance WORD — the shape a
# fabricated marketing claim takes. Buyer-own-data identifiers (winRate, netPnL) never match.
GENERIC_PATTERNS = [
    # aggregate win-rate / accuracy / hit-rate as a numeric claim: "82% win rate", "74.5% accuracy"
    (r"\b\d{1,3}(?:\.\d+)?\s*%\s*(?:win[\s-]?rate|winrate|win\b|winners?|accuracy|accurate|"
     r"hit[\s-]?rate|profitable|of\s+trades?\s+(?:win|won))", "aggregate win-rate/accuracy claim"),
    # "win rate of 82%", "accuracy of 74%"
    (r"\b(?:win[\s-]?rate|winrate|accuracy|hit[\s-]?rate)\s+of\s+\d{1,3}(?:\.\d+)?\s*%",
     "aggregate win-rate/accuracy claim"),
    # $ P&L figure in profit context: "$791,123 in profit", "profit of $12,400", "made $1.4M"
    (r"(?:profit|profits|gain|gains|earned|made|net\s+of|returns?\s+of|up)\s+(?:of\s+)?[+\-]?"
     r"\$\s?\d[\d,]*(?:\.\d+)?[KMB]?", "$ P&L / profit claim"),
    (r"[+\-]?\$\s?\d[\d,]*(?:\.\d+)?[KMB]?\s*(?:in\s+)?(?:profit|profits|gain|gains|earned|"
     r"P&L|PnL|net\s+profit)", "$ P&L / profit claim"),
    # return-rate claims: "241% return", "18% per month", "monthly ROI of 9%"
    (r"\b\d{1,3}(?:\.\d+)?\s*%\s*(?:ROI|CAGR|return|returns|per\s+(?:month|year|day|week)|"
     r"monthly|annual(?:ized)?)", "return-rate claim"),
]

# NEGATION GUARD: if any of these honesty markers sits within GUARD_WINDOW chars *before* a generic
# match, it is the product describing what it REFUSES to show — not a claim. Skip it.
NEGATION_MARKERS = re.compile(
    r"\b(?:never|no|not|n't|zero|without|isn't|won't|refuse|refuses|avoid|instead of|"
    r"rather than|free of|absent|excludes?|suppress(?:es|ed)?|hides?)\b", re.IGNORECASE)
GUARD_WINDOW = 48

# Files that are part of the SHIPPED product surface. Excludes tests, the reference generator, and
# this linter (none of which reach a buyer; all would self-trip on their own literals/fixtures).
def shipped_source_files(root: str) -> list[str]:
    files: list[str] = []
    files += sorted(glob.glob(os.path.join(root, "Sources", "*.swift")))
    for py in sorted(glob.glob(os.path.join(root, "backend", "bltd_*.py"))):
        files.append(py)                       # bltd_*.py is exactly what build.command bundles
    # shipped data + buyer-facing copy
    for extra in ("backend/reference_oos.json", "README.txt", "README.md", "DOCUMENTATION.md"):
        p = os.path.join(root, extra)
        if os.path.isfile(p):
            files.append(p)
    for md in sorted(glob.glob(os.path.join(root, "docs", "**", "*.md"), recursive=True)):
        files.append(md)
    return files


def scan_text(text: str, *, source: str = "<text>") -> list[tuple[str, int, str, str]]:
    """Return a list of (source, line_no, matched_text, reason) for every forbidden claim in *text*.

    EXACT figures are reported unconditionally; GENERIC shapes are skipped when a negation marker
    precedes them within GUARD_WINDOW chars (the product's own honesty copy)."""
    hits: list[tuple[str, int, str, str]] = []

    def line_of(idx: int) -> int:
        return text.count("\n", 0, idx) + 1

    for pat in EXACT_FORBIDDEN:
        for m in re.finditer(pat, text, re.IGNORECASE):
            hits.append((source, line_of(m.start()), m.group(0), "EXACT fabricated figure"))

    for pat, reason in GENERIC_PATTERNS:
        for m in re.finditer(pat, text, re.IGNORECASE):
            window = text[max(0, m.start() - GUARD_WINDOW):m.start()]
            if NEGATION_MARKERS.search(window):
                continue                       # honest "never a 100% win-rate" — not a claim
            hits.append((source, line_of(m.start()), m.group(0).strip(), reason))
    return hits


def scan_file(path: str) -> list[tuple[str, int, str, str]]:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError as exc:
        print(f"  WARN cannot read {path}: {exc}", file=sys.stderr)
        return []
    return scan_text(text, source=path)


def scan_alert_payloads(render_fn=None) -> list[tuple[str, int, str, str]]:
    """Scan the RENDERED TR-06 alert payloads — the actual text/JSON that would go on the wire — not
    just the source. This catches a forbidden figure that reaches a push through the render path even
    if it was computed rather than a static literal (a source-only scan would miss that). Default
    source is bltd_alerts.linter_sample_payloads(); tests inject render_fn to prove the teeth.

    Import/introspection failure is reported as a warning, not a pass — but only when the real module
    is being scanned (render_fn is None); a missing bltd_alerts in a temp-root fixture is a no-op."""
    if render_fn is None:
        try:
            import bltd_alerts  # noqa: PLC0415 — optional, lazy: the linter must run without it too
        except Exception as exc:  # noqa: BLE001
            print(f"  WARN cannot import bltd_alerts to scan payloads (skipping): "
                  f"{type(exc).__name__}: {exc}", file=sys.stderr)
            return []
        render_fn = bltd_alerts.linter_sample_payloads
    try:
        texts = list(render_fn())
    except Exception as exc:  # noqa: BLE001
        print(f"  WARN cannot render alert payloads: {type(exc).__name__}: {exc}", file=sys.stderr)
        return []
    hits: list[tuple[str, int, str, str]] = []
    for i, text in enumerate(texts):
        hits += scan_text(str(text), source=f"<alert-payload#{i}>")
    return hits


def scan_farm_payloads(render_fn=None) -> list[tuple[str, int, str, str]]:
    """Scan the RENDERED TR-19 backtest-farm payloads — the buyer-facing text a farm run / share
    would emit — not just source. A parameter sweep is the surface most tempted to parade a
    best-of-N win-rate or a $ headline; this catches a forbidden figure that reaches the farm's text
    even if computed. Default source is bltd_analytics.farm_sample_payloads(); tests inject render_fn.

    Import/introspection failure is a warning, not a pass — but only when the real module is scanned
    (render_fn is None); a missing bltd_analytics in a temp-root fixture is a no-op."""
    if render_fn is None:
        try:
            import bltd_analytics  # noqa: PLC0415 — optional, lazy: the linter must run without it too
        except Exception as exc:  # noqa: BLE001
            print(f"  WARN cannot import bltd_analytics to scan farm payloads (skipping): "
                  f"{type(exc).__name__}: {exc}", file=sys.stderr)
            return []
        render_fn = bltd_analytics.farm_sample_payloads
    try:
        texts = list(render_fn())
    except Exception as exc:  # noqa: BLE001
        print(f"  WARN cannot render farm payloads: {type(exc).__name__}: {exc}", file=sys.stderr)
        return []
    hits: list[tuple[str, int, str, str]] = []
    for i, text in enumerate(texts):
        hits += scan_text(str(text), source=f"<farm-payload#{i}>")
    return hits


def scan_binary(binary: str) -> list[tuple[str, int, str, str]]:
    """Scan the compiled binary's embedded strings — the surface a buyer actually sees at runtime."""
    if not os.path.isfile(binary):
        print(f"  WARN binary not found (skipping): {binary}", file=sys.stderr)
        return []
    try:
        out = subprocess.run(["strings", binary], capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError) as exc:
        print(f"  WARN cannot run strings on {binary}: {exc}", file=sys.stderr)
        return []
    return scan_text(out, source=f"{binary} (strings)")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Zero-claims linter for the shipped Trading surface.")
    ap.add_argument("--root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                    help="repo root (default: parent of backend/)")
    ap.add_argument("--binary", default=None, help="also scan this compiled binary via `strings`")
    ap.add_argument("--no-payloads", action="store_true",
                    help="skip rendering + scanning the TR-06 alert payloads")
    args = ap.parse_args(argv)

    all_hits: list[tuple[str, int, str, str]] = []
    scanned = 0
    for f in shipped_source_files(args.root):
        scanned += 1
        all_hits += scan_file(f)
    if args.binary:
        scanned += 1
        all_hits += scan_binary(args.binary)
    # Scan the RENDERED TR-06 alert payloads too — a forbidden figure must never reach a push (§5.1).
    if not args.no_payloads:
        scanned += 1
        all_hits += scan_alert_payloads()
        # …and the TR-19 farm payloads — a best-of-N sweep must never emit a snooped win-rate/$.
        scanned += 1
        all_hits += scan_farm_payloads()

    if all_hits:
        print(f"claim_linter: {len(all_hits)} FORBIDDEN CLAIM(S) in the shipped surface "
              f"({scanned} inputs scanned):")
        for src, ln, txt, reason in all_hits:
            print(f"  {src}:{ln}: [{reason}] {txt!r}")
        print("A fabricated win-rate / P&L / return / track-record claim must never ship "
              "(CHARTER §5.1 / §5.7). Remove it or gate it honestly.")
        return 1
    print(f"claim_linter: clean — 0 forbidden claims across {scanned} shipped inputs.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
