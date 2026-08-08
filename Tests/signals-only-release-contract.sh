#!/bin/bash
# Permanent b27 boundary: every assembled buyer artifact is signals/research only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
SHIPPING_BACKEND=(
  bltd_alerts.py bltd_analytics.py bltd_api.py bltd_browser.py bltd_capture.py
  bltd_feeds.py bltd_optimizer.py bltd_optimizer_cli.py bltd_parsers.py
  bltd_paths.py bltd_store.py bltd_topstep_bridge.py
)
FORBIDDEN_ROUTES=(
  "/api/exec/"
  "/api/Order/place"
  "/api/Position/closeContract"
)
FORBIDDEN_UI_PHRASES=(
  "Go LIVE"
  "arm the Execution engine"
  "Optional autonomous order execution"
  "autonomous execution"
  "live execution"
)

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

ok() {
  PASS=$((PASS + 1))
}

absent_literal() {
  local file="$1" literal="$2"
  if grep -F "$literal" "$file" >/dev/null 2>&1; then
    fail "$file contains forbidden release literal: $literal"
  fi
  ok
}

present_literal() {
  local file="$1" literal="$2"
  grep -F "$literal" "$file" >/dev/null 2>&1 ||
    fail "$file is missing required b27 release guard: $literal"
  ok
}

absent_swift_phrase() {
  local phrase="$1" file
  for file in "$ROOT"/Sources/*.swift; do
    [ -f "$file" ] || continue
    if grep -iF "$phrase" "$file" >/dev/null 2>&1; then
      fail "$file contains execution UI copy forbidden from b27: $phrase"
    fi
  done
  ok
}

shell_allowlist() {
  awk '
    /^[[:space:]]*BACKEND_RUNTIME=\(/ { inside=1; next }
    inside && /^[[:space:]]*\)/ { exit }
    inside { for (i=1; i<=NF; i++) print $i }
  ' "$1" | paste -sd ' ' -
}

windows_allowlist() {
  sed -n '/\$RuntimeModules = @(/,/^[[:space:]]*)/p' "$1" |
    grep -oE '"bltd_[a-z_]+\.py"' |
    tr -d '"' |
    paste -sd ' ' -
}

shell_python_wrapper() {
  awk '
    !inside && /cat > .*\/python3.*<<'\''PYSH'\''/ { inside=1; next }
    inside && $0 == "PYSH" { exit }
    inside { print }
  ' "$1"
}

project_python_wrapper() {
  awk '
    !inside && /cat > .*\/python3.*<<'\''PYSH'\''/ { inside=1; next }
    inside {
      terminator=$0
      sub(/^[[:space:]]*/, "", terminator)
      if (terminator == "PYSH") exit
      sub(/^          /, "")
      print
    }
  ' "$1"
}

expected_allowlist="${SHIPPING_BACKEND[*]}"

[ ! -f "$ROOT/Sources/Execution.swift" ] ||
  fail "Sources/Execution.swift would be compiled by the release glob"
ok

absent_literal "$ROOT/backend/bltd_capture.py" "import bltd_exec"
absent_literal "$ROOT/backend/bltd_capture.py" "self._execute("
absent_literal "$ROOT/backend/bltd_api.py" '"/api/exec/'
absent_literal "$ROOT/Sources/main.swift" "case execution"
absent_literal "$ROOT/Sources/FeedClient.swift" '"/api/exec/'
absent_literal "$ROOT/build-developer-id.sh" 'cp -f "$ROOT/backend"/bltd_*.py'
absent_literal "$ROOT/build.command" 'cp -f "$ROOT/backend"/bltd_*.py'
present_literal "$ROOT/build.command" \
  'build.command produces an unnotarized artifact and cannot install to /Applications.'
present_literal "$ROOT/build.command" 'awk -v team="$TEAM"'
absent_literal "$ROOT/build.command" 'DEST="/Applications/$APPNAME.app"'
present_literal "$ROOT/.gitignore" "dist/"
tracked_dist="$(git -C "$ROOT" ls-files 'dist/*' 2>/dev/null || true)"
[ -z "$tracked_dist" ] || fail "generated distribution artifacts remain tracked: $tracked_dist"
ok
present_literal "$ROOT/Sources/FeedClient.swift" \
  'obj["runtimeContract"] as? String == "bltd-signals-only-runtime-v1"'
present_literal "$ROOT/Sources/FeedClient.swift" \
  'exactJSONBoolean(capabilities["execution"]) == false'
present_literal "$ROOT/Sources/FeedClient.swift" \
  'exactJSONBoolean(capabilities["optimizerCompute"]) == false'
present_literal "$ROOT/Sources/FeedClient.swift" \
  'CFGetTypeID(number) == CFBooleanGetTypeID()'
present_literal "$ROOT/Sources/FeedClient.swift" \
  '.appendingPathComponent("bltd_api.py")'
present_literal "$ROOT/project.yml" 'RUNTIME_SRC="$SRCROOT/vendor/python-runtime"'
present_literal "$ROOT/project.yml" 'cp -Rf "$RUNTIME_SRC" "$BACKEND/python-runtime"'
present_literal "$ROOT/project.yml" 'cat > "$BACKEND/python3"'
present_literal "$ROOT/project.yml" 'PYTHONPATH="$BACKEND" "$BACKEND/python3"'
present_literal "$ROOT/project.yml" 'for backend_item in "$BACKEND"/*'
present_literal "$ROOT/Tests/run-all.sh" \
  '${SIGNALS_ONLY_ARGS[@]+"${SIGNALS_ONLY_ARGS[@]}"}'
for wrapper_source in "$ROOT/build.command" "$ROOT/build-developer-id.sh" "$ROOT/project.yml"; do
  present_literal "$wrapper_source" "unset PYTHONHOME PYTHONPATH PYTHONSTARTUP PYTHONINSPECT PYTHONUSERBASE"
  present_literal "$wrapper_source" '"PYTHONNOUSERSITE=1"'
  present_literal "$wrapper_source" 'exec /usr/bin/env -i "${RUNTIME_ENV[@]}"'
  present_literal "$wrapper_source" "BLTD_TOKEN_FILE"
  if grep -Eq '^[[:space:]]+BLTD_TOKEN[[:space:]]*$' "$wrapper_source"; then
    fail "$wrapper_source passes the bearer token instead of its 0600 token-file path"
  fi
  ok
done
build_wrapper="$(shell_python_wrapper "$ROOT/build.command")"
devid_wrapper="$(shell_python_wrapper "$ROOT/build-developer-id.sh")"
project_wrapper="$(project_python_wrapper "$ROOT/project.yml")"
[ -n "$build_wrapper" ] || fail "build.command Python wrapper template could not be extracted"
[ "$build_wrapper" = "$devid_wrapper" ] ||
  fail "build.command and build-developer-id.sh Python wrappers drifted"
[ "$build_wrapper" = "$project_wrapper" ] ||
  fail "shell and Xcode Python wrapper templates drifted"
ok

devid_build="$ROOT/build-developer-id.sh"
present_literal "$devid_build" 'BLTD_SUPPORT_DIR="$SUPPORT"'
absent_literal "$devid_build" 'HOME="$TESTROOT'
absent_literal "$devid_build" "pkill -f"
absent_literal "$devid_build" "bltd-supervisor-v2"
present_literal "$devid_build" "bltd-supervisor-v3:"
present_literal "$devid_build" \
  'if [ "$INSTALL" = "1" ] && [ "$SUBMIT" != "1" ]; then'
present_literal "$devid_build" \
  'if [ "$SUBMIT" != "1" ] || [ "$STAPLED_VERIFIED" != "1" ]; then'
present_literal "$devid_build" \
  '"BLTD_OWNED_BACKEND_DIR=$DEST/Contents/Resources/backend"'
present_literal "$devid_build" \
  '/bin/bash "$STAGED_BACKEND/launch-backend.sh" --stop-owned'
present_literal "$devid_build" \
  '! spctl -a -t exec -vv "$DEST"'
present_literal "$devid_build" \
  '! xcrun stapler validate "$DEST"'
present_literal "$devid_build" 'grep -F "($TEAM)"'
present_literal "$devid_build" '[ "$FINAL_TEAM" != "$TEAM" ]'
present_literal "$devid_build" 'quit the running Black Label Trading app before canonical replacement'
present_literal "$devid_build" "STAPLED_VERIFIED=1"
stapler_line="$(grep -n 'xcrun stapler validate ' "$devid_build" | tail -1 | cut -d: -f1)"
stapled_line="$(grep -n '^STAPLED_VERIFIED=1$' "$devid_build" | tail -1 | cut -d: -f1)"
submit_install_line="$(grep -n '^[[:space:]]*install_signed_bundle$' "$devid_build" | tail -1 | cut -d: -f1)"
case "$stapler_line" in ''|*[!0-9]*) fail "stapler validation line could not be proven" ;; esac
case "$stapled_line" in ''|*[!0-9]*) fail "stapling verification line could not be proven" ;; esac
case "$submit_install_line" in ''|*[!0-9]*) fail "submit install line could not be proven" ;; esac
[ "$stapler_line" -lt "$stapled_line" ] ||
  fail "Developer-ID stapled state is set before stapler validation"
[ "$stapled_line" -lt "$submit_install_line" ] ||
  fail "Developer-ID submit-mode install occurs before stapling verification"
ok

stop_install_line="$(grep -nF '"BLTD_OWNED_BACKEND_DIR=$DEST/Contents/Resources/backend"' "$devid_build" | tail -1 | cut -d: -f1)"
move_installed_line="$(grep -nF '[ -d "$DEST" ] && mv "$DEST" "$OLD"' "$devid_build" | tail -1 | cut -d: -f1)"
installed_spctl_line="$(grep -nF '! spctl -a -t exec -vv "$DEST"' "$devid_build" | tail -1 | cut -d: -f1)"
installed_staple_line="$(grep -nF '! xcrun stapler validate "$DEST"' "$devid_build" | tail -1 | cut -d: -f1)"
delete_backup_line="$(grep -nF 'rm -rf "$OLD"' "$devid_build" | tail -1 | cut -d: -f1)"
for line in "$stop_install_line" "$move_installed_line" "$installed_spctl_line" \
            "$installed_staple_line" "$delete_backup_line"; do
  case "$line" in ''|*[!0-9]*) fail "Developer-ID install sequencing could not be proven" ;; esac
done
[ "$stop_install_line" -lt "$move_installed_line" ] ||
  fail "Developer-ID install moves the old app before verified runtime teardown"
[ "$installed_spctl_line" -lt "$delete_backup_line" ] &&
  [ "$installed_staple_line" -lt "$delete_backup_line" ] ||
  fail "Developer-ID install deletes its backup before final Gatekeeper/staple validation"
ok

for module in "${SHIPPING_BACKEND[@]}"; do
  file="$ROOT/backend/$module"
  [ -f "$file" ] || fail "shipping allowlist names missing source module: $module"
  for route in "${FORBIDDEN_ROUTES[@]}"; do
    absent_literal "$file" "$route"
  done
  for phrase in "${FORBIDDEN_UI_PHRASES[@]}"; do
    if grep -iF "$phrase" "$file" >/dev/null 2>&1; then
      fail "$file contains execution copy forbidden from b27: $phrase"
    fi
    ok
  done
done
for route in "${FORBIDDEN_ROUTES[@]}"; do
  absent_literal "$ROOT/backend/launch-backend.sh" "$route"
done
launcher="$ROOT/backend/launch-backend.sh"
absent_literal "$launcher" "pkill"
absent_literal "$launcher" "pgrep"
present_literal "$launcher" '[[ "${1:-}" =~ ^[1-9][0-9]*$ ]]'
present_literal "$launcher" "stop_owned_runtime"
present_literal "$launcher" "bltd-worker-v3:"
present_literal "$launcher" "umask 077"
present_literal "$launcher" 'export PYTHONPATH="$HERE"'
absent_literal "$launcher" '${PYTHONPATH:-}'
present_literal "$launcher" 'nohup /usr/bin/env -i "${RUNTIME_ENV[@]}"'
present_literal "$launcher" "trap shutdown HUP INT TERM EXIT"
present_literal "$launcher" '"BLTD_TOKEN_FILE=$BLTD_TOKEN_FILE"'
absent_literal "$launcher" '"BLTD_TOKEN=$BLTD_TOKEN"'
for phrase in "${FORBIDDEN_UI_PHRASES[@]}"; do
  if grep -iF "$phrase" "$ROOT/backend/launch-backend.sh" >/dev/null 2>&1; then
    fail "$ROOT/backend/launch-backend.sh contains execution copy forbidden from b27: $phrase"
  fi
  ok
done

for phrase in "${FORBIDDEN_UI_PHRASES[@]}"; do
  absent_swift_phrase "$phrase"
done

for script in "$ROOT/build-developer-id.sh" "$ROOT/build.command"; do
  actual_allowlist="$(shell_allowlist "$script")"
  [ "$actual_allowlist" = "$expected_allowlist" ] ||
    fail "$script backend allowlist drifted: $actual_allowlist"
  ok
done

windows_script="$ROOT/windows/build-windows.ps1"
actual_windows_allowlist="$(windows_allowlist "$windows_script")"
[ "$actual_windows_allowlist" = "$expected_allowlist" ] ||
  fail "$windows_script backend allowlist drifted: $actual_windows_allowlist"
ok

APP="${1:-}"
if [ -n "$APP" ]; then
  [ -d "$APP" ] || fail "assembled app not found: $APP"
  BACKEND="$APP/Contents/Resources/backend"
  EXECUTABLE="$APP/Contents/MacOS/Black Label Trading"
  [ -d "$BACKEND" ] || fail "missing bundled backend: $BACKEND"
  [ -f "$EXECUTABLE" ] || fail "missing bundled executable: $EXECUTABLE"
  PYTHON="$BACKEND/python3"
  RUNTIME="$BACKEND/python-runtime"
  [ -x "$PYTHON" ] || fail "missing executable bundled Python wrapper: $PYTHON"
  [ -d "$RUNTIME" ] || fail "missing bundled Python runtime: $RUNTIME"
  ok

  expected_top_level="$(
    printf '%s\n' "${SHIPPING_BACKEND[@]}" \
      launch-backend.sh reference_oos.json python3 python-runtime |
      sort |
      paste -sd ' ' -
  )"
  actual_top_level="$(
    find "$BACKEND" -maxdepth 1 ! -path "$BACKEND" -print |
      sed 's|.*/||' |
      sort |
      paste -sd ' ' -
  )"
  [ "$actual_top_level" = "$expected_top_level" ] ||
    fail "assembled backend top level contains non-runtime files: $actual_top_level"
  ok

  present_literal "$PYTHON" "unset PYTHONHOME PYTHONPATH PYTHONSTARTUP PYTHONINSPECT PYTHONUSERBASE"
  present_literal "$PYTHON" '"PYTHONNOUSERSITE=1"'
  present_literal "$PYTHON" 'exec /usr/bin/env -i "${RUNTIME_ENV[@]}"'
  present_literal "$PYTHON" "BLTD_TOKEN_FILE"
  if grep -Eq '^[[:space:]]+BLTD_TOKEN[[:space:]]*$' "$PYTHON"; then
    fail "assembled wrapper exposes BLTD_TOKEN"
  fi
  ok

  expected_sorted="$(printf '%s\n' "${SHIPPING_BACKEND[@]}" | sort | paste -sd ' ' -)"
  actual_sorted="$(
    find "$BACKEND" -maxdepth 1 -type f -name 'bltd_*.py' -print |
      sed 's|.*/||' |
      sort |
      paste -sd ' ' -
  )"
  [ "$actual_sorted" = "$expected_sorted" ] ||
    fail "assembled backend module set is not the signals-only allowlist: $actual_sorted"
  ok

  for forbidden_module in bltd_exec.py bltd_projectx.py; do
    hit="$(
      find "$BACKEND" -path "$BACKEND/python-runtime" -prune -o \
        \( -type f -o -type l \) -name "$forbidden_module" -print -quit
    )"
    [ -z "$hit" ] || fail "bundle contains execution module: $hit"
    ok
  done

  for route in "${FORBIDDEN_ROUTES[@]}"; do
    for file in "$BACKEND"/*.py "$BACKEND"/*.sh; do
      [ -f "$file" ] || continue
      absent_literal "$file" "$route"
    done
    if LC_ALL=C /usr/bin/strings "$EXECUTABLE" | grep -F "$route" >/dev/null 2>&1; then
      fail "assembled executable contains forbidden execution route: $route"
    fi
    ok
  done

  for phrase in "${FORBIDDEN_UI_PHRASES[@]}"; do
    for file in "$BACKEND"/*.py "$BACKEND"/*.sh; do
      [ -f "$file" ] || continue
      if grep -iF "$phrase" "$file" >/dev/null 2>&1; then
        fail "$file contains execution copy forbidden from b27: $phrase"
      fi
      ok
    done
    if LC_ALL=C /usr/bin/strings "$EXECUTABLE" | grep -iF "$phrase" >/dev/null 2>&1; then
      fail "assembled executable contains execution UI copy forbidden from b27: $phrase"
    fi
    ok
  done

  SMOKE="$(mktemp -d "${TMPDIR:-/tmp}/bltd-runtime-contract.XXXXXX")"
  trap 'rm -rf "$SMOKE"' EXIT
  if ! BLTD_SUPPORT_DIR="$SMOKE/support" BLTD_PYCACHE_ROOT="$SMOKE/pycache" \
    PYTHONPATH="$BACKEND" "$PYTHON" - "$RUNTIME" <<'PY'
import importlib
import os
import secrets
import sqlite3
import ssl
import sys

runtime = os.path.realpath(sys.argv[1])
executable = os.path.realpath(sys.executable)
assert os.path.commonpath((runtime, executable)) == runtime, (runtime, executable)
assert sys.version_info[:2] >= (3, 9), sys.version
for name in (
    "bltd_alerts", "bltd_analytics", "bltd_api", "bltd_browser",
    "bltd_capture", "bltd_feeds", "bltd_optimizer", "bltd_optimizer_cli",
    "bltd_parsers", "bltd_paths", "bltd_store", "bltd_topstep_bridge",
):
    importlib.import_module(name)
PY
  then
    fail "bundled Python runtime/import smoke failed"
  fi
  if find "$BACKEND" \( -type d -name __pycache__ -o -type f -name '*.pyc' \) |
      grep -q .; then
    fail "runtime/import smoke mutated the assembled backend"
  fi
  rm -rf "$SMOKE"
  trap - EXIT
  ok
fi

echo "$PASS passed, 0 failed"
