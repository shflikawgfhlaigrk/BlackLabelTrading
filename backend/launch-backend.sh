#!/bin/bash
# Black Label Trading — self-contained backend launcher (ships INSIDE the .app bundle at
# Contents/Resources/backend). Starts the buyer's OWN data backend:
#   - serves /api/* on 127.0.0.1:8793 (bltd_api.py) — the app talks to this
#   - receives the buyer's OWN browser feed into a local SQLite store the product owns
#       * bundled browser bridge posts observed TopstepX/WealthCharts ticks or OHLC bars into /webhook/feed
#       (bltd_capture.py runs the capture + the single edge-gate evaluator that records fires)
#   - the store starts EMPTY and is filled ONLY by the buyer's own browser bridge/webhook feed
#
# FULLY SELF-CONTAINED + ZERO DATA: stdlib-only Python (no pip installs, no Postgres, no Utah),
# bundles NO credentials, bars, or broker-order adapter. The product is signals-only.
#
#   ./launch-backend.sh            # foreground (api), capture in background
#   ./launch-backend.sh --bg       # everything background (writes pids + logs under app-support)
set -uo pipefail
umask 077
HERE="$(cd "$(dirname "$0")" && pwd)"
RUNTIME_HOME="${HOME:-/var/empty}"
RUNTIME_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
RUNTIME_LANG="C"
SUPPORT="${BLTD_SUPPORT_DIR:-$RUNTIME_HOME/Library/Application Support/Black Label Trading}"
mkdir -p "$SUPPORT"
PREREQ="$SUPPORT/prereq.json"
rm -f "$PREREQ"

LOCK="$SUPPORT/launcher.lock"
LOCK_ACQUIRED=0
if mkdir "$LOCK" 2>/dev/null; then
  LOCK_ACQUIRED=1
else
  # Another app window/action is already starting the backend. Wait for its lock to clear. Reclaim
  # only a lock whose recorded launcher PID is no longer alive; never delete a live launcher's lock.
  for _ in {1..30}; do
    OWNER="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [ -n "$OWNER" ] && ! kill -0 "$OWNER" 2>/dev/null; then
      rm -f "$LOCK/pid"
      rmdir "$LOCK" 2>/dev/null || true
    fi
    if mkdir "$LOCK" 2>/dev/null; then
      LOCK_ACQUIRED=1
      break
    fi
    sleep 0.2
  done
fi
if [ "$LOCK_ACQUIRED" -ne 1 ]; then
  if [ "${1:-}" = "--stop-owned" ]; then
    echo "Black Label Trading: runtime teardown could not acquire the launcher lock." >&2
    exit 6
  fi
  exit 0
fi
printf '%s\n' "$$" >"$LOCK/pid"
release_launcher_lock() {
  if [ "$LOCK_ACQUIRED" -eq 1 ]; then
    rm -f "$LOCK/pid"
    rmdir "$LOCK" 2>/dev/null || true
    LOCK_ACQUIRED=0
  fi
}
trap release_launcher_lock EXIT

# ---------------------------------------------------------------------------
# Locate the app-bundled CPython runtime. Fresh customer machines must not need Terminal, developer
# tools, Homebrew, or a manually installed Python. BLTD_PYTHON is kept only as a developer override.
# ---------------------------------------------------------------------------
works() {
  /usr/bin/env -i \
    "HOME=$RUNTIME_HOME" \
    "PATH=$RUNTIME_PATH" \
    "LANG=$RUNTIME_LANG" \
    "LC_ALL=$RUNTIME_LANG" \
    "PYTHONNOUSERSITE=1" \
    "PYTHONPYCACHEPREFIX=$SUPPORT/pycache" \
    "BLTD_PYCACHE_ROOT=$SUPPORT/pycache" \
    "$1" -c 'import sys; raise SystemExit(0 if sys.version_info[:2] >= (3,9) else 1)' \
    >/dev/null 2>&1
}

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

unset PYTHONHOME PYTHONSTARTUP PYTHONINSPECT PYTHONUSERBASE
unset BASH_ENV ENV
unset DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH
unset DYLD_FALLBACK_LIBRARY_PATH DYLD_FALLBACK_FRAMEWORK_PATH
export PYTHONPATH="$HERE"
export PYTHONUNBUFFERED=1
export PYTHONDONTWRITEBYTECODE=1
export PYTHONNOUSERSITE=1
# Backend reads/writes ONLY the product's own store + the buyer's own browser bridge/webhook feed.
export BLTD_STORE="${BLTD_STORE:-$SUPPORT/trading.sqlite3}"
export BLTD_CONFIG="${BLTD_CONFIG:-$SUPPORT/config.json}"
export BLTD_PORT="${BLTD_PORT:-8793}"
export BLTD_SCOPE="${BLTD_SCOPE:-all}"
INFO_PLIST="$HERE/../../Info.plist"
if [ -z "${BLTD_BUILD:-}" ] && [ -f "$INFO_PLIST" ]; then
  BLTD_BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$INFO_PLIST" 2>/dev/null || true)"
fi
export BLTD_BUILD="${BLTD_BUILD:-dev}"
export BLTD_RUNTIME_CONTRACT="bltd-signals-only-runtime-v1"
# A signed app bundle is immutable. Force every Python cache outside Contents/Resources even if a
# future interpreter ignores PYTHONDONTWRITEBYTECODE for an import path.
export PYTHONPYCACHEPREFIX="$SUPPORT/pycache"
mkdir -p "$PYTHONPYCACHEPREFIX"
TOKEN_FILE="$SUPPORT/webhook.token"
TOKEN_TMP="$TOKEN_FILE.tmp.$$"
if [ -n "${BLTD_TOKEN:-}" ]; then
  printf '%s\n' "$BLTD_TOKEN" >"$TOKEN_TMP" &&
    mv -f "$TOKEN_TMP" "$TOKEN_FILE"
elif [ ! -s "$TOKEN_FILE" ]; then
  if "$PY" - <<'PY' >"$TOKEN_TMP"
import secrets
print(secrets.token_urlsafe(24))
PY
  then
    mv -f "$TOKEN_TMP" "$TOKEN_FILE"
  else
    rm -f "$TOKEN_TMP"
  fi
fi
rm -f "$TOKEN_TMP"
[ -s "$TOKEN_FILE" ] || {
  echo "Black Label Trading: local webhook token could not be created." >&2
  exit 3
}
chmod 600 "$TOKEN_FILE" 2>/dev/null || true
unset BLTD_TOKEN
export BLTD_TOKEN_FILE="$TOKEN_FILE"
export BLTD_WEBHOOK_URL="${BLTD_WEBHOOK_URL:-http://127.0.0.1:$BLTD_PORT/webhook/feed}"
export BLTD_CAPTURE_BROWSER=0
export BLTD_AUTO_BROWSER=0
export BLTD_CAPTURE_ENGINES="${BLTD_CAPTURE_ENGINES:-1}"
export BLTD_CDP_PORT="${BLTD_CDP_PORT:-9223}"
export BLTD_BAR_SECONDS="${BLTD_BAR_SECONDS:-15}"
export BLTD_LOOKBACK="${BLTD_LOOKBACK:-20}"
export BLTD_EDGE_GATE="${BLTD_EDGE_GATE:-1}"
export BLTD_STALL_SECONDS="${BLTD_STALL_SECONDS:-45}"
export BLTD_TOPSTEP_OPEN_DEBOUNCE_SECONDS="${BLTD_TOPSTEP_OPEN_DEBOUNCE_SECONDS:-90}"

# Every long-lived process starts from an empty environment. Only the product's exact local runtime
# contract crosses the boundary; caller credentials, shell hooks, Python injection variables, and
# unrelated developer-session state never enter the API or supervisor trees.
RUNTIME_ENV=(
  "HOME=$RUNTIME_HOME"
  "PATH=$RUNTIME_PATH"
  "LANG=$RUNTIME_LANG"
  "LC_ALL=$RUNTIME_LANG"
  "PYTHONPATH=$HERE"
  "PYTHONUNBUFFERED=1"
  "PYTHONDONTWRITEBYTECODE=1"
  "PYTHONNOUSERSITE=1"
  "PYTHONPYCACHEPREFIX=$PYTHONPYCACHEPREFIX"
  "BLTD_SUPPORT_DIR=$SUPPORT"
  "BLTD_STORE=$BLTD_STORE"
  "BLTD_CONFIG=$BLTD_CONFIG"
  "BLTD_PORT=$BLTD_PORT"
  "BLTD_SCOPE=$BLTD_SCOPE"
  "BLTD_BUILD=$BLTD_BUILD"
  "BLTD_RUNTIME_CONTRACT=$BLTD_RUNTIME_CONTRACT"
  "BLTD_TOKEN_FILE=$BLTD_TOKEN_FILE"
  "BLTD_WEBHOOK_URL=$BLTD_WEBHOOK_URL"
  "BLTD_CAPTURE_BROWSER=0"
  "BLTD_AUTO_BROWSER=0"
  "BLTD_CAPTURE_ENGINES=$BLTD_CAPTURE_ENGINES"
  "BLTD_CDP_PORT=$BLTD_CDP_PORT"
  "BLTD_BAR_SECONDS=$BLTD_BAR_SECONDS"
  "BLTD_LOOKBACK=$BLTD_LOOKBACK"
  "BLTD_EDGE_GATE=$BLTD_EDGE_GATE"
  "BLTD_STALL_SECONDS=$BLTD_STALL_SECONDS"
  "BLTD_TOPSTEP_OPEN_DEBOUNCE_SECONDS=$BLTD_TOPSTEP_OPEN_DEBOUNCE_SECONDS"
)

health_is_ours() {
  "$PY" - "$BLTD_PORT" "$BLTD_BUILD" "$BLTD_RUNTIME_CONTRACT" "$HERE/bltd_api.py" <<'PY' >/dev/null 2>&1
import json
import os
import sys
import urllib.request

try:
    with urllib.request.urlopen(f"http://127.0.0.1:{int(sys.argv[1])}/health", timeout=0.6) as r:
        body = json.load(r)
    capabilities = body.get("capabilities") or {}
    raise SystemExit(0 if body.get("ok") is True
                     and body.get("service") == "black-label-trading"
                     and str(body.get("build")) == sys.argv[2]
                     and body.get("runtimeContract") == sys.argv[3]
                     and os.path.realpath(str(body.get("backendScript") or "")) == os.path.realpath(sys.argv[4])
                     and capabilities.get("signals") is True
                     and capabilities.get("execution") is False
                     and capabilities.get("optimizerCompute") is False else 1)
except Exception:
    raise SystemExit(1)
PY
}

port_is_listening() {
  "$PY" - "$BLTD_PORT" <<'PY' >/dev/null 2>&1
import socket
import sys

try:
    port = int(sys.argv[1])
    if not 1 <= port <= 65535:
        raise ValueError("port out of range")
except Exception:
    raise SystemExit(2)
with socket.socket() as s:
    s.settimeout(0.4)
    raise SystemExit(0 if s.connect_ex(("127.0.0.1", port)) == 0 else 1)
PY
}

write_port_prereq() {
  "$PY" - "$BLTD_PORT" <<'PY' >"$PREREQ"
import json
import sys
import time

port = sys.argv[1]
print(json.dumps({
    "ok": False,
    "reason": f"Local port {port} is already owned by another service.",
    "fix": "Choose an unused localhost port in Settings, then reconnect.",
    "detail": "Trading refused to claim another service's listener and did not report a false start.",
    "ts": int(time.time()),
}, separators=(",", ":")))
PY
}

CANONICAL_BACKEND="/Applications/Black Label Trading.app/Contents/Resources/backend"
EXTRA_OWNED_BACKEND=""
EXTRA_OWNED_BACKEND_REAL=""
if [ -n "${BLTD_OWNED_BACKEND_DIR:-}" ] &&
   [[ "$BLTD_OWNED_BACKEND_DIR" == /*/Contents/Resources/backend ]] &&
   [ -d "$BLTD_OWNED_BACKEND_DIR" ]; then
  EXTRA_OWNED_BACKEND="$BLTD_OWNED_BACKEND_DIR"
  EXTRA_OWNED_BACKEND_REAL="$(cd "$BLTD_OWNED_BACKEND_DIR" && pwd -P)"
fi

valid_pid() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

write_pidfile_atomic() {
  local PIDFILE="$1" PID="$2" TMP
  valid_pid "$PID" || return 1
  TMP="$PIDFILE.tmp.$$"
  if ! printf '%s\n' "$PID" >"$TMP" || ! mv -f "$TMP" "$PIDFILE"; then
    rm -f "$TMP"
    return 1
  fi
}

remove_pidfile_if_same() {
  local PIDFILE="$1" EXPECTED="$2" CURRENT
  CURRENT="$(cat "$PIDFILE" 2>/dev/null || true)"
  [ "$CURRENT" = "$EXPECTED" ] && rm -f "$PIDFILE"
}

command_has_owned_script() {
  local CMD="$1" SCRIPT="$2" CANONICAL
  CANONICAL="$CANONICAL_BACKEND/$(basename "$SCRIPT")"
  [[ "$CMD" == *"$SCRIPT"* || "$CMD" == *"$CANONICAL"* ]] ||
    { [ -n "$EXTRA_OWNED_BACKEND" ] &&
      [[ "$CMD" == *"$EXTRA_OWNED_BACKEND/$(basename "$SCRIPT")"* ||
         "$CMD" == *"$EXTRA_OWNED_BACKEND_REAL/$(basename "$SCRIPT")"* ]]; }
}

command_is_python() {
  local CMD="$1"
  [[ "$CMD" == *python* || "$CMD" == *Python* ]]
}

owned_api_command() {
  local CMD="$1" SCRIPT PORT
  command_is_python "$CMD" || return 1
  for SCRIPT in "$HERE/bltd_api.py" "$CANONICAL_BACKEND/bltd_api.py" \
    "${EXTRA_OWNED_BACKEND:+$EXTRA_OWNED_BACKEND/bltd_api.py}" \
    "${EXTRA_OWNED_BACKEND_REAL:+$EXTRA_OWNED_BACKEND_REAL/bltd_api.py}"; do
    [ -n "$SCRIPT" ] || continue
    case "$CMD" in
      *"$SCRIPT "*)
        PORT="${CMD##*"$SCRIPT "}"
        if [[ "$PORT" =~ ^[1-9][0-9]*$ ]] && [ "$PORT" -le 65535 ]; then
          return 0
        fi
        ;;
    esac
  done
  return 1
}

owned_process_command() {
  local KIND="$1" NAME="$2" SCRIPT="$3" CMD="$4"
  case "$KIND" in
    api)
      owned_api_command "$CMD"
      ;;
    supervisor)
      command_has_owned_script "$CMD" "$SCRIPT" || return 1
      [[ "$CMD" == *"bltd-supervisor-v2:$NAME"* ||
         "$CMD" == *"bltd-supervisor-v3:"*":$NAME"* ]]
      ;;
    worker)
      command_has_owned_script "$CMD" "$SCRIPT" &&
        command_is_python "$CMD" &&
        [[ "$CMD" != *"bltd-supervisor"* ]]
      ;;
    *)
      return 1
      ;;
  esac
}

current_process_command() {
  local KIND="$1" NAME="$2" SCRIPT="$3" CMD="$4"
  case "$KIND" in
    supervisor)
      [[ "$CMD" == *"bltd-supervisor-v3:$BLTD_BUILD:$NAME"* &&
         "$CMD" == *"$SCRIPT"* ]]
      ;;
    worker)
      [[ "$CMD" == *"bltd-worker-v3:$BLTD_BUILD:$NAME"* &&
         "$CMD" == *"$SCRIPT"* &&
         ( "$CMD" == *python* || "$CMD" == *Python* ) &&
         "$CMD" != *"bltd-supervisor"* ]]
      ;;
    *)
      return 1
      ;;
  esac
}

pidfile_process_is_current() {
  local PIDFILE="$1" KIND="$2" NAME="$3" SCRIPT="$4" PID CMD
  PID="$(cat "$PIDFILE" 2>/dev/null || true)"
  valid_pid "$PID" || return 1
  CMD="$(ps -ww -p "$PID" -o command= 2>/dev/null || true)"
  [ -n "$CMD" ] && current_process_command "$KIND" "$NAME" "$SCRIPT" "$CMD"
}

stop_owned_pidfile() {
  local PIDFILE="$1" KIND="$2" NAME="$3" SCRIPT="$4" PID CMD CURRENT
  PID="$(cat "$PIDFILE" 2>/dev/null || true)"
  if ! valid_pid "$PID"; then
    remove_pidfile_if_same "$PIDFILE" "$PID"
    return 0
  fi
  CMD="$(ps -ww -p "$PID" -o command= 2>/dev/null || true)"
  if [ -z "$CMD" ]; then
    remove_pidfile_if_same "$PIDFILE" "$PID"
    return 0
  fi
  if ! owned_process_command "$KIND" "$NAME" "$SCRIPT" "$CMD"; then
    # A stale pidfile may now name an unrelated live process. Discard the product metadata but
    # never signal that process.
    remove_pidfile_if_same "$PIDFILE" "$PID"
    return 0
  fi
  [ "$(cat "$PIDFILE" 2>/dev/null || true)" = "$PID" ] || return 0
  kill -TERM "$PID" 2>/dev/null || true
  for _ in {1..20}; do
    kill -0 "$PID" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$PID" 2>/dev/null; then
    CURRENT="$(ps -ww -p "$PID" -o command= 2>/dev/null || true)"
    if [ "$(cat "$PIDFILE" 2>/dev/null || true)" = "$PID" ] &&
       owned_process_command "$KIND" "$NAME" "$SCRIPT" "$CURRENT"; then
      kill -KILL "$PID" 2>/dev/null || true
      for _ in {1..10}; do
        kill -0 "$PID" 2>/dev/null || break
        sleep 0.1
      done
    fi
  fi
  CURRENT="$(ps -ww -p "$PID" -o command= 2>/dev/null || true)"
  if kill -0 "$PID" 2>/dev/null &&
     owned_process_command "$KIND" "$NAME" "$SCRIPT" "$CURRENT"; then
    return 1
  fi
  remove_pidfile_if_same "$PIDFILE" "$PID"
  return 0
}

stop_owned_runtime() {
  local FAILED=0
  # Supervisors first, then their workers, so an old in-memory supervisor cannot respawn a worker
  # after a direct/manual app replacement. The API comes last and may be on legacy :8787.
  stop_owned_pidfile "$SUPPORT/capture-supervisor.pid" \
    supervisor capture "$HERE/bltd_capture.py" || FAILED=1
  stop_owned_pidfile "$SUPPORT/topstep-bridge-supervisor.pid" \
    supervisor topstep-bridge "$HERE/bltd_topstep_bridge.py" || FAILED=1
  stop_owned_pidfile "$SUPPORT/capture.pid" \
    worker capture "$HERE/bltd_capture.py" || FAILED=1
  stop_owned_pidfile "$SUPPORT/topstep-bridge.pid" \
    worker topstep-bridge "$HERE/bltd_topstep_bridge.py" || FAILED=1
  stop_owned_pidfile "$SUPPORT/backend.pid" \
    api backend "$HERE/bltd_api.py" || FAILED=1
  return "$FAILED"
}

# Start + SUPERVISE the evaluator daemon. This daemon hosts the SINGLE edge-gate evaluator that
# records fires on ES bars after the local webhook/store receives buyer data. The API server and this
# daemon are SEPARATE processes bridged ONLY by the shared store ($BLTD_STORE, exported above). We
  # keep it alive, but disable its direct browser readers so the bundled browser bridge is the single
# sender path into /webhook/feed.
supervisor_running() {
  local SPID="$1" CPID="$2" NAME="$3" SCRIPT="$4"
  pidfile_process_is_current "$SPID" supervisor "$NAME" "$SCRIPT" &&
    pidfile_process_is_current "$CPID" worker "$NAME" "$SCRIPT"
}

start_supervisor() {
  local NAME="$1" SCRIPT="$2" SPID="$3" CPID="$4" CLOG="$5" MODE="$6"
  local WORKER_MARKER="bltd-worker-v3:$BLTD_BUILD:$NAME" SUPERVISOR_PID
  if supervisor_running "$SPID" "$CPID" "$NAME" "$SCRIPT"; then return; fi
  stop_owned_pidfile "$SPID" supervisor "$NAME" "$SCRIPT" || return 1
  stop_owned_pidfile "$CPID" worker "$NAME" "$SCRIPT" || return 1
  nohup /usr/bin/env -i "${RUNTIME_ENV[@]}" /bin/bash -c '
    set -uo pipefail
    umask 077
    PY_BIN="$1"; SCRIPT="$2"; CLOG="$3"; CPID="$4"; MODE="$5"; WORKER_MARKER="$6"
    CHILD_PID=""
    TIMER_PID=""
    valid_pid() {
      [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
    }
    child_command_is_ours() {
      local PID="$1" CMD
      CMD="$(/bin/ps -ww -p "$PID" -o command= 2>/dev/null || true)"
      [ -n "$CMD" ] &&
        [[ "$CMD" == *"$SCRIPT"* && "$CMD" == *"$WORKER_MARKER"* &&
           ( "$CMD" == *python* || "$CMD" == *Python* ) &&
           "$CMD" != *"bltd-supervisor"* ]]
    }
    child_running() {
      local PID CMD
      PID="$CHILD_PID"
      valid_pid "$PID" || PID="$(cat "$CPID" 2>/dev/null || true)"
      [[ "$PID" =~ ^[1-9][0-9]*$ ]] || return 1
      child_command_is_ours "$PID" || return 1
      CHILD_PID="$PID"
    }
    publish_child_pid() {
      local PID="$1" TMP="$CPID.tmp.$$"
      printf "%s\n" "$PID" >"$TMP" && /bin/mv -f "$TMP" "$CPID"
    }
    remove_child_pidfile_if_same() {
      local PID="$1" CURRENT
      CURRENT="$(cat "$CPID" 2>/dev/null || true)"
      [ "$CURRENT" = "$PID" ] && /bin/rm -f "$CPID"
    }
    stop_child() {
      local PID CMD
      PID="$CHILD_PID"
      valid_pid "$PID" || PID="$(cat "$CPID" 2>/dev/null || true)"
      if ! valid_pid "$PID"; then
        return
      fi
      if child_command_is_ours "$PID"; then
        /bin/kill -TERM "$PID" 2>/dev/null || true
        for _ in {1..20}; do
          /bin/kill -0 "$PID" 2>/dev/null || break
          /bin/sleep 0.05
        done
        if /bin/kill -0 "$PID" 2>/dev/null && child_command_is_ours "$PID"; then
          /bin/kill -KILL "$PID" 2>/dev/null || true
          for _ in {1..20}; do
            /bin/kill -0 "$PID" 2>/dev/null || break
            /bin/sleep 0.05
          done
        fi
      fi
      if ! /bin/kill -0 "$PID" 2>/dev/null; then
        remove_child_pidfile_if_same "$PID"
      fi
      CHILD_PID=""
    }
    shutdown() {
      trap - HUP INT TERM EXIT
      if valid_pid "$TIMER_PID"; then
        /bin/kill -TERM "$TIMER_PID" 2>/dev/null || true
      fi
      stop_child
      exit 0
    }
    trap shutdown HUP INT TERM EXIT
    while true; do
      if ! child_running; then
        if [ "$MODE" = "capture" ]; then
          BLTD_AUTO_BROWSER="0" BLTD_CAPTURE_BROWSER="0" \
            "$PY_BIN" "$SCRIPT" "$WORKER_MARKER" >>"$CLOG" 2>&1 &
        else
          "$PY_BIN" "$SCRIPT" "$WORKER_MARKER" >>"$CLOG" 2>&1 &
        fi
        CHILD_PID=$!
        if ! publish_child_pid "$CHILD_PID"; then
          stop_child
          exit 1
        fi
      fi
      /bin/sleep 20 &
      TIMER_PID=$!
      wait "$TIMER_PID" 2>/dev/null || true
      TIMER_PID=""
    done
  ' "bltd-supervisor-v3:$BLTD_BUILD:$NAME" \
    "$PY" "$SCRIPT" "$CLOG" "$CPID" "$MODE" "$WORKER_MARKER" >/dev/null 2>&1 &
  SUPERVISOR_PID=$!
  if ! write_pidfile_atomic "$SPID" "$SUPERVISOR_PID"; then
    kill -TERM "$SUPERVISOR_PID" 2>/dev/null || true
    return 1
  fi
  for _ in {1..30}; do
    if supervisor_running "$SPID" "$CPID" "$NAME" "$SCRIPT"; then
      return 0
    fi
    sleep 0.05
  done
  stop_owned_pidfile "$SPID" supervisor "$NAME" "$SCRIPT" || true
  stop_owned_pidfile "$CPID" worker "$NAME" "$SCRIPT" || true
  return 1
}

supervise_capture() {
  start_supervisor "capture" "$HERE/bltd_capture.py" \
    "$SUPPORT/capture-supervisor.pid" "$SUPPORT/capture.pid" "$SUPPORT/capture.log" "capture"
}

supervise_topstep_bridge() {
  start_supervisor "topstep-bridge" "$HERE/bltd_topstep_bridge.py" \
    "$SUPPORT/topstep-bridge-supervisor.pid" "$SUPPORT/topstep-bridge.pid" "$SUPPORT/topstep-bridge.log" "topstep-bridge"
}

if [ "${1:-}" == "--stop-owned" ]; then
  if stop_owned_runtime; then
    exit 0
  fi
  echo "Black Label Trading: a verified owned process refused to stop." >&2
  exit 6
fi

# Reuse requires this exact build, script path, and signals-only capability contract. Otherwise stop
# every positively verified process named by the product pidfiles before inspecting the new port.
# This ordering closes the b26 :8787 -> b27 :8793 migration hole during a direct/manual replacement.
BACKEND_ALREADY_HEALTHY=0
if health_is_ours; then
  BACKEND_ALREADY_HEALTHY=1
else
  if ! stop_owned_runtime; then
    echo "Black Label Trading: a verified legacy backend process refused to stop." >&2
    exit 6
  fi
  if port_is_listening; then
    write_port_prereq
    echo "Black Label Trading: 127.0.0.1:$BLTD_PORT is already owned by another service (incompatible or unverified listener); backend not started." >&2
    exit 4
  fi
fi

supervise_capture || {
  echo "Black Label Trading: capture supervisor could not be replaced safely." >&2
  exit 6
}
supervise_topstep_bridge || {
  echo "Black Label Trading: browser-bridge supervisor could not be replaced safely." >&2
  exit 6
}

if [ "${1:-}" == "--bg" ]; then
  LOG="$SUPPORT/backend.log"; PIDF="$SUPPORT/backend.pid"
  if [ "$BACKEND_ALREADY_HEALTHY" = "1" ]; then
    echo "backend already healthy → http://127.0.0.1:$BLTD_PORT  log: $LOG"
    exit 0
  fi
  nohup /usr/bin/env -i "${RUNTIME_ENV[@]}" \
    "$PY" "$HERE/bltd_api.py" "$BLTD_PORT" >>"$LOG" 2>&1 &
  API_PID=$!
  if ! write_pidfile_atomic "$PIDF" "$API_PID"; then
    kill -TERM "$API_PID" 2>/dev/null || true
    stop_owned_runtime || true
    echo "Black Label Trading: backend pid could not be published safely." >&2
    exit 5
  fi
  for _ in {1..30}; do
    if health_is_ours; then
      rm -f "$PREREQ"
      echo "backend healthy (pid $(cat "$PIDF")) → http://127.0.0.1:$BLTD_PORT  log: $LOG"
      exit 0
    fi
    PID="$(cat "$PIDF" 2>/dev/null || true)"
    valid_pid "$PID" && kill -0 "$PID" 2>/dev/null || break
    sleep 0.2
  done
  stop_owned_pidfile "$PIDF" api backend "$HERE/bltd_api.py" || true
  echo "Black Label Trading: backend failed readiness on 127.0.0.1:$BLTD_PORT; see $LOG" >&2
  exit 5
else
  if [ "$BACKEND_ALREADY_HEALTHY" = "1" ]; then
    echo "backend already healthy → http://127.0.0.1:$BLTD_PORT"
    exit 0
  fi
  PIDF="$SUPPORT/backend.pid"
  /usr/bin/env -i "${RUNTIME_ENV[@]}" \
    "$PY" "$HERE/bltd_api.py" "$BLTD_PORT" &
  API_PID=$!
  if ! write_pidfile_atomic "$PIDF" "$API_PID"; then
    kill -TERM "$API_PID" 2>/dev/null || true
    stop_owned_runtime || true
    echo "Black Label Trading: foreground backend pid could not be published safely." >&2
    exit 5
  fi

  # The API is now independently pidfile-owned. Release the startup lock so a verified
  # --stop-owned request can acquire it; keep this shell only to forward terminal signals and reap
  # the API child.
  release_launcher_lock
  trap - EXIT
  forward_foreground_signal() {
    if valid_pid "$API_PID" &&
       [ "$(cat "$PIDF" 2>/dev/null || true)" = "$API_PID" ]; then
      kill -TERM "$API_PID" 2>/dev/null || true
    fi
  }
  trap forward_foreground_signal HUP INT TERM
  wait "$API_PID"
  API_STATUS=$?
  trap - HUP INT TERM
  remove_pidfile_if_same "$PIDF" "$API_PID"
  exit "$API_STATUS"
fi
