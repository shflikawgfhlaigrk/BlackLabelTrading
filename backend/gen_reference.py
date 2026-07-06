#!/usr/bin/env python3
"""Generate the REFERENCE out-of-sample verdict artifact (reference_oos.json).

WHAT THIS IS
------------
This is a build-time research tool run by Black Label — NOT something that runs on a buyer's
machine. It runs the EXACT SAME shipped edge-gate provers (bltd_store.PROVERS / _summarize /
_edge_pvalue) over real, WealthCharts-captured ES bars from the vendor Postgres `bars` table, and
writes each engine's honest out-of-sample verdict to reference_oos.json. That JSON is then bundled
with the app and served (read-only) at GET /api/reference so a cold buyer — who has captured NO
bars of their own yet — can see that the edge-gate produces a real, earned verdict before they
spend weeks accumulating their own data.

HARD RULES (§5.1 / §5.7 — this is the whole moat)
-------------------------------------------------
* It is REFERENCE ONLY. It is computed on historical ES data, NOT the buyer's account, and is NOT
  a promise. No performance is guaranteed. The Swift panel and the served payload both carry that
  label verbatim.
* It is NEVER presented as the buyer's track record. There is NO aggregate win-rate, NO blended
  equity curve, NO "verified-live edge" claim. When an engine has no proven edge, the artifact
  says so honestly ("no edge") — that is the point of the product.
* Every number is computed here from real ES history by the shipped prover — nothing is typed in.
  Provenance (source, symbol, bar count, UTC date range, prover name, code sha) travels with the
  artifact so any verdict is reproducible: re-run this script against the same bars and get the
  same numbers.

USAGE
-----
    ~/.utah/venv/bin/python backend/gen_reference.py            # default vendor DSN + ES contracts
    BLTD_REF_DSN="host=/tmp port=5433 dbname=utah" python backend/gen_reference.py
    python backend/gen_reference.py CM.ESU6 CM.ESM6             # explicit symbols

If Postgres is unreachable it exits non-zero and writes NOTHING (never a painted/placeholder file).
"""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bltd_store as S  # noqa: E402  — the SINGLE source of the OOS math

DEFAULT_DSN = os.environ.get("BLTD_REF_DSN", "host=/tmp port=5433 dbname=utah")
# ES-family reference contracts. ES is the canonical liquid US index future the engines were
# designed around; multiple contract months give an honest cross-section (an edge on one contract
# that fails on another is shown as such, never averaged away).
DEFAULT_SYMBOLS = ["CM.ESU6", "CM.ESM6"]

OUT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "reference_oos.json")

REFERENCE_LABEL = ("Reference only — computed on historical ES data, NOT your account, "
                   "NOT a promise, no performance guaranteed.")


def _code_sha() -> str:
    """sha256 of the prover module so a verdict is tied to the exact math that produced it."""
    try:
        with open(S.__file__, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()[:16]
    except Exception:
        return "unknown"


def _git_sha() -> str:
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=os.path.dirname(os.path.abspath(__file__)),
            stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        return "unknown"


def _load(cx, sym):
    rows = list(cx.execute(
        "SELECT o::float8,h::float8,l::float8,c::float8,extract(epoch from ts)::float8 "
        "FROM bars WHERE symbol=%s ORDER BY ts ASC, id ASC", (sym,)))
    ohlc = [(r[0], r[1], r[2], r[3]) for r in rows if None not in (r[0], r[1], r[2], r[3])]
    span = (rows[0][4], rows[-1][4]) if rows else (None, None)
    return ohlc, span


def build(dsn: str, symbols: list[str]) -> dict:
    import psycopg  # imported here so the module imports even without the driver (buyer path never runs this)
    cx = psycopg.connect(dsn, autocommit=True, connect_timeout=5)
    cfg = S.CONFIG_DEFAULTS
    engines = []
    for eng, prover in S.PROVERS.items():
        # For each engine, evaluate every reference contract and keep the honest per-contract verdict.
        contracts = []
        for sym in symbols:
            ohlc, (t0, t1) = _load(cx, sym)
            if len(ohlc) < 40:
                continue
            v = prover(ohlc, cfg)
            proven = bool(v.get("ok"))
            contracts.append({
                "symbol": sym,
                "bars": len(ohlc),
                "from": time.strftime("%Y-%m-%d", time.gmtime(t0)) if t0 else None,
                "to": time.strftime("%Y-%m-%d", time.gmtime(t1)) if t1 else None,
                "proven": proven,
                "trades": int(v.get("trades", 0)),
                "winRate": round(float(v.get("winRate", 0.0)), 4),
                "expectancyR": round(float(v.get("expectancyR", 0.0)), 4),
                "netPts": round(float(v.get("netPts", 0.0)), 4),
                "pEdge": v.get("pEdge", 1.0),
                # honest verdict string: an OOS candidate that cleared significance, or "no edge"
                "verdict": ("OOS candidate (cleared significance)" if proven else "no edge"),
                "reason": v.get("reason", ""),
            })
        if not contracts:
            continue
        any_proven = any(c["proven"] for c in contracts)
        engines.append({
            "engine": eng,
            "label": S.__dict__.get("ENGINE_LABELS", {}).get(eng, eng),
            # Engine-level status is honest: "candidate" only if it cleared significance on at
            # least one real contract; otherwise "no edge". Never averaged into a single number.
            "status": "candidate" if any_proven else "no_edge",
            "contracts": contracts,
        })

    provenN = sum(1 for e in engines if e["status"] == "candidate")
    return {
        "kind": "reference_oos",
        "label": REFERENCE_LABEL,
        "disclaimer": ("These verdicts are the edge-gate's honest out-of-sample result on Black "
                       "Label's own historical ES bars. They are reference research, not your "
                       "results, not live, and not a guarantee. Your own engine fleet arms only "
                       "on the bars YOUR feed captures."),
        "source": "Black Label historical ES bars (WealthCharts-captured)",
        "generated_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "prover_sha": _code_sha(),
        "git_sha": _git_sha(),
        "significance": {"alpha": S.SIG_ALPHA, "minTrades": S.SIG_MIN_N,
                         "test": "one-sided binomial vs R-geometry breakeven, BH-FDR at grid level"},
        "engineCount": len(engines),
        "candidateCount": provenN,
        "engines": engines,
    }


def main() -> int:
    symbols = sys.argv[1:] or DEFAULT_SYMBOLS
    try:
        payload = build(DEFAULT_DSN, symbols)
    except Exception as e:  # unreachable DB / no driver -> write NOTHING, fail loud
        print(f"gen_reference: FAILED ({type(e).__name__}: {e}) — no artifact written", file=sys.stderr)
        return 2
    if not payload["engines"]:
        print("gen_reference: no engines had >=40 reference bars — no artifact written", file=sys.stderr)
        return 3
    with open(OUT_PATH, "w") as f:
        json.dump(payload, f, indent=2, sort_keys=False)
    cand = payload["candidateCount"]
    print(f"gen_reference: wrote {OUT_PATH}  ({payload['engineCount']} engines, "
          f"{cand} OOS candidate(s), prover_sha={payload['prover_sha']})")
    for e in payload["engines"]:
        for c in e["contracts"]:
            print(f"  {e['engine']:10s} {c['symbol']:8s} {c['verdict']:34s} "
                  f"trades={c['trades']:3d} win={c['winRate']*100:5.1f}% "
                  f"net={c['netPts']:+8.2f} p={c['pEdge']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
