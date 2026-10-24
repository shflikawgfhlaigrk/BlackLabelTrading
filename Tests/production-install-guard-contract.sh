#!/bin/bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/scripts/production-install-guard.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { /usr/bin/grep -Fq "$2" "$1" || fail "$1 missing: $2"; }
[[ -f "$HELPER" ]] || fail "missing repo-owned production install guard"
# shellcheck source=/dev/null
source "$HELPER"

APP="$(mktemp -d)/Trading.app"
mkdir -p "$APP"
codesign() { printf '%s\n' "$FAKE_CODESIGN" >&2; }
expect_rc() {
  local expected="$1" release="$2" signature="$3" rc
  FAKE_CODESIGN="$signature"
  production_install_guard "$release" "$APP" >/dev/null 2>&1
  rc=$?
  [[ "$rc" -eq "$expected" ]] || fail "guard rc=$rc, expected $expected"
}
expect_rc 64 0 'Signature=adhoc'
expect_rc 65 1 'Signature=adhoc'
expect_rc 65 1 'Authority=Apple Development: Example'
expect_rc 0 1 'Authority=Developer ID Application: Example (TEAM)'
contains "$ROOT/build.command" 'production_install_guard "$DEVID" "$APP"'
contains "$ROOT/build-developer-id.sh" 'production_install_guard "$INSTALL" "$APP"'
if /usr/bin/grep -Fq 'DEST="/Applications/$APPNAME.app"' "$ROOT/build-signed.command"; then
  fail "Apple Development build still targets canonical production app"
fi

echo "production install guard contract PASS"
