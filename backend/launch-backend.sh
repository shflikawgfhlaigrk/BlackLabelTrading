#!/bin/bash
# Black Label Trading — self-contained backend launcher (ships INSIDE the .app bundle at
# Contents/Resources/backend). Starts the buyer's OWN data backend:
#   - serves /api/* on 127.0.0.1:8787 (bltd_api.py) — the app talks to this
#   - receives the buyer's OWN browser feed into a local SQLite store the product owns
#       * bundled browser bridge posts observed TopstepX/WealthCharts ticks or OHLC bars into /webhook/feed
#       (bltd_capture.py runs the capture + the single edge-gate evaluator that records fires)
#   - the store starts EMPTY and is filled ONLY by the buyer's own browser bridge/webhook feed
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

LOCK="$SUPPORT/launcher.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  # Another app window/action is already starting the backend. Wait briefly for the API pid to
  # appear; if the lock is stale, remove it and continue as the single launcher.
  for _ in {1..30}; do
    if [ -f "$SUPPORT/backend.pid" ] && kill -0 "$(cat "$SUPPORT/backend.pid" 2>/dev/null)" 2>/dev/null; then
      exit 0
    fi
    sleep 0.2
  done
  rmdir "$LOCK" 2>/dev/null || exit 0
  mkdir "$LOCK" 2>/dev/null || exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

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
# Backend reads/writes ONLY the product's own store + the buyer's own browser bridge/webhook feed.
export BLTD_STORE="${BLTD_STORE:-$SUPPORT/trading.sqlite3}"
export BLTD_CONFIG="${BLTD_CONFIG:-$SUPPORT/config.json}"
export BLTD_PORT="${BLTD_PORT:-8787}"
export BLTD_SCOPE="${BLTD_SCOPE:-all}"
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
  # keep it alive, but disable its direct browser readers so the bundled browser bridge is the single
# sender path into /webhook/feed.
supervisor_running() {
  local SPID="$1" NAME="$2" PID CMD
  PID="$(cat "$SPID" 2>/dev/null || true)"
  [ -n "$PID" ] || return 1
  CMD="$(ps -p "$PID" -o command= 2>/dev/null || true)"
  [ -n "$CMD" ] || return 1
  if [[ "$CMD" == *"bltd-supervisor-v2:$NAME"* ]]; then return 0; fi
  # Upgrade cleanup: older launchers used unmarked pgrep-based supervisors whose command line
  # included the full helper command. Stop that wrapper tree so the pid-file supervisor below owns
  # exactly one real child and never exposes the webhook token in `ps`.
  pkill -TERM -P "$PID" 2>/dev/null || true
  kill "$PID" 2>/dev/null || true
  rm -f "$SPID"
  return 1
}

start_supervisor() {
  local NAME="$1" SCRIPT="$2" SPID="$3" CPID="$4" CLOG="$5" MODE="$6"
  if supervisor_running "$SPID" "$NAME"; then return; fi
  nohup bash -c '
    set -u
    PY_BIN="$1"; SCRIPT="$2"; CLOG="$3"; CPID="$4"; MODE="$5"
    child_running() {
      local PID CMD
      PID="$(cat "$CPID" 2>/dev/null || true)"
      [ -n "$PID" ] || return 1
      CMD="$(ps -p "$PID" -o command= 2>/dev/null || true)"
      [ -n "$CMD" ] && [[ "$CMD" == *"$SCRIPT"* && "$CMD" == *python* && "$CMD" != *"bltd-supervisor"* ]]
    }
    find_existing_child() {
      ps -axo pid=,command= | awk -v script="$SCRIPT" \
        "index(\$0, script) && index(\$0, \"python\") && index(\$0, \"bltd-supervisor\") == 0 && index(\$0, \"bash -c\") == 0 { print \$1; exit }"
    }
    while true; do
      if ! child_running; then
        EXISTING="$(find_existing_child || true)"
        if [ -n "$EXISTING" ]; then
          echo "$EXISTING" > "$CPID"
        elif [ "$MODE" = "capture" ]; then
          BLTD_AUTO_BROWSER="0" BLTD_CAPTURE_BROWSER="0" "$PY_BIN" "$SCRIPT" >>"$CLOG" 2>&1 &
          echo $! > "$CPID"
        else
          "$PY_BIN" "$SCRIPT" >>"$CLOG" 2>&1 &
          echo $! > "$CPID"
        fi
      fi
      sleep 20
    done
  ' "bltd-supervisor-v2:$NAME" "$PY" "$SCRIPT" "$CLOG" "$CPID" "$MODE" >/dev/null 2>&1 &
  echo $! > "$SPID"
}

supervise_capture() {
  start_supervisor "capture" "$HERE/bltd_capture.py" \
    "$SUPPORT/capture-supervisor.pid" "$SUPPORT/capture.pid" "$SUPPORT/capture.log" "capture"
}

supervise_topstep_bridge() {
  start_supervisor "topstep-bridge" "$HERE/bltd_topstep_bridge.py" \
    "$SUPPORT/topstep-bridge-supervisor.pid" "$SUPPORT/topstep-bridge.pid" "$SUPPORT/topstep-bridge.log" "topstep-bridge"
}

supervise_capture
supervise_topstep_bridge

if [ "${1:-}" == "--bg" ]; then
  LOG="$SUPPORT/backend.log"; PIDF="$SUPPORT/backend.pid"
  if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; then
    echo "backend already running (pid $(cat "$PIDF")) → http://127.0.0.1:$BLTD_PORT  log: $LOG"
    exit 0
  fi
  EXISTING="$(pgrep -f "$HERE/bltd_api.py $BLTD_PORT" 2>/dev/null | head -n 1 || true)"
  if [ -n "$EXISTING" ]; then
    echo "$EXISTING" > "$PIDF"
    echo "backend already running (pid $EXISTING) → http://127.0.0.1:$BLTD_PORT  log: $LOG"
    exit 0
  fi
  nohup "$PY" "$HERE/bltd_api.py" "$BLTD_PORT" >>"$LOG" 2>&1 &
  echo $! > "$PIDF"
  echo "backend started (pid $(cat "$PIDF")) → http://127.0.0.1:$BLTD_PORT  log: $LOG"
else
  exec "$PY" "$HERE/bltd_api.py" "$BLTD_PORT"
fi
