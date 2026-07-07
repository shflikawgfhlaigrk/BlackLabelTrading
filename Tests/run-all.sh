#!/bin/bash
# Black Label Trading — combined test gate.
# ──────────────────────────────────────────────────────────────────────────────
# Runs the maintained suites through their own entrypoints and prints one combined
# pass/fail total (fleet convention, matches BlackLabelLeads/Tests/run-tests.command):
#
#   1. Swift pure-logic engine tests    — Tests/run-tests.sh           (headless swiftc, no Xcode)
#   2. Backend engine + edge-gate tests — backend/run-tests.sh         (pytest if present, else stdlib)
#   3. Offline submission contract      — Tests/submission-contract.sh (macOS AppIcon/CFBundleIconName guard)
#   4. Built bundle Reference contract  — Tests/built-bundle-reference-contract.sh (when build app exists)
#
# Each sub-runner stays the source of truth for its own suite; this script only orchestrates
# them and aggregates the result. The real gate is the sub-runners' EXIT CODES — the printed
# counts are best-effort reporting parsed from whichever summary line the runner emits
# ("N passed, M failed" from Swift/stdlib, or pytest's "N passed in Xs").
#
# Usage:  ./Tests/run-all.sh        (exit 0 iff BOTH suites pass)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/blt-all.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

TOTAL_PASS=0
TOTAL_FAIL=0
ANY_SUITE_FAIL=0

# parse_counts <logfile> — emit "<passed> <failed>" from the last "...passed..." summary line.
# Handles "410 passed, 0 failed" (Swift/stdlib) and "48 passed in 0.16s" (pytest, failed→0),
# as well as pytest "1 failed, 47 passed in ...".
parse_counts() {
  local log="$1" line p f
  line="$(grep -E "[0-9]+ passed" "$log" | tail -1)"
  if [ -z "$line" ]; then echo "PARSE_FAIL"; return; fi
  p="$(echo "$line" | grep -oE "[0-9]+ passed" | grep -oE "[0-9]+")"
  if echo "$line" | grep -qE "[0-9]+ failed"; then
    f="$(echo "$line" | grep -oE "[0-9]+ failed" | grep -oE "[0-9]+")"
  else
    f="0"
  fi
  echo "$p $f"
}

run_suite() {
  local label="$1"; shift
  local log="$WORK/${label}.out"
  echo ""
  echo "──────────────────────────────────────────────────────────────"
  echo "==> [$label] $*"
  set +e
  ( cd "$ROOT" && "$@" ) 2>&1 | tee "$log"
  local code="${PIPESTATUS[0]}"
  set -e 2>/dev/null || true
  local counts; counts="$(parse_counts "$log")"
  if [ "$code" -ne 0 ]; then ANY_SUITE_FAIL=1; fi
  if [ "$counts" = "PARSE_FAIL" ]; then
    echo "    [$label] WARNING: no summary line parsed (exit=$code)"
    [ "$code" -ne 0 ] && TOTAL_FAIL=$((TOTAL_FAIL + 1))
  else
    local p f; read -r p f <<<"$counts"
    TOTAL_PASS=$((TOTAL_PASS + p))
    TOTAL_FAIL=$((TOTAL_FAIL + f))
    echo "    [$label] $p passed, $f failed (exit=$code)"
  fi
}

echo "==> Black Label Trading :: combined test gate"

run_suite "swift-logic"    bash "$ROOT/Tests/run-tests.sh"
run_suite "backend-engine" bash "$ROOT/backend/run-tests.sh"
run_suite "submission-contract" bash "$ROOT/Tests/submission-contract.sh"
if [ -d "$ROOT/build/Black Label Trading.app" ]; then
  run_suite "bundle-reference" bash "$ROOT/Tests/built-bundle-reference-contract.sh" "$ROOT/build/Black Label Trading.app"
else
  echo ""
  echo "──────────────────────────────────────────────────────────────"
  echo "==> [bundle-reference] skipped: no built app at $ROOT/build/Black Label Trading.app"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "==> COMBINED RESULT: $TOTAL_PASS passed, $TOTAL_FAIL failed"
echo "═══════════════════════════════════════════════════════════════"

if [ "$ANY_SUITE_FAIL" -ne 0 ] || [ "$TOTAL_FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
