#!/bin/bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/scripts/production-install-guard.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bltd-install-guard.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { /usr/bin/grep -Fq "$2" "$1" || fail "$1 missing: $2"; }
[[ -f "$HELPER" ]] || fail "missing repo-owned production install guard"
# shellcheck source=/dev/null
source "$HELPER"

APP="$WORK/Trading.app"
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
contains "$ROOT/build.command" 'build.command produces an unnotarized artifact and cannot install to /Applications.'
if /usr/bin/grep -Fq 'DEST="/Applications/$APPNAME.app"' "$ROOT/build.command"; then
  fail "unnotarized build.command still contains a canonical install lane"
fi
contains "$ROOT/build-developer-id.sh" 'production_install_guard "$INSTALL" "$APP"'
if /usr/bin/grep -Fq 'DEST="/Applications/$APPNAME.app"' "$ROOT/build-signed.command"; then
  fail "Apple Development build still targets canonical production app"
fi

expect_blocked_install() {
  local expected="$1" label="$2"
  shift 2
  set +e
  /bin/bash "$@" >"$WORK/$label.out" 2>&1
  local rc=$?
  set -e
  [[ "$rc" -eq "$expected" ]] ||
    fail "$label returned $rc, expected fail-closed $expected"
}
expect_blocked_install 64 build-command "$ROOT/build.command" --devid --install
expect_blocked_install 64 developer-id "$ROOT/build-developer-id.sh" --no-submit --install

echo "production install guard contract PASS"
