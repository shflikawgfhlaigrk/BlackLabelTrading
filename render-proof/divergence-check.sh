#!/bin/bash
# blacklabel-trading-divergence-check.sh
# READ-ONLY divergence check for the proof ledger: does the LIVE Trading daemon
# (~/.blacklabel) run the SAME generic-named, Utah-decoupled backend a buyer ships
# with (the git bundle ~/BlackLabelTrading/backend == the .app's embedded backend)?
#
# Exit 0 + "SAME" only when every shipped backend file is byte-identical live, AND
# the live dir carries no extra/Utah-coupled backend files. Otherwise exit 1.
#
# This script writes NOTHING and restarts NOTHING. Safe to run in the ledger any time.
set -euo pipefail

BUNDLE="$HOME/BlackLabelTrading/backend"
LIVE="$HOME/.blacklabel"
APP="/Applications/Black Label Trading.app/Contents/Resources/backend"

# The backend files that SHIP (the canonical roster a buyer gets).
SHIP_FILES=(bltd_api.py bltd_analytics.py bltd_capture.py bltd_pg.py bltd_store.py)

# Live-only files that prove the live daemon is running a DIFFERENT (Utah-era / split-process)
# architecture than what ships. Their presence is a divergence.
FORBIDDEN_LIVE_EXTRAS=(bltd_engine.py bltd_parsers.py api_watch.py feed_watchdog.py harvest_parcels.py)

rc=0
echo "== blacklabel trading: deployed-vs-bundle divergence =="
echo "bundle: $BUNDLE"
echo "live:   $LIVE"
echo

echo "-- (1) shipped backend files: live must == bundle (byte-identical) --"
for f in "${SHIP_FILES[@]}"; do
  if [ ! -f "$LIVE/$f" ];   then echo "MISSING-LIVE   $f"; rc=1; continue; fi
  if [ ! -f "$BUNDLE/$f" ]; then echo "MISSING-BUNDLE $f"; rc=1; continue; fi
  if diff -q "$LIVE/$f" "$BUNDLE/$f" >/dev/null 2>&1; then
    echo "SAME      $f"
  else
    echo "DIFFERENT $f   live=$(md5 -q "$LIVE/$f")  bundle=$(md5 -q "$BUNDLE/$f")"; rc=1
  fi
done

echo
echo "-- (2) bundle must == the shipped .app's embedded backend (what a buyer actually runs) --"
if [ -d "$APP" ]; then
  for f in "${SHIP_FILES[@]}"; do
    if diff -q "$APP/$f" "$BUNDLE/$f" >/dev/null 2>&1; then echo "SAME      $f"
    else echo "DIFFERENT $f   app=$(md5 -q "$APP/$f" 2>/dev/null)  bundle=$(md5 -q "$BUNDLE/$f")"; rc=1; fi
  done
else
  echo "skip: $APP not present"
fi

echo
echo "-- (3) live must NOT carry Utah-era / split-process backend extras --"
for f in "${FORBIDDEN_LIVE_EXTRAS[@]}"; do
  if [ -f "$LIVE/$f" ]; then echo "EXTRA-IN-LIVE $f  (not in shipped bundle -> divergence)"; rc=1
  else echo "ABSENT    $f"; fi
done

echo
echo "-- (4) live must NOT advertise Utah-coupled engine names --"
if grep -qE '"(bible|apex|perp|barber|ctx_alpha|ctx_bravo)"' "$LIVE/bltd_store.py" 2>/dev/null; then
  echo "UTAH-NAMES-PRESENT in live bltd_store.py (bible/apex/perp/barber/ctx_*) -> divergence"; rc=1
else
  echo "OK: no Utah-coupled engine names in live bltd_store.py"
fi

echo
if [ "$rc" -eq 0 ]; then echo "RESULT: SAME  (live == shipped bundle)"; else echo "RESULT: DIVERGED"; fi
exit "$rc"
