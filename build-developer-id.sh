#!/bin/bash
# build-developer-id.sh — DEVELOPER ID build of Black Label Trading (ships OUTSIDE the App Store).
#
# Trading spawns its own bundled Python data backend, which the App Store sandbox would forbid, so
# it ships via Developer ID + Hardened Runtime (NOT app-sandbox). This script produces a
# hardened-runtime bundle, signs it with a "Developer ID Application" identity when one is in the
# keychain, and otherwise falls back to an ad-hoc signature (same hardened runtime + entitlements)
# so the bundle is still launch-verifiable headlessly. Notarization is a separate human step that
# needs Michael's Apple ID in notarytool (see the end of this script).
#
#   ./build-developer-id.sh                 # build + sign (Developer ID if available, else adhoc)
#   ./build-developer-id.sh --no-submit     # explicit default: no Apple contact
#   ./build-developer-id.sh --submit        # notarize + staple (requires Michael approval)
#   ./build-developer-id.sh --submit --install  # notarize, staple, verify, then install
#   ./build-developer-id.sh --launch-test   # build, sign, launch, prove backend up, then quit
#
# Signals-only runtime. Ships NO data, broker-order adapter, or credentials — the SQLite
# store is created empty at runtime; broker creds live in the buyer's Keychain only.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
# shellcheck source=scripts/production-install-guard.sh
source "$ROOT/scripts/production-install-guard.sh"
SRC="$ROOT/Sources"
BUILD="$ROOT/build"
APPNAME="Black Label Trading"
APP="$BUILD/$APPNAME.app"
ZIP="$BUILD/Black-Label-Trading-DeveloperID.zip"
BIN_NAME="Black Label Trading"
BUNDLE_ID="com.blacklabel.trading"
TEAM="745ZPGFRA5"
ENTS="$SRC/app-developerid.entitlements"
NOTARY_PROFILE="${NOTARY_PROFILE:-BL_NOTARY}"
BUILD_NUMBER="${BUILD_NUMBER:-27}"
PY_RUNTIME_SRC="$ROOT/vendor/python-runtime"
SUBMIT="${SUBMIT:-0}"
INSTALL=0
LAUNCH_TEST=0
STAPLED_VERIFIED=0

for arg in "$@"; do
  case "$arg" in
    --submit) SUBMIT=1 ;;
    --no-submit|--build-only) SUBMIT=0 ;;
    --install) INSTALL=1 ;;
    --launch-test) LAUNCH_TEST=1 ;;
    -h|--help)
      echo "Usage: $0 [--submit|--no-submit|--build-only] [--install] [--launch-test]"
      echo "  default: build + sign + verify only (no Apple contact)"
      echo "  --submit: also notarize + staple (requires Michael's approval)"
      echo "  --install: atomically install after notarization (requires --submit)"
      exit 0 ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 [--submit|--no-submit|--build-only] [--install] [--launch-test]" >&2
      exit 2 ;;
  esac
done

if [ "$INSTALL" = "1" ] && [ "$SUBMIT" != "1" ]; then
  echo "FAIL: --install requires --submit; canonical installs must be notarized and stapled first" >&2
  exit 64
fi

[ -f "$ENTS" ] || { echo "FAIL: missing $ENTS" >&2; exit 1; }

echo "==> Signals-only release contract (source preflight)"
bash "$ROOT/Tests/signals-only-release-contract.sh"

# --- resolve a signing identity: prefer a real Developer ID Application cert ---------------------
# Developer ID is the correct identity for out-of-store distribution + notarization. If none is in
# the keychain (the common headless case), fall back to ad-hoc ("-") so the bundle still builds +
# launches; the report flags Developer ID + notarization as the remaining human step.
SIGN_MODE="adhoc"
IDENTITY="-"
DEVID_LINE="$(
  security find-identity -v -p codesigning 2>/dev/null |
    grep 'Developer ID Application' |
    grep -F "($TEAM)" |
    head -n 1 || true
)"
if [ -n "$DEVID_LINE" ]; then
  IDENTITY="$(echo "$DEVID_LINE" | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-F]+).*/\1/')"
  SIGN_MODE="developerid"
fi
echo "==> Signing mode: $SIGN_MODE  (identity: $IDENTITY)"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
echo "==> SDK: $SDK"

# --- clean skeleton ---
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# --- compile universal2 (arm64 + x86_64 -> lipo). Trading now ships a TRUE universal2 app: the Swift
# binary AND the bundled CPython runtime (vendor/python-runtime) are both universal2, so it runs
# natively on Apple Silicon AND Intel. (2026-07-01: arm64-only binary + arm64-only vendored Python
# locked Intel buyers out; vendored a lipo-merged universal2 CPython 3.11.15 from the free
# python-build-standalone project, so the whole app is universal.) ---
echo "==> Compiling Sources/*.swift (universal2: arm64 + x86_64)"
SWIFT_FILES=( "$SRC"/*.swift )
TRD_FRAMEWORKS=( -framework SwiftUI -framework AppKit -framework Charts
  -framework AuthenticationServices -framework CryptoKit -framework UserNotifications )
build_trd_arch () {
  local arch="$1"
  echo "==> Compiling ${arch} (deployment target macOS 13.0)"
  xcrun --sdk macosx swiftc \
    -O -sdk "$SDK" -target "${arch}-apple-macosx13.0" \
    "${TRD_FRAMEWORKS[@]}" \
    -o "$BUILD/$BIN_NAME-${arch}" \
    "${SWIFT_FILES[@]}"
}
build_trd_arch arm64
build_trd_arch x86_64
echo "==> lipo -> universal"
lipo -create "$BUILD/$BIN_NAME-arm64" "$BUILD/$BIN_NAME-x86_64" -output "$APP/Contents/MacOS/$BIN_NAME"
rm -f "$BUILD/$BIN_NAME-arm64" "$BUILD/$BIN_NAME-x86_64"
lipo -archs "$APP/Contents/MacOS/$BIN_NAME"

# --- Info.plist ---
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>Black Label Trading</string>
  <key>CFBundleExecutable</key><string>$BIN_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Black Label Trading</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>ITSAppUsesNonExemptEncryption</key><false/>
  <key>LSApplicationCategoryType</key><string>public.app-category.finance</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Black Label. All rights reserved.</string>
  <key>CFBundleURLTypes</key>
  <array><dict><key>CFBundleURLSchemes</key><array><string>$BUNDLE_ID</string></array></dict></array>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

# --- privacy manifest (REQUIRED, accurate: no tracking, no collection, UserDefaults reason) ---
[ -f "$SRC/PrivacyInfo.xcprivacy" ] || { echo "FAIL: missing $SRC/PrivacyInfo.xcprivacy" >&2; exit 1; }
cp -f "$SRC/PrivacyInfo.xcprivacy" "$APP/Contents/Resources/PrivacyInfo.xcprivacy"

# --- compile source-controlled assets (never inherit bytes from /Applications) ---
ASSET_CATALOG="$SRC/Assets.xcassets"
[ -d "$ASSET_CATALOG" ] || { echo "FAIL: missing source asset catalog: $ASSET_CATALOG" >&2; exit 1; }
xcrun actool "$ASSET_CATALOG" \
  --compile "$APP/Contents/Resources" \
  --platform macosx \
  --minimum-deployment-target 13.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$BUILD/asset-info.plist"
[ -f "$APP/Contents/Resources/AppIcon.icns" ] || { echo "FAIL: actool did not emit AppIcon.icns" >&2; exit 1; }
[ -f "$APP/Contents/Resources/Assets.car" ] || { echo "FAIL: actool did not emit Assets.car" >&2; exit 1; }

# --- bundle the SELF-CONTAINED backend (code only, ships NO data) ---
echo "==> Bundling self-contained backend (code only, no data)"
mkdir -p "$APP/Contents/Resources/backend"
BACKEND_RUNTIME=(
  bltd_alerts.py bltd_analytics.py bltd_api.py bltd_browser.py bltd_capture.py
  bltd_feeds.py bltd_optimizer.py bltd_optimizer_cli.py bltd_parsers.py
  bltd_paths.py bltd_store.py bltd_topstep_bridge.py
)
for module in "${BACKEND_RUNTIME[@]}"; do
  [ -f "$ROOT/backend/$module" ] || { echo "FAIL: missing backend runtime module $module" >&2; exit 1; }
  cp -f "$ROOT/backend/$module" "$APP/Contents/Resources/backend/"
done
cp -f "$ROOT/backend/launch-backend.sh" "$APP/Contents/Resources/backend/"
chmod +x "$APP/Contents/Resources/backend/launch-backend.sh"
# Reference OOS verdicts — Black Label's edge-gate result on OUR OWN historical ES bars (research,
# NOT buyer data), served read-only at /api/reference so a cold buyer sees a real earned verdict.
# The build-time generator gen_reference.py is deliberately NOT shipped.
[ -f "$ROOT/backend/reference_oos.json" ] && cp -f "$ROOT/backend/reference_oos.json" "$APP/Contents/Resources/backend/"

echo "==> Bundling CPython runtime (fresh Mac: no Terminal/dev-tools prerequisite)"
if [ ! -x "$PY_RUNTIME_SRC/bin/python3.11" ] && [ ! -x "$PY_RUNTIME_SRC/bin/python3" ]; then
  echo "FAIL: missing bundled Python runtime at $PY_RUNTIME_SRC" >&2
  echo "      Populate the source-controlled vendor/python-runtime release input." >&2
  exit 1
fi
rm -rf "$APP/Contents/Resources/backend/python-runtime"
cp -Rf "$PY_RUNTIME_SRC" "$APP/Contents/Resources/backend/python-runtime"
find "$APP/Contents/Resources/backend" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$APP/Contents/Resources/backend" -type f -name '*.pyc' -delete
if find "$APP/Contents/Resources/backend" -type f \( -name 'bltd_exec.py' -o -name 'bltd_projectx.py' \) | grep -q .; then
  echo "FAIL: broker-order code entered the signals-only bundle" >&2
  exit 1
fi
cat > "$APP/Contents/Resources/backend/python3" <<'PYSH'
#!/bin/bash
set -euo pipefail
umask 077

DIR="$(cd "$(dirname "$0")" && pwd -P)"
RUNTIME_HOME="${HOME:-/var/empty}"
case "$RUNTIME_HOME" in
  /*) ;;
  *) RUNTIME_HOME="/var/empty" ;;
esac
CACHE_INPUT="${PYTHONPYCACHEPREFIX:-${BLTD_PYCACHE_ROOT:-$RUNTIME_HOME/Library/Caches/Black Label Trading/python}}"

unset PYTHONHOME PYTHONPATH PYTHONSTARTUP PYTHONINSPECT PYTHONUSERBASE
unset BASH_ENV ENV
unset DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH
unset DYLD_FALLBACK_LIBRARY_PATH DYLD_FALLBACK_FRAMEWORK_PATH

canonicalize_cache_path() {
  local probe="${1%/}" suffix="" component
  [ -n "$probe" ] || probe="/"
  while [ ! -e "$probe" ]; do
    [ "$probe" != "/" ] || return 1
    component="${probe##*/}"
    probe="${probe%/*}"
    [ -n "$probe" ] || probe="/"
    suffix="/$component$suffix"
  done
  [ -d "$probe" ] || return 1
  probe="$(cd "$probe" && pwd -P)" || return 1
  while [ -n "$suffix" ]; do
    suffix="${suffix#/}"
    component="${suffix%%/*}"
    if [ "$suffix" = "$component" ]; then
      suffix=""
    else
      suffix="${suffix#*/}"
    fi
    case "$component" in
      ""|.) ;;
      ..)
        if [ "$probe" != "/" ]; then
          probe="${probe%/*}"
          [ -n "$probe" ] || probe="/"
        fi
        ;;
      *)
        if [ "$probe" = "/" ]; then
          probe="/$component"
        else
          probe="$probe/$component"
        fi
        ;;
    esac
  done
  printf '%s\n' "$probe"
}

case "$CACHE_INPUT" in
  /*) ;;
  *)
    echo "Black Label Trading: PYTHONPYCACHEPREFIX must be an absolute path." >&2
    exit 78
    ;;
esac
PYTHON_CACHE="$(canonicalize_cache_path "$CACHE_INPUT")" || {
  echo "Black Label Trading: invalid PYTHONPYCACHEPREFIX." >&2
  exit 78
}
case "$PYTHON_CACHE" in
  "$DIR"|"$DIR"/*)
    echo "Black Label Trading: Python cache must be outside the bundled backend." >&2
    exit 78
    ;;
esac
/bin/mkdir -p "$PYTHON_CACHE"
PYTHON_CACHE="$(cd "$PYTHON_CACHE" && pwd -P)"
case "$PYTHON_CACHE" in
  "$DIR"|"$DIR"/*)
    echo "Black Label Trading: Python cache resolved inside the bundled backend." >&2
    exit 78
    ;;
esac

if [ -x "$DIR/python-runtime/bin/python3.11" ]; then
  PYTHON_BIN="$DIR/python-runtime/bin/python3.11"
elif [ -x "$DIR/python-runtime/bin/python3" ]; then
  PYTHON_BIN="$DIR/python-runtime/bin/python3"
else
  echo "Black Label Trading: bundled Python runtime is missing." >&2
  exit 127
fi

RUNTIME_ENV=(
  "HOME=$RUNTIME_HOME"
  "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
  "LANG=C"
  "LC_ALL=C"
  "PYTHONPATH=$DIR"
  "PYTHONUNBUFFERED=1"
  "PYTHONDONTWRITEBYTECODE=1"
  "PYTHONNOUSERSITE=1"
  "PYTHONPYCACHEPREFIX=$PYTHON_CACHE"
)
BLTD_ALLOWLIST=(
  BLTD_SUPPORT_DIR
  BLTD_STORE
  BLTD_CONFIG
  BLTD_PORT
  BLTD_SCOPE
  BLTD_BUILD
  BLTD_RUNTIME_CONTRACT
  BLTD_TOKEN_FILE
  BLTD_WEBHOOK_URL
  BLTD_CAPTURE_BROWSER
  BLTD_AUTO_BROWSER
  BLTD_CAPTURE_ENGINES
  BLTD_CDP_PORT
  BLTD_BAR_SECONDS
  BLTD_LOOKBACK
  BLTD_EDGE_GATE
  BLTD_STALL_SECONDS
  BLTD_TOPSTEP_OPEN_DEBOUNCE_SECONDS
)
for name in "${BLTD_ALLOWLIST[@]}"; do
  if [ "${!name+x}" = "x" ]; then
    RUNTIME_ENV+=("$name=${!name}")
  fi
done

exec /usr/bin/env -i "${RUNTIME_ENV[@]}" "$PYTHON_BIN" "$@"
PYSH
chmod +x "$APP/Contents/Resources/backend/python3"
BLTD_PYCACHE_ROOT="$BUILD/python-cache-test" \
  "$APP/Contents/Resources/backend/python3" - <<'PY'
import secrets, sqlite3, ssl, sys
raise SystemExit(0 if sys.version_info[:2] >= (3, 9) else 1)
PY

find "$APP" \( -name '._*' -o -name '.__*' \) -delete
if find "$APP/Contents/Resources/backend" \( -type d -name __pycache__ -o -type f -name '*.pyc' \) | grep -q .; then
  echo "FAIL: mutable Python cache found inside release bundle" >&2
  exit 1
fi

# Zero-data guard: fail loudly if any database/data file slipped into the bundle.
STRAY="$(find "$APP" -type f \( -name '*.sqlite3' -o -name '*.db' -o -name '*.sqlite' -o -name 'bars_log.csv' -o -name 'fires*.json' \) 2>/dev/null || true)"
if [ -n "$STRAY" ]; then echo "FAIL: data files in bundle (must ship EMPTY):" >&2; echo "$STRAY" >&2; exit 1; fi

echo "==> Signals-only release contract (assembled artifact)"
bash "$ROOT/Tests/signals-only-release-contract.sh" "$APP"

# --- sign with HARDENED RUNTIME + Developer ID entitlements (NO app-sandbox, NO applesignin) ----
# --deep signs the nested launcher script's resources too. --options runtime = hardened runtime,
# required for notarization. --timestamp is used for a Developer ID identity (notary needs a secure
# timestamp); ad-hoc skips it.
# Sign every nested Mach-O in the bundled Python runtime FIRST (inside-out). Apple's `--deep` does
# NOT reliably reach a bundled interpreter's many binaries (bin/python3.11 + hundreds of .so/.dylib),
# and notarization REJECTS any unsigned nested code (2026-07-01: a freshly lipo'd universal2 CPython
# was unsigned -> "The binary is not signed"). Each leaf gets hardened runtime + the same entitlements
# (disable-library-validation lets python3.11 load the .so set).
if [ "$SIGN_MODE" = "developerid" ]; then
  SIGN_ID="$IDENTITY"; TS_FLAG="--timestamp"
else
  SIGN_ID="-"; TS_FLAG="--timestamp=none"
fi
RT="$APP/Contents/Resources/backend/python-runtime"
if [ -d "$RT" ]; then
  echo "==> Signing bundled python-runtime Mach-O (inside-out)"
  # shellcheck disable=SC2038
  find "$RT" -type f \( -name '*.so' -o -name '*.dylib' -o -name 'python3*' \) -print0 \
    | while IFS= read -r -d '' f; do
        if file "$f" | grep -q 'Mach-O'; then
          codesign --force --options runtime $TS_FLAG --entitlements "$ENTS" --sign "$SIGN_ID" "$f" 2>/dev/null \
            || { echo "FAIL: could not sign runtime binary $f" >&2; exit 1; }
        fi
      done
fi

echo "==> Signing (hardened runtime, Developer-ID entitlements)"
if [ "$SIGN_MODE" = "developerid" ]; then
  codesign --force --deep --options runtime --timestamp \
    --entitlements "$ENTS" --sign "$IDENTITY" "$APP"
else
  codesign --force --deep --options runtime --timestamp=none \
    --entitlements "$ENTS" --sign - "$APP"
fi

# --- verify ---
echo "==> codesign --verify --deep --strict"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "==> Entitlements on the signed bundle:"
codesign -d --entitlements - "$APP" 2>/dev/null | sed 's/^/    /' || true

echo "==> Packaging Developer-ID zip for notary submission"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "==> Notary submission zip: $ZIP"

# Assert the forbidden entitlements are ABSENT and the hardened-runtime exceptions are PRESENT.
ENTDUMP="$(codesign -d --entitlements - "$APP" 2>/dev/null || true)"
echo "$ENTDUMP" | grep -q 'app-sandbox'  && { echo "FAIL: app-sandbox must NOT be present for the Developer-ID backend-spawn build" >&2; exit 1; } || true
echo "$ENTDUMP" | grep -q 'applesignin' && { echo "FAIL: applesignin must NOT be present (AMFI SIGKILL without a profile)" >&2; exit 1; } || true
echo "$ENTDUMP" | grep -q 'disable-library-validation' || { echo "FAIL: disable-library-validation missing (python backend won't load its libs)" >&2; exit 1; }
# b25: assert on the SIGNED bytes, not just the source plist — this dump is the only surface that
# shows what codesign actually embedded. Paired with disable-library-validation above, granting this
# would re-enable DYLD_INSERT_LIBRARIES injection of unsigned dylibs into a notarized process.
echo "$ENTDUMP" | grep -q 'allow-dyld-environment-variables' && { echo "FAIL: allow-dyld-environment-variables must NOT be present (nothing sets DYLD_*; it would re-open dylib injection)" >&2; exit 1; } || true

# --- Gatekeeper assessment (informational for adhoc; real verdict needs notarization) ----
echo "==> spctl -a -t exec assessment:"
spctl -a -t exec -vv "$APP" 2>&1 | sed 's/^/    /' || true

install_signed_bundle() {
  if [ "$SUBMIT" != "1" ] || [ "$STAPLED_VERIFIED" != "1" ]; then
    echo "FAIL: canonical install is forbidden until notarization and stapling verify" >&2
    return 66
  fi
  production_install_guard "$INSTALL" "$APP"
  local DEST="/Applications/$APPNAME.app"
  local STAGE="$DEST.staging.$$"
  local OLD="$DEST.old.$$"
  echo "==> Staging atomic install at $STAGE"
  rm -rf "$STAGE" "$OLD"
  cp -Rf "$APP" "$STAGE"
  codesign --verify --deep --strict "$STAGE"
  [ -f "$STAGE/Contents/Info.plist" ] || { echo "FAIL: staged bundle has no Info.plist" >&2; rm -rf "$STAGE"; exit 1; }
  [ -d "$STAGE/Contents/Resources/backend/python-runtime" ] || { echo "FAIL: staged bundle has no Python runtime" >&2; rm -rf "$STAGE"; exit 1; }
  local INSTALL_SUPPORT="$HOME/Library/Application Support/Black Label Trading"
  local STAGED_BACKEND="$STAGE/Contents/Resources/backend"
  local INSTALLED_GUI="$DEST/Contents/MacOS/$BIN_NAME"
  if [ -x "$INSTALLED_GUI" ] &&
     ps -axo command= | awk -v executable="$INSTALLED_GUI" '
       $0 == executable || index($0, executable " ") == 1 { found=1 }
       END { exit(found ? 0 : 1) }
     '; then
    rm -rf "$STAGE"
    echo "FAIL: quit the running Black Label Trading app before canonical replacement" >&2
    return 68
  fi
  echo "==> Stopping only verified installed Trading runtime processes"
  if ! /usr/bin/env \
      "BLTD_SUPPORT_DIR=$INSTALL_SUPPORT" \
      "BLTD_PYTHON=$STAGED_BACKEND/python3" \
      "BLTD_BUILD=$BUILD_NUMBER" \
      "BLTD_PORT=8793" \
      "BLTD_OWNED_BACKEND_DIR=$DEST/Contents/Resources/backend" \
      /bin/bash "$STAGED_BACKEND/launch-backend.sh" --stop-owned; then
    rm -rf "$STAGE"
    echo "FAIL: verified installed Trading runtime could not be stopped; old app left untouched" >&2
    return 67
  fi
  [ -d "$DEST" ] && mv "$DEST" "$OLD"
  if ! mv "$STAGE" "$DEST"; then
    [ -d "$OLD" ] && mv "$OLD" "$DEST"
    echo "FAIL: atomic install rename failed; previous app restored" >&2
    exit 1
  fi
  local FINAL_PLIST="$DEST/Contents/Info.plist"
  local FINAL_TEAM
  FINAL_TEAM="$(codesign -dv --verbose=4 "$DEST" 2>&1 |
    awk -F= '$1 == "TeamIdentifier" { print $2; exit }' || true)"
  if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$FINAL_PLIST" 2>/dev/null || true)" != "$BUNDLE_ID" ] ||
     [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$FINAL_PLIST" 2>/dev/null || true)" != "$APPNAME" ] ||
     [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$FINAL_PLIST" 2>/dev/null || true)" != "$BIN_NAME" ] ||
     [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$FINAL_PLIST" 2>/dev/null || true)" != "$BUILD_NUMBER" ] ||
     [ "$FINAL_TEAM" != "$TEAM" ] ||
     [ ! -x "$DEST/Contents/MacOS/$BIN_NAME" ] ||
     ! codesign --verify --deep --strict --all-architectures "$DEST" ||
     ! spctl -a -t exec -vv "$DEST" ||
     ! xcrun stapler validate "$DEST"; then
    rm -rf "$DEST"
    [ -d "$OLD" ] && mv "$OLD" "$DEST"
    echo "FAIL: installed bundle failed codesign/Gatekeeper/staple verification; previous app restored" >&2
    exit 1
  fi
  rm -rf "$OLD"
  echo "==> Installed: $DEST"
}

if [ "$LAUNCH_TEST" = "1" ]; then
  echo "==> Launch test: starting the bundled backend exactly as the app does"
  LAUNCH="$APP/Contents/Resources/backend/launch-backend.sh"
  TESTROOT="$(mktemp -d)"
  SUPPORT="$TESTROOT/support"
  TMPSTORE="$SUPPORT/trading.sqlite3"
  BACKEND_DIR="$APP/Contents/Resources/backend"
  mkdir -p "$SUPPORT"
  PORT="$("$APP/Contents/Resources/backend/python3" - <<'PY'
import socket
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    print(s.getsockname()[1])
PY
)"

  launch_test_command() {
    ps -ww -p "$1" -o command= 2>/dev/null || true
  }
  launch_test_pid_is_owned() {
    local kind="$1" name="$2" script="$3" cmd="$4"
    [[ "$cmd" == *"$BACKEND_DIR/"* ]] || return 1
    # The fresh, isolated support directory can only contain pidfiles from this launch. The API
    # additionally proves the exact random test port in argv; every worker proves the exact bundle
    # script (and each supervisor proves its v3 build/name marker).
    case "$kind" in
      api)
        [[ "$cmd" == *"$BACKEND_DIR/$script $PORT"* ]]
        ;;
      supervisor)
        [[ "$cmd" == *"bltd-supervisor-v3:$BUILD_NUMBER:$name"* &&
           "$cmd" == *"$BACKEND_DIR/$script"* ]]
        ;;
      child)
        [[ "$cmd" == *"$BACKEND_DIR/$script"* &&
           "$cmd" == *"bltd-worker-v3:$BUILD_NUMBER:$name"* &&
           "$cmd" == *python* &&
           "$cmd" != *"bltd-supervisor"* ]]
        ;;
      *) return 1 ;;
    esac
  }
  stop_launch_test_pid() {
    local pidfile="$1" kind="$2" name="$3" script="$4"
    local pid cmd current
    [ -f "$pidfile" ] || return 0
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    case "$pid" in ''|0|*[!0-9]*) return 0 ;; esac
    cmd="$(launch_test_command "$pid")"
    launch_test_pid_is_owned "$kind" "$name" "$script" "$cmd" || return 0
    kill "$pid" 2>/dev/null || return 0
    for _ in $(seq 1 20); do
      kill -0 "$pid" 2>/dev/null || return 0
      sleep 0.1
    done
    # Re-read the live command before a force kill so PID reuse can never widen the target.
    current="$(launch_test_command "$pid")"
    if launch_test_pid_is_owned "$kind" "$name" "$script" "$current"; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  }
  LAUNCH_TEST_CLEANED=0
  cleanup_launch_test() {
    [ "$LAUNCH_TEST_CLEANED" = "0" ] || return 0
    LAUNCH_TEST_CLEANED=1
    # Stop supervisors before their children so they cannot restart a child during teardown.
    stop_launch_test_pid "$SUPPORT/capture-supervisor.pid" \
      supervisor capture bltd_capture.py
    stop_launch_test_pid "$SUPPORT/topstep-bridge-supervisor.pid" \
      supervisor topstep-bridge bltd_topstep_bridge.py
    stop_launch_test_pid "$SUPPORT/capture.pid" child capture bltd_capture.py
    stop_launch_test_pid "$SUPPORT/topstep-bridge.pid" \
      child topstep-bridge bltd_topstep_bridge.py
    stop_launch_test_pid "$SUPPORT/backend.pid" api backend bltd_api.py
    rm -rf "$TESTROOT"
  }
  trap cleanup_launch_test EXIT

  if ! BLTD_SUPPORT_DIR="$SUPPORT" \
    BLTD_PYCACHE_ROOT="$TESTROOT/pycache" \
    BLTD_PORT="$PORT" \
    BLTD_BUILD="$BUILD_NUMBER" \
    BLTD_STORE="$TMPSTORE" \
    BLTD_CONFIG="$SUPPORT/config.json" \
    /bin/bash "$LAUNCH" --bg >"$TESTROOT/launch.log" 2>&1; then
    echo "FAIL: bundled launcher returned non-zero: $(tail -n 1 "$TESTROOT/launch.log")" >&2
    exit 1
  fi
  ok=""; body=""
  for i in $(seq 1 25); do
    body="$(curl -fsS "http://127.0.0.1:$PORT/health" 2>/dev/null || true)"
    if "$APP/Contents/Resources/backend/python3" -c '
import json, os, sys
try:
    d = json.loads(sys.argv[1])
    c = d.get("capabilities") or {}
    good = (d.get("ok") is True
            and d.get("service") == "black-label-trading"
            and str(d.get("build")) == sys.argv[2]
            and d.get("runtimeContract") == "bltd-signals-only-runtime-v1"
            and os.path.realpath(str(d.get("backendScript") or "")) == os.path.realpath(sys.argv[3])
            and c.get("signals") is True and c.get("execution") is False
            and c.get("optimizerCompute") is False)
except Exception:
    good = False
raise SystemExit(0 if good else 1)
' "$body" "$BUILD_NUMBER" "$BACKEND_DIR/bltd_api.py"; then
      ok="yes"; break
    fi
    sleep 0.4
  done
  if [ -z "$ok" ]; then echo "FAIL: bundled backend did not come up on :$PORT" >&2; exit 1; fi
  echo "==> BACKEND UP: /health -> $body"
  # Self-contained guard: must serve its OWN store, never Utah's Postgres.
  echo "$body" | grep -q '"store": "own"' || echo "$body" | grep -q '"store":"own"' \
    || { echo "FAIL: backend is not using its OWN store ($body)" >&2; exit 1; }
  echo "==> SELF-CONTAINED OK: backend serves its own empty SQLite store (not Utah)"
  cleanup_launch_test
  trap - EXIT
fi

if [ "$SUBMIT" != "1" ]; then
  echo ""
  echo "==> BUILD-ONLY MODE: build + sign + verify complete. No Apple contact made."
  echo "    Signed app: $APP"
  echo "    Distributable zip: $ZIP"
  echo "    To notarize (requires Michael's explicit approval), re-run with: $0 --submit"
  echo ""
  echo "==> DONE — Developer-ID bundle: $APP"
  echo "    Signing mode: $SIGN_MODE"
  if [ "$SIGN_MODE" != "developerid" ]; then
    echo ""
    echo "    HUMAN STEP REMAINING (Michael only): a 'Developer ID Application' cert is not in the"
    echo "    keychain, so this run signed ad-hoc. To produce a notarized, distributable build:"
    echo "      1) In Xcode > Settings > Accounts, sign in with the Apple ID on team $TEAM and"
    echo "         create/download a 'Developer ID Application' certificate."
    echo "      2) Re-run this script (it will auto-pick the Developer ID identity)."
  fi
  exit 0
fi

if [ "$SIGN_MODE" != "developerid" ]; then
  echo "FAIL: --submit requires a Developer ID Application identity, but signing mode is $SIGN_MODE" >&2
  exit 1
fi

echo "==> SUBMIT MODE: contacting Apple notary service for $APP"

# --- Toolchain guard (read-only; contacts no Apple service) --------------------
# Leads build 18 was rejected (INVALID_BINARY) because it was packaged on this
# macOS 27 beta host with the Xcode 26.6 (17F113) beta toolchain — the same beta
# host that package.sh already refuses for every release build (App Store AND
# Developer-ID, via appstore_select_xcode). Apply that shared guard before the
# outward-facing Apple notary submission. Override with ALLOW_BETA_TOOLCHAIN=1.
_tc_guard="$HOME/BlackLabel-Submission/appstore_toolchain_guard.sh"
if [ -f "$_tc_guard" ]; then
  _tcg_err="/tmp/bl_tc_guard.$$"
  if ( source "$_tc_guard"; appstore_select_xcode ) 2>"$_tcg_err"; then
    echo "✓ Build host toolchain accepted (no macOS 27 beta / Xcode 17F113 markers)."
  else
    cat "$_tcg_err" >&2
    echo "✗ BETA-TOOLCHAIN HOST: this macOS/Xcode is the beta toolchain Apple rejected" >&2
    echo "  for Leads build 18 (INVALID_BINARY). Notarize from an Apple-accepted release" >&2
    echo "  macOS/Xcode host, or set ALLOW_BETA_TOOLCHAIN=1 to override on purpose." >&2
    rm -f "$_tcg_err"
    [ "${ALLOW_BETA_TOOLCHAIN:-0}" = "1" ] || exit 1
    echo "  ALLOW_BETA_TOOLCHAIN=1 set — proceeding on beta toolchain on purpose." >&2
  fi
  rm -f "$_tcg_err"
else
  echo "! Shared toolchain guard not found at $_tc_guard — cannot verify host toolchain." >&2
fi
# --- end toolchain guard ------------------------------------------------------

xcrun notarytool submit "$ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait
xcrun stapler staple "$APP"
spctl -a -t exec -vv "$APP"

echo "==> Repackaging stapled distributable zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
_verify_extract="$(mktemp -d)"
ditto -x -k "$ZIP" "$_verify_extract"
spctl -a -t exec -vv "$_verify_extract/$APPNAME.app"
xcrun stapler validate "$_verify_extract/$APPNAME.app"
rm -rf "$_verify_extract"
STAPLED_VERIFIED=1

if [ "$INSTALL" = "1" ]; then
  install_signed_bundle
fi

echo ""
echo "==> DONE — Developer-ID bundle: $APP"
echo "    Signing mode: $SIGN_MODE"
echo "    Stapled distributable zip: $ZIP"
