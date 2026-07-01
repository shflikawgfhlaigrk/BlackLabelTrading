#!/bin/bash
# Black Label Trading — self-contained backend launcher (ships INSIDE the .app bundle at
# Contents/Resources/backend). Starts the buyer's OWN data backend:
#   - serves /api/* on 127.0.0.1:8787 (bltd_api.py) — the app talks to this
#   - receives the buyer's OWN TopstepX feed into a local SQLite store the product owns
#       * bundled Topstep bridge posts observed ticks or OHLC bars into /webhook/feed
#       (bltd_capture.py runs the capture + the single edge-gate evaluator that records fires)
#   - the store starts EMPTY and is filled ONLY by the buyer's own Topstep bridge/webhook feed
#
# FULLY SELF-CONTAINED + ZERO DATA: stdlib-only Python (no pip installs, no Postgres, no Utah),
# bundles NO credentials and NO bars. Optional autonomous execution is OFF by default (bltd_exec,
# paper-first); a live order needs the buyer to arm live + supply their own broker creds.
#
#   ./launch-backend.sh            # foreground (api), capture in background
#   ./launch-backend.sh --bg       # everything background (writes pids + logs under app-support)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUPPORT="$HOME/Library/Application Support/Black Label Trading"
mkdir -p "$SUPPORT"
PREREQ="$SUPPORT/prereq.json"
rm -f "$PREREQ"

# ---------------------------------------------------------------------------
# Locate the app-bundled CPython runtime. Fresh customer machines must not need Terminal, developer
# tools, Homebrew, or a manually installed Python. BLTD_PYTHON is kept only as a developer override.
# ---------------------------------------------------------------------------
works() { "$1" -c 'import sys; raise SystemExit(0 if sys.version_info[:2] >= (3,9) else 1)' >/dev/null 2>&1; }

PY=""
CANDIDATES=(
  "${BLTD_PYTHON:-}"
  "$HERE/python3"
)
for c in "${CANDIDATES[@]}"; do
  [ -n "$c" ] || continue
  if works "$c"; then PY="$c"; break; fi
done

if [ -z "$PY" ]; then
  # Honest package state: the shipped app should contain its own runtime. The buyer should replace
  # the app package, not run setup commands.
  cat >"$PREREQ" <<JSON
{"ok":false,"reason":"The app package is missing its bundled local runtime.","fix":"Reinstall Black Label Trading from the official download.","detail":"No Terminal commands are needed. Replace the app with a fresh copy from blacklabelbots.com, then reopen it.","ts":$(date +%s)}
JSON
  echo "Black Label Trading: bundled runtime missing — wrote package state to $PREREQ" >&2
  echo "Reinstall Black Label Trading from the official download, then relaunch." >&2
  exit 3
fi

export PYTHONPATH="$HERE:${PYTHONPATH:-}"
export PYTHONUNBUFFERED=1
export PYTHONDONTWRITEBYTECODE=1
# Backend reads/writes ONLY the product's own store + the buyer's own Topstep bridge/webhook feed.
export BLTD_STORE="${BLTD_STORE:-$SUPPORT/trading.sqlite3}"
export BLTD_CONFIG="${BLTD_CONFIG:-$SUPPORT/config.json}"
export BLTD_PORT="${BLTD_PORT:-8787}"
export BLTD_SCOPE="${BLTD_SCOPE:-es}"
TOKEN_FILE="$SUPPORT/webhook.token"
if [ -z "${BLTD_TOKEN:-}" ]; then
  if [ ! -s "$TOKEN_FILE" ]; then
    "$PY" - <<'PY' >"$TOKEN_FILE"
import secrets
print(secrets.token_urlsafe(24))
PY
    chmod 600 "$TOKEN_FILE" 2>/dev/null || true
  fi
  export BLTD_TOKEN="$(cat "$TOKEN_FILE")"
fi
export BLTD_WEBHOOK_URL="${BLTD_WEBHOOK_URL:-http://127.0.0.1:$BLTD_PORT/webhook/feed}"

# Start + SUPERVISE the evaluator daemon. This daemon hosts the SINGLE edge-gate evaluator that
# records fires on ES bars after the local webhook/store receives buyer data. The API server and this
# daemon are SEPARATE processes bridged ONLY by the shared store ($BLTD_STORE, exported above). We
# keep it alive, but disable its direct browser readers so the bundled Topstep bridge is the single
# sender path into /webhook/feed.
supervise_capture() {
  local SPID="$SUPPORT/capture-supervisor.pid" CLOG="$SUPPORT/capture.log"
  # one supervisor only: if the recorded pid is still alive, do nothing.
  if [ -f "$SPID" ] && kill -0 "$(cat "$SPID" 2>/dev/null)" 2>/dev/null; then return; fi
  nohup bash -c '
    while true; do
      pgrep -f "bltd_capture.py" >/dev/null 2>&1 || \
        BLTD_AUTO_BROWSER="0" BLTD_CAPTURE_BROWSER="0" "'"$PY"'" "'"$HERE"'/bltd_capture.py" >>"'"$CLOG"'" 2>&1 &
      sleep 20
    done
  ' >/dev/null 2>&1 &
  echo $! > "$SPID"
}

supervise_topstep_bridge() {
  local SPID="$SUPPORT/topstep-bridge-supervisor.pid" CLOG="$SUPPORT/topstep-bridge.log"
  if [ -f "$SPID" ] && kill -0 "$(cat "$SPID" 2>/dev/null)" 2>/dev/null; then return; fi
  nohup bash -c '
    while true; do
      pgrep -f "bltd_topstep_bridge.py" >/dev/null 2>&1 || \
        BLTD_TOKEN="'"$BLTD_TOKEN"'" BLTD_WEBHOOK_URL="'"$BLTD_WEBHOOK_URL"'" BLTD_PORT="'"$BLTD_PORT"'" "'"$PY"'" "'"$HERE"'/bltd_topstep_bridge.py" >>"'"$CLOG"'" 2>&1 &
      sleep 20
    done
  ' >/dev/null 2>&1 &
  echo $! > "$SPID"
}

supervise_capture
supervise_topstep_bridge

if [ "${1:-}" == "--bg" ]; then
  LOG="$SUPPORT/backend.log"; PIDF="$SUPPORT/backend.pid"
  nohup "$PY" "$HERE/bltd_api.py" "$BLTD_PORT" >>"$LOG" 2>&1 &
  echo $! > "$PIDF"
  echo "backend started (pid $(cat "$PIDF")) → http://127.0.0.1:$BLTD_PORT  log: $LOG"
else
  exec "$PY" "$HERE/bltd_api.py" "$BLTD_PORT"
fi
