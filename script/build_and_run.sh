#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Black Label Trading"
BUNDLE_ID="com.blacklabel.trading"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/build/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

usage() {
  echo "usage: $0 [run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify]" >&2
}

stop_existing() {
  pkill -f "$APP_BINARY" >/dev/null 2>&1 || true
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
}

build_app() {
  "$ROOT_DIR/build.command"
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

verify_process() {
  local attempt
  for attempt in {1..20}; do
    if pgrep -f "$APP_BINARY" >/dev/null 2>&1; then
      echo "==> Verified running: $APP_NAME"
      return 0
    fi
    sleep 0.5
  done
  echo "ERROR: $APP_NAME did not appear as a running process" >&2
  return 1
}

stop_existing
build_app

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    verify_process
    ;;
  *)
    usage
    exit 2
    ;;
esac
