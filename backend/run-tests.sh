#!/bin/bash
# Black Label Trading — backend engine test runner (pure stdlib; pytest optional).
# Runs the ported-engine + edge-gate test suite. Uses pytest when available, else the
# self-contained plain runner in test_engines.py (no third-party deps required).
#
#   bash backend/run-tests.sh
set -uo pipefail
cd "$(dirname "$0")"

FILES=(test_engines.py test_feeds.py test_api.py test_topstep_bridge.py test_store_scope.py test_claim_linter.py test_alerts.py test_egress.py test_farm.py test_optimizer.py test_optimizer_cli.py test_runtime_contract.py test_windows_lane.py test_reference_fdr.py test_reference_auth.py)

if python3 -c "import pytest" 2>/dev/null; then
  # pytest emits ONE combined "N passed[, M failed]" summary line — run-all.sh parses it directly.
  exec python3 -m pytest "${FILES[@]}" -q
fi

# ── stdlib fallback (no pytest) ──────────────────────────────────────────────
# Each file is self-contained. Some print "N passed, M failed" (Swift/stdlib convention); a couple
# (e.g. test_topstep_bridge.py) print only "ok <name>" / "FAIL <name>" lines. The OLD runner chained
# these with `&&` and emitted 7 separate summary lines, so run-all.sh's tail-1 parser only ever saw
# the LAST file's count — silently undercounting the backend suite. Run every file, count honestly
# (summary line when present, else ok/FAIL/ERR lines), and emit ONE aggregate summary line so the
# combined gate reports the TRUE sum. Exit non-zero if any file fails or errors.
TOTAL_PASS=0
TOTAL_FAIL=0
ANY_FAIL=0
for f in "${FILES[@]}"; do
  out="$(python3 "$f" 2>&1)"; code=$?
  echo "$out"
  line="$(echo "$out" | grep -E "[0-9]+ passed" | tail -1)"
  if [ -n "$line" ]; then
    p="$(echo "$line" | grep -oE "[0-9]+ passed" | grep -oE "[0-9]+")"
    if echo "$line" | grep -qE "[0-9]+ failed"; then
      fl="$(echo "$line" | grep -oE "[0-9]+ failed" | grep -oE "[0-9]+")"
    else
      fl=0
    fi
  else
    # no summary line — count "ok " passes and FAIL/ERR failures (e.g. test_topstep_bridge.py)
    p="$(echo "$out" | grep -cE '^ok ')"
    fl="$(echo "$out" | grep -cE '^(FAIL|ERR) ')"
  fi
  TOTAL_PASS=$((TOTAL_PASS + ${p:-0}))
  TOTAL_FAIL=$((TOTAL_FAIL + ${fl:-0}))
  if [ "$code" -ne 0 ] || [ "${fl:-0}" -ne 0 ]; then ANY_FAIL=1; fi
done

echo ""
echo "backend suite TOTAL: $TOTAL_PASS passed, $TOTAL_FAIL failed"
if [ "$ANY_FAIL" -ne 0 ] || [ "$TOTAL_FAIL" -ne 0 ]; then exit 1; fi
exit 0
