#!/bin/bash
# Exercise the exact updater helper control flow with only fixed macOS assessment/launch tools
# redirected to deterministic local stubs. Both an early GUI exit and a stable GUI with no exact
# backend health acknowledgement must restore the previous bundle automatically.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bltd-updater-rollback.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

TOOLS="$WORK/tools"
SUPPORT="$WORK/Application Support/Black Label Trading"
MODE_FILE="$WORK/open-mode"
QUIT_FILE="$WORK/quit"
OPEN_LOG="$WORK/open.log"
LAUNCH_LOG="$WORK/launcher.log"
GUI_PID_FILE="$WORK/gui.pid"
mkdir -p "$TOOLS" "$SUPPORT"

cat >"$TOOLS/codesign" <<'SH'
#!/bin/bash
case " $* " in
  *" --display "*)
    printf '%s\n' "TeamIdentifier=745ZPGFRA5" >&2
    ;;
esac
exit 0
SH

cat >"$TOOLS/spctl" <<'SH'
#!/bin/bash
printf '%s\n' "source=Notarized Developer ID" >&2
exit 0
SH

cat >"$TOOLS/stapler" <<'SH'
#!/bin/bash
exit 0
SH

cat >"$TOOLS/xattr" <<'SH'
#!/bin/bash
exit 0
SH

cat >"$TOOLS/osascript" <<SH
#!/bin/bash
/usr/bin/touch "$QUIT_FILE"
exit 0
SH

cat >"$TOOLS/open" <<SH
#!/bin/bash
if [ "\${1:-}" = "-n" ] && [ "\${2:-}" = "-W" ]; then
  mode="\$(/bin/cat "$MODE_FILE")"
  printf '%s\n' "new:\$mode" >>"$OPEN_LOG"
  last=""
  for argument in "\$@"; do last="\$argument"; done
  if [ "\$mode" = "crash" ]; then
    /bin/sleep 0.2
    exit 7
  fi
  if [ "\$mode" = "stubborn-gui" ]; then
    "\$last/Contents/MacOS/Black Label Trading" 120 &
    gui_pid=\$!
    printf '%s\n' "\$gui_pid" >"$GUI_PID_FILE"
    wait "\$gui_pid"
    exit \$?
  fi
  while [ ! -e "$QUIT_FILE" ]; do /bin/sleep 0.1; done
  exit 0
fi
last=""
for argument in "\$@"; do last="\$argument"; done
if [ -f "\$last/old-app-sentinel" ]; then
  printf '%s\n' "rollback-opened-old" >>"$OPEN_LOG"
fi
exit 0
SH
chmod 700 "$TOOLS"/*

write_app() {
  local app="$1" kind="$2"
  local backend="$app/Contents/Resources/backend"
  mkdir -p "$app/Contents/MacOS" "$backend"
  cat >"$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.blacklabel.trading</string>
  <key>CFBundleDisplayName</key><string>Black Label Trading</string>
  <key>CFBundleName</key><string>Black Label Trading</string>
  <key>CFBundleExecutable</key><string>Black Label Trading</string>
  <key>CFBundleVersion</key><string>27</string>
</dict></plist>
PLIST
  printf '%s\n' "$kind" >"$app/$kind-app-sentinel"
  cat >"$app/Contents/MacOS/Black Label Trading" <<'SH'
#!/bin/bash
exit 0
SH
  cat >"$backend/python3" <<'SH'
#!/bin/bash
# Write the helper's recovery marker, but fail its later bundled-health probe.
if [ "${1:-}" = "-" ]; then
  case "${2:-}" in
    *.tmp.*)
      printf '{"version":1,"helperPID":%s,"watchdogPID":%s,"statePath":"%s","backupPath":"%s","expectedBuild":%s,"backendMode":"%s","backendPort":%s}\n' \
        "$4" "$6" "$7" "$3" "$5" "$8" "$9" >"$2"
      chmod 600 "$2"
      exit 0
      ;;
  esac
fi
if [ "$(/bin/cat "__MODE_FILE__")" = "bundled-healthy" ]; then
  exit 0
fi
exit 1
SH
  /usr/bin/sed -i '' "s#__MODE_FILE__#$MODE_FILE#g" "$backend/python3"
  cat >"$backend/launch-backend.sh" <<SH
#!/bin/bash
printf '%s\n' "\${1:-}" >>"$LAUNCH_LOG"
exit 0
SH
  chmod 700 "$app/Contents/MacOS/Black Label Trading" \
    "$backend/python3" "$backend/launch-backend.sh"
}

run_case() {
  local mode="$1"
  local case_root="$WORK/$mode"
  local installed="$case_root/Black Label Trading.app"
  local staged="$case_root/staged/Black Label Trading.app"
  local backup="$case_root/Black Label Trading.app.update-backup-test"
  local helper="$case_root/update-helper.sh"
  local backend_mode="bundled"
  local backend_port="9000"
  local expected="rollback"
  if [ "$mode" = "remote" ]; then
    backend_mode="external"
    backend_port="0"
    expected="success"
  elif [ "$mode" = "bundled-healthy" ]; then
    expected="success"
  elif [ "$mode" = "killed-helper" ]; then
    expected="watchdog"
  elif [ "$mode" = "stubborn-gui" ]; then
    expected="retained"
  fi

  mkdir -p "$(dirname "$staged")"
  write_app "$installed" old
  write_app "$staged" staged
  if [ "$mode" = "stubborn-gui" ]; then
    cat >"$case_root/stubborn-gui.c" <<'C'
#include <unistd.h>
int main(void) { sleep(120); return 0; }
C
    /usr/bin/clang "$case_root/stubborn-gui.c" \
      -o "$staged/Contents/MacOS/Black Label Trading"
  fi
  printf '%s\n' "$mode" >"$MODE_FILE"
  rm -f "$QUIT_FILE" "$OPEN_LOG" "$LAUNCH_LOG" "$GUI_PID_FILE" \
    "$SUPPORT/update-backup.pending"

  awk '
    /^[[:space:]]*let script = """$/ { inside=1; next }
    inside && /^        """$/ { exit }
    inside { sub(/^        /, ""); print }
  ' "$ROOT/Sources/UpdaterUI.swift" >"$helper"
  chmod 700 "$helper"
  /bin/sh -n "$helper"

  # The production helper keeps fixed system paths and a 30-second window. Redirect only those
  # external seams and shorten only the wait for this executable regression.
  /usr/bin/sed -i '' \
    -e "s#/usr/bin/codesign#$TOOLS/codesign#g" \
    -e "s#/usr/sbin/spctl#$TOOLS/spctl#g" \
    -e "s#/usr/bin/stapler#$TOOLS/stapler#g" \
    -e "s#/usr/bin/xattr#$TOOLS/xattr#g" \
    -e "s#/usr/bin/osascript#$TOOLS/osascript#g" \
    -e "s#/usr/bin/open#$TOOLS/open#g" \
    -e 's/stable_seconds=30/stable_seconds=2/' \
    "$helper"
  /bin/sh -n "$helper"

  helper_command=(
    "$helper"
    999999 \
    "$installed" \
    "$staged" \
    "$backup" \
    com.blacklabel.trading \
    "Black Label Trading" \
    27 \
    745ZPGFRA5 \
    "Black Label Trading" \
    "$SUPPORT" \
    "$backend_mode" \
    "$backend_port"
  )
  local rc
  if [ "$expected" = "watchdog" ] || [ "$expected" = "retained" ]; then
    /bin/sh "${helper_command[@]}" >/dev/null 2>&1 &
    local helper_pid=$!
    local ready=0
    for _ in $(seq 1 80); do
      if [ -f "$installed/staged-app-sentinel" ] &&
         [ -f "$SUPPORT/update-backup.pending" ]; then
        if [ "$mode" = "stubborn-gui" ] && [ ! -f "$GUI_PID_FILE" ]; then
          /bin/sleep 0.05
          continue
        fi
        ready=1
        break
      fi
      /bin/sleep 0.05
    done
    [ "$ready" -eq 1 ] ||
      { echo "FAIL: watchdog fixture never reached post-swap state" >&2; exit 1; }
    /bin/kill -KILL "$helper_pid"
    set +e
    wait "$helper_pid" 2>/dev/null
    rc=$?
    set -e
    if [ "$expected" = "watchdog" ]; then
      for _ in $(seq 1 100); do
        [ -f "$installed/old-app-sentinel" ] &&
          [ ! -e "$SUPPORT/update-backup.pending" ] && break
        /bin/sleep 0.1
      done
    else
      local transaction_watchdog
      transaction_watchdog="$(
        /usr/bin/sed -E 's/.*"watchdogPID":([0-9]+).*/\1/' \
          "$SUPPORT/update-backup.pending"
      )"
      for _ in $(seq 1 100); do
        /bin/kill -0 "$transaction_watchdog" 2>/dev/null || break
        /bin/sleep 0.1
      done
    fi
  else
    set +e
    /bin/sh "${helper_command[@]}" >/dev/null 2>&1
    rc=$?
    set -e
  fi

  if [ "$expected" = "rollback" ] || [ "$expected" = "watchdog" ]; then
    if [ "$expected" = "rollback" ]; then
      [ "$rc" -eq 1 ] ||
      {
        echo "FAIL: $mode helper returned $rc instead of rollback exit 1" >&2
        /usr/bin/tail -n 40 "$SUPPORT/update-helper.log" >&2 || true
        exit 1
      }
    else
      [ "$rc" -ge 128 ] ||
        { echo "FAIL: killed helper did not terminate by signal (rc=$rc)" >&2; exit 1; }
    fi
    [ -f "$installed/old-app-sentinel" ] ||
      { echo "FAIL: $mode did not restore the previous bundle" >&2; exit 1; }
    [ ! -e "$installed/staged-app-sentinel" ] ||
      { echo "FAIL: $mode left the failed staged bundle installed" >&2; exit 1; }
    grep -Fqx "rollback-opened-old" "$OPEN_LOG" ||
      { echo "FAIL: $mode did not reopen the restored app" >&2; exit 1; }
  elif [ "$expected" = "success" ]; then
    [ "$rc" -eq 0 ] ||
      { echo "FAIL: $mode helper returned $rc instead of success" >&2; exit 1; }
    [ -f "$installed/staged-app-sentinel" ] ||
      { echo "FAIL: $mode incorrectly restored the previous bundle" >&2; exit 1; }
    [ ! -e "$installed/old-app-sentinel" ] ||
      { echo "FAIL: $mode retained the replaced bundle" >&2; exit 1; }
    if [ "$mode" = "remote" ]; then
      ! grep -Fqx -- "--bg" "$LAUNCH_LOG" ||
        { echo "FAIL: remote mode started the bundled backend" >&2; exit 1; }
    else
      grep -Fqx -- "--bg" "$LAUNCH_LOG" ||
        { echo "FAIL: signed-out bundled mode did not start its backend" >&2; exit 1; }
    fi
  else
    [ "$rc" -ge 128 ] ||
      { echo "FAIL: stubborn-GUI helper did not terminate by signal (rc=$rc)" >&2; exit 1; }
    [ -f "$installed/staged-app-sentinel" ] ||
      { echo "FAIL: watchdog replaced a still-running installed GUI" >&2; exit 1; }
    [ -d "$backup" ] ||
      { echo "FAIL: watchdog discarded rollback backup while GUI was live" >&2; exit 1; }
    [ -f "$SUPPORT/update-backup.pending" ] ||
      { echo "FAIL: watchdog cleared recovery marker while GUI was live" >&2; exit 1; }
    state_path="$(
      /usr/bin/sed -E 's/.*"statePath":"([^"]+)".*/\1/' \
        "$SUPPORT/update-backup.pending"
    )"
    [ "$(/bin/cat "$state_path")" = "pending" ] ||
      { echo "FAIL: stubborn-GUI transaction was incorrectly committed" >&2; exit 1; }
    gui_pid="$(/bin/cat "$GUI_PID_FILE")"
    gui_command="$(/bin/ps -ww -p "$gui_pid" -o command= 2>/dev/null || true)"
    case "$gui_command" in
      "$installed/Contents/MacOS/Black Label Trading"*)
        /bin/kill -TERM "$gui_pid" 2>/dev/null || true
        ;;
      *) echo "FAIL: stubborn-GUI fixture lost exact process identity" >&2; exit 1 ;;
    esac
    return
  fi
  [ ! -e "$backup" ] ||
    { echo "FAIL: $mode left a rollback backup after its terminal decision" >&2; exit 1; }
  [ ! -e "$SUPPORT/update-backup.pending" ] ||
    { echo "FAIL: $mode left its recovery marker after its terminal decision" >&2; exit 1; }
}

run_case crash
run_case no-health
run_case killed-helper
run_case stubborn-gui
run_case bundled-healthy
run_case remote
echo "Updater helper crash/health rollback regression PASS"
