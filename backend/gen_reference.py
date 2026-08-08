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
import bltd_analytics as A  # noqa: E402  — the SINGLE source of the grid-wide BH-FDR correction

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


def _uncommitted(path: str) -> bool | None:
    """True if the module that produced this artifact differs from what git_sha pins.

    git_sha alone does NOT pin the math: the prover can be edited in the working tree and still
    stamp a clean commit sha. When this is True the ONLY durable pin is prover_sha (the content
    hash of the file that actually ran) — so say so in the artifact rather than implying the
    commit reproduces it.
    """
    try:
        out = subprocess.check_output(
            ["git", "status", "--porcelain", "--", os.path.basename(path)],
            cwd=os.path.dirname(os.path.abspath(path)),
            stderr=subprocess.DEVNULL).decode().strip()
        return bool(out)
    except Exception:
        return None


def _file_sha(path: str) -> str:
    try:
        with open(path, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()[:16]
    except Exception:
        return "unknown"


def _apply_grid_fdr(cells: list[dict], q: float) -> int:
    """Demote every per-test-significant cell that does NOT survive a grid-wide Benjamini–Hochberg
    correction across the whole engine×contract family, and return the family size m.

    This is the SAME guard the live buyer path applies (bltd_analytics.gate_rerun, which calls the
    same _benjamini_hochberg) — the reference artifact previously skipped it and shipped a raw
    per-test p<alpha verdict as "cleared significance", inflating candidateCount by grid size.
    Mutates each cell in place: proven -> False, fdrRejected -> True. It can only ever DEMOTE.
    """
    # Every predeclared engine×contract cell belongs to the correction family. A completed active
    # engine with zero trades is a tested null at p=1.0; a retired duplicate is permanent historical
    # multiplicity debt at p=1.0. Dropping either would let today's activity shrink yesterday's
    # family and loosen the threshold.
    testable = list(cells)
    survivors = A._benjamini_hochberg([c["pEdge"] for c in testable], q)
    kept = {id(testable[i]) for i in survivors}
    m = len(testable)
    for c in testable:
        if c["proven"] and id(c) not in kept:
            c["proven"] = False
            c["fdrRejected"] = True
    return m


def _load(cx, sym):
    rows = list(cx.execute(
        "SELECT o::float8,h::float8,l::float8,c::float8,extract(epoch from ts)::float8 "
        "FROM bars WHERE symbol=%s ORDER BY ts ASC, id ASC", (sym,)))
    valid = [r for r in rows if None not in (r[0], r[1], r[2], r[3], r[4])]
    ohlc = [(r[0], r[1], r[2], r[3]) for r in valid]
    span = (valid[0][4], valid[-1][4]) if valid else (None, None)
    # The source table is mutable. Pin the exact ordered input bytes, not merely a human date range,
    # so a clean commit plus this digest can reproduce (or refute) the evidence snapshot.
    digest = hashlib.sha256()
    for o, h, low, c, epoch in valid:
        digest.update(
            (f"{sym}|{float(epoch):.6f}|{float(o):.17g}|{float(h):.17g}|"
             f"{float(low):.17g}|{float(c):.17g}\n").encode("utf-8"))
    return ohlc, span, digest.hexdigest()


def build(dsn: str, symbols: list[str]) -> dict:
    import psycopg  # imported here so the module imports even without the driver (buyer path never runs this)
    cx = psycopg.connect(dsn, autocommit=True, connect_timeout=5)
    cfg = S.CONFIG_DEFAULTS
    q = cfg.get("fdrQ", 0.10)
    series = {}
    source_inputs = []
    for sym in symbols:
        ohlc, (t0, t1), input_sha = _load(cx, sym)
        if len(ohlc) < 40:
            continue
        series[sym] = (ohlc, t0, t1, input_sha)
        source_inputs.append({
            "symbol": sym,
            "bars": len(ohlc),
            "from": time.strftime("%Y-%m-%d", time.gmtime(t0)) if t0 else None,
            "to": time.strftime("%Y-%m-%d", time.gmtime(t1)) if t1 else None,
            "input_sha256": input_sha,
        })
    engines = []
    all_cells = []                       # every (engine, contract) cell — the BH family
    for eng in S.FDR_ENGINE_FAMILY:
        if eng not in S.PROVERS:
            continue
        # For each engine, evaluate every reference contract and keep the honest per-contract verdict.
        contracts = []
        for sym in symbols:
            loaded = series.get(sym)
            if loaded is None:
                continue
            ohlc, t0, t1, input_sha = loaded
            retired = eng in S.DUPLICATE_ENGINE_ALIASES
            if retired:
                # Retired aliases preserve the historical family size but supply no current
                # evidence. Never run or clone the canonical prover: duplicated low p-values can
                # advance BH rank and make a canonical result easier to pass.
                v = {
                    "ok": False, "trades": 0, "winRate": 0.0, "expectancyR": 0.0,
                    "netPts": 0.0, "maxDrawdownR": 0.0, "pEdge": 1.0,
                    "reason": (f"retired duplicate of "
                               f"'{S.DUPLICATE_ENGINE_ALIASES[eng]}' — multiplicity debt only; "
                               "no current evidence"),
                }
            else:
                v = S.PROVERS[eng](ohlc, cfg)
            # Per-test candidacy ONLY. The grid-wide FDR pass below can demote this; nothing is
            # labeled a candidate until the whole family has been corrected.
            c = {
                "symbol": sym,
                "bars": len(ohlc),
                "from": time.strftime("%Y-%m-%d", time.gmtime(t0)) if t0 else None,
                "to": time.strftime("%Y-%m-%d", time.gmtime(t1)) if t1 else None,
                "proven": bool(v.get("ok")),
                "trades": int(v.get("trades", 0)),
                "winRate": round(float(v.get("winRate", 0.0)), 4),
                "expectancyR": round(float(v.get("expectancyR", 0.0)), 4),
                "netPts": round(float(v.get("netPts", 0.0)), 4),
                "maxDrawdownR": round(float(v.get("maxDrawdownR", 0.0)), 4),
                "pEdge": v.get("pEdge", 1.0),
                "input_sha256": input_sha,
                "reason": v.get("reason", ""),
            }
            if retired:
                c["retired"] = True
                c["fdrDebt"] = True
            contracts.append(c)
            all_cells.append(c)
        if not contracts:
            continue
        engines.append({
            "engine": eng,
            "label": S.__dict__.get("ENGINE_LABELS", {}).get(eng, eng),
            "retired": eng in S.DUPLICATE_ENGINE_ALIASES,
            "status": None,              # set after the family-wide correction
            "contracts": contracts,
        })

    # ── grid-wide Benjamini–Hochberg FDR control (the same guard the live buyer path applies) ──
    m = _apply_grid_fdr(all_cells, q)
    for c in all_cells:
        if c.get("fdrDebt"):
            c["verdict"] = "retired hypothesis (multiplicity debt only)"
        elif c["proven"]:
            c["verdict"] = "OOS candidate (cleared significance)"
        elif c.get("fdrRejected"):
            c["verdict"] = "no edge (FDR-rejected)"
            c["reason"] = (f"per-test significant (p={float(c['pEdge']):.3f}) but rejected by "
                           f"grid-wide FDR control across {m} tests (q={q:.2f})")
        else:
            c["verdict"] = "no edge"
    for e in engines:
        # Engine-level status is honest: "candidate" only if it survived the family-wide correction
        # on at least one real contract; otherwise "no edge". Never averaged into a single number.
        e["status"] = (
            "retired" if e.get("retired") else
            ("candidate" if any(c["proven"] for c in e["contracts"]) else "no_edge")
        )

    provenN = sum(1 for e in engines if e["status"] == "candidate")
    retired_debt_n = sum(1 for c in all_cells if c.get("fdrDebt"))
    snapshot_sha = hashlib.sha256(
        json.dumps(source_inputs, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    return {
        "kind": "reference_oos",
        "label": REFERENCE_LABEL,
        "disclaimer": ("These verdicts are the edge-gate's honest out-of-sample result on Black "
                       "Label's own historical ES bars. They are reference research, not your "
                       "results, not live, and not a guarantee. Your own engine fleet arms only "
                       "on the bars YOUR feed captures."),
        "source": "Black Label historical ES bars (WealthCharts-captured)",
        "source_inputs": source_inputs,
        "source_snapshot_sha256": snapshot_sha,
        "generated_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        # Provenance pins the math that ACTUALLY ran: the content hash of the prover module plus
        # the content hash of the module supplying the family-wide correction. git_sha is the tree
        # it was generated from; prover_uncommitted=True means that commit does NOT reproduce it
        # and prover_sha is the only durable pin (verify: shasum -a 256 backend/bltd_store.py).
        "prover_sha": _code_sha(),
        "prover_file": os.path.basename(S.__file__),
        "prover_uncommitted": _uncommitted(S.__file__),
        "fdr_module": os.path.basename(A.__file__),
        "fdr_module_sha": _file_sha(A.__file__),
        "git_sha": _git_sha(),
        "significance": {
            "alpha": S.SIG_ALPHA, "minTrades": S.SIG_MIN_N, "fdrQ": q, "gridCells": m,
            "retiredDebtCells": retired_debt_n,
            "test": (f"one-sided realized-mean-R Student-t with Newey-West serial-dependence "
                     f"variance (alpha={S.SIG_ALPHA}, n>={S.SIG_MIN_N}), then "
                     f"Benjamini-Hochberg FDR control at q={q} across the "
                     f"m={m}-cell engine x contract grid"),
        },
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
