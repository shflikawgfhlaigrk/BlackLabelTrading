#!/bin/bash
# Black Label Trading — combined test gate.
# ──────────────────────────────────────────────────────────────────────────────
# Runs the maintained suites through their own entrypoints and prints one combined
# pass/fail total (fleet convention, matches BlackLabelLeads/Tests/run-tests.command):
#
#   1. Swift pure-logic engine tests      — Tests/run-tests.sh           (headless swiftc, no Xcode)
#   2. Updater release-integrity contract — Tests/updater-release-integrity-contract.sh
#   3. Signals-only source/artifact gate  — Tests/signals-only-release-contract.sh
#   4. Backend engine + edge-gate tests   — backend/run-tests.sh         (pytest if present, else stdlib)
#   5. Production install guard contract  — Tests/production-install-guard-contract.sh
#   6. Windows W1 read-only verifier      — windows/verify-windows-lane.sh
#   7. Offline submission contracts       — Tests/submission-contract.sh + entitlements
#   8. Built bundle Reference contract    — Tests/built-bundle-reference-contract.sh (when build app exists)
#
# Each sub-runner stays the source of truth for its own suite; this script only orchestrates
# them and aggregates the result. The real gate is the sub-runners' EXIT CODES — the printed
# counts are best-effort reporting parsed from whichever summary line the runner emits
# ("N passed, M failed" from Swift/stdlib, or pytest's "N passed in Xs").
#
# Usage:  ./Tests/run-all.sh        (exit 0 iff every maintained suite passes)
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

SIGNALS_ONLY_ARGS=()
if [ -d "$ROOT/build/Black Label Trading.app" ]; then
  SIGNALS_ONLY_ARGS=("$ROOT/build/Black Label Trading.app")
fi

run_suite "swift-logic"    bash "$ROOT/Tests/run-tests.sh"
run_suite "updater-integrity" bash "$ROOT/Tests/updater-release-integrity-contract.sh"
run_suite "signals-only" bash "$ROOT/Tests/signals-only-release-contract.sh" \
  ${SIGNALS_ONLY_ARGS[@]+"${SIGNALS_ONLY_ARGS[@]}"}
run_suite "backend-engine" bash "$ROOT/backend/run-tests.sh"

# These are safe offline contracts: the install guard mocks codesign and is confined to this run's
# temp tree; the Windows verifier compiles/parses sources, runs tests, and calls supervisor --plan
# (no spawn). Disable Python/pytest caches so invoking it here remains read-only to the repository.
# Wrap their PASS-only output so the combined counter can account for them.
production_install_guard_suite() {
  local fixture_root="$WORK/production-install-guard"
  mkdir -p "$fixture_root"
  if TMPDIR="$fixture_root" bash "$ROOT/Tests/production-install-guard-contract.sh"; then
    echo "1 passed, 0 failed"
  else
    echo "0 passed, 1 failed"
    return 1
  fi
}
windows_lane_suite() {
  if PYTHONDONTWRITEBYTECODE=1 PYTEST_ADDOPTS="-p no:cacheprovider" \
    bash "$ROOT/windows/verify-windows-lane.sh"; then
    echo "1 passed, 0 failed"
  else
    echo "0 passed, 1 failed"
    return 1
  fi
}
run_suite "production-install-guard" production_install_guard_suite
run_suite "windows-lane" windows_lane_suite
run_suite "submission-contract" bash "$ROOT/Tests/submission-contract.sh"
run_suite "devid-entitlements" bash "$ROOT/Tests/devid-entitlements-contract.sh"

# TR-10 PERMANENT zero-claims linter — scans the shipped source surface, and the built binary too
# when present. This is the standing mechanism (⛔H1): no fabricated win-rate / P&L / return / track-
# record claim may reach a buyer. build.command runs the same linter to fail the build at compile.
LINTER_ARGS=()
if [ -x "$ROOT/build/Black Label Trading.app/Contents/MacOS/Black Label Trading" ]; then
  LINTER_ARGS=(--binary "$ROOT/build/Black Label Trading.app/Contents/MacOS/Black Label Trading")
fi
# Wrap the linter so it emits the "N passed, M failed" summary line run_suite's parser expects
# (the linter itself prints "clean —", which would otherwise hit run_suite's PARSE_FAIL path).
claim_linter_suite() {
  if python3 "$ROOT/backend/claim_linter.py" ${LINTER_ARGS[@]+"${LINTER_ARGS[@]}"}; then
    echo "1 passed, 0 failed"
  else
    echo "0 passed, 1 failed"; return 1
  fi
}
run_suite "claim-linter" claim_linter_suite

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
