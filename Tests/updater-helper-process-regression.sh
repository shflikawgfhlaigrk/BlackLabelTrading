#!/bin/bash
# Execute the exact detached helper embedded in UpdaterUI.swift. A staged launcher that cannot stop
# the verified old runtime must abort before either app bundle is moved.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bltd-updater-stop.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

INSTALLED="$WORK/Installed Black Label Trading.app"
STAGED="$WORK/Staged Black Label Trading.app"
BACKUP="$WORK/update-backup.app"
SUPPORT="$WORK/Application Support/Black Label Trading"
HELPER="$WORK/update-helper.sh"
INSTALLED_BACKEND="$INSTALLED/Contents/Resources/backend"
STAGED_BACKEND="$STAGED/Contents/Resources/backend"

mkdir -p "$INSTALLED_BACKEND" "$STAGED_BACKEND" "$SUPPORT"
printf '%s\n' old-app >"$INSTALLED/old-app-sentinel"
printf '%s\n' staged-app >"$STAGED/staged-app-sentinel"

awk '
  /^[[:space:]]*let script = """$/ { inside=1; next }
  inside && /^        """$/ { exit }
  inside { sub(/^        /, ""); print }
' "$ROOT/Sources/UpdaterUI.swift" >"$HELPER"
chmod 700 "$HELPER"

cat >"$STAGED_BACKEND/python3" <<'PY'
#!/bin/bash
exit 0
PY
chmod 700 "$STAGED_BACKEND/python3"

cat >"$STAGED_BACKEND/launch-backend.sh" <<'LAUNCH'
#!/bin/bash
HERE="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "${1:-}" >"$HERE/called-mode"
printf '%s\n' "${BLTD_SUPPORT_DIR:-}" >"$HERE/called-support"
printf '%s\n' "${BLTD_OWNED_BACKEND_DIR:-}" >"$HERE/called-installed-backend"
exit 6
LAUNCH
chmod 700 "$STAGED_BACKEND/launch-backend.sh"

set +e
/bin/sh "$HELPER" \
  999999 \
  "$INSTALLED" \
  "$STAGED" \
  "$BACKUP" \
  com.blacklabel.trading \
  "Black Label Trading" \
  27 \
  745ZPGFRA5 \
  "Black Label Trading" \
  "$SUPPORT" \
  bundled \
  8793 >/dev/null 2>&1
rc=$?
set -e

[ "$rc" -eq 1 ] || { echo "FAIL: helper returned $rc, expected fail-closed exit 1" >&2; exit 1; }
[ -f "$INSTALLED/old-app-sentinel" ] ||
  { echo "FAIL: installed app moved despite teardown failure" >&2; exit 1; }
[ -f "$STAGED/staged-app-sentinel" ] ||
  { echo "FAIL: staged app moved despite teardown failure" >&2; exit 1; }
[ ! -e "$BACKUP" ] ||
  { echo "FAIL: backup was created before teardown succeeded" >&2; exit 1; }
[ "$(cat "$STAGED_BACKEND/called-mode")" = "--stop-owned" ] ||
  { echo "FAIL: helper did not invoke the verified stop mode" >&2; exit 1; }
[ "$(cat "$STAGED_BACKEND/called-support")" = "$SUPPORT" ] ||
  { echo "FAIL: helper did not pass exact Application Support" >&2; exit 1; }
[ "$(cat "$STAGED_BACKEND/called-installed-backend")" = "$INSTALLED_BACKEND" ] ||
  { echo "FAIL: helper did not pin the exact installed backend" >&2; exit 1; }

echo "Updater helper teardown-failure regression PASS"
