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
#   ./build-developer-id.sh --install       # also install to /Applications
#   ./build-developer-id.sh --launch-test   # build, sign, launch, prove backend up, then quit
#
# Optional autonomous execution (default OFF, paper-first). Ships NO data and NO creds — the SQLite
# store is created empty at runtime; broker creds live in the buyer's Keychain only.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
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
BUILD_NUMBER="${BUILD_NUMBER:-16}"
PY_RUNTIME_SRC="${BLTD_PYTHON_RUNTIME:-$ROOT/vendor/python-runtime}"
SUBMIT="${SUBMIT:-0}"
INSTALL=0
LAUNCH_TEST=0

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
      exit 0 ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 [--submit|--no-submit|--build-only] [--install] [--launch-test]" >&2
      exit 2 ;;
  esac
done

[ -f "$ENTS" ] || { echo "FAIL: missing $ENTS" >&2; exit 1; }

# --- resolve a signing identity: prefer a real Developer ID Application cert ---------------------
# Developer ID is the correct identity for out-of-store distribution + notarization. If none is in
# the keychain (the common headless case), fall back to ad-hoc ("-") so the bundle still builds +
# launches; the report flags Developer ID + notarization as the remaining human step.
SIGN_MODE="adhoc"
IDENTITY="-"
DEVID_LINE="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 'Developer ID Application' || true)"
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
  -framework AuthenticationServices -framework CryptoKit -framework UserNotifications -framework LocalAuthentication )
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

# --- reuse installed icon/assets/fonts if present ---
for res in AppIcon.icns Assets.car; do
  [ -f "/Applications/$APPNAME.app/Contents/Resources/$res" ] && cp -f "/Applications/$APPNAME.app/Contents/Resources/$res" "$APP/Contents/Resources/" || true
done
[ -d "/Applications/$APPNAME.app/Contents/Resources/Fonts" ] && cp -Rf "/Applications/$APPNAME.app/Contents/Resources/Fonts" "$APP/Contents/Resources/" || true

# --- bundle the SELF-CONTAINED backend (code only, ships NO data) ---
echo "==> Bundling self-contained backend (code only, no data)"
mkdir -p "$APP/Contents/Resources/backend"
cp -f "$ROOT/backend"/bltd_*.py "$APP/Contents/Resources/backend/"
cp -f "$ROOT/backend/launch-backend.sh" "$APP/Contents/Resources/backend/"
chmod +x "$APP/Contents/Resources/backend/launch-backend.sh"
# Reference OOS verdicts — Black Label's edge-gate result on OUR OWN historical ES bars (research,
# NOT buyer data), served read-only at /api/reference so a cold buyer sees a real earned verdict.
# The build-time generator gen_reference.py is deliberately NOT shipped.
[ -f "$ROOT/backend/reference_oos.json" ] && cp -f "$ROOT/backend/reference_oos.json" "$APP/Contents/Resources/backend/"

echo "==> Bundling CPython runtime (fresh Mac: no Terminal/dev-tools prerequisite)"
if [ ! -x "$PY_RUNTIME_SRC/bin/python3.11" ] && [ ! -x "$PY_RUNTIME_SRC/bin/python3" ]; then
  echo "FAIL: missing bundled Python runtime at $PY_RUNTIME_SRC" >&2
  echo "      Set BLTD_PYTHON_RUNTIME=/path/to/python-runtime or populate vendor/python-runtime." >&2
  exit 1
fi
rm -rf "$APP/Contents/Resources/backend/python-runtime"
cp -Rf "$PY_RUNTIME_SRC" "$APP/Contents/Resources/backend/python-runtime"
cat > "$APP/Contents/Resources/backend/python3" <<'PYSH'
#!/bin/bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -x "$DIR/python-runtime/bin/python3.11" ]; then
  exec "$DIR/python-runtime/bin/python3.11" "$@"
fi
exec "$DIR/python-runtime/bin/python3" "$@"
PYSH
chmod +x "$APP/Contents/Resources/backend/python3"
"$APP/Contents/Resources/backend/python3" - <<'PY'
import secrets, sqlite3, ssl, sys
raise SystemExit(0 if sys.version_info[:2] >= (3, 9) else 1)
PY

find "$APP" \( -name '._*' -o -name '.__*' \) -delete

# Zero-data guard: fail loudly if any database/data file slipped into the bundle.
STRAY="$(find "$APP" -type f \( -name '*.sqlite3' -o -name '*.db' -o -name '*.sqlite' -o -name 'bars_log.csv' -o -name 'fires*.json' \) 2>/dev/null || true)"
if [ -n "$STRAY" ]; then echo "FAIL: data files in bundle (must ship EMPTY):" >&2; echo "$STRAY" >&2; exit 1; fi

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

# --- Gatekeeper assessment (informational for adhoc; real verdict needs notarization) ----
echo "==> spctl -a -t exec assessment:"
spctl -a -t exec -vv "$APP" 2>&1 | sed 's/^/    /' || true

if [ "$INSTALL" = "1" ]; then
  DEST="/Applications/$APPNAME.app"
  echo "==> Installing to $DEST"
  rm -rf "$DEST"; cp -Rf "$APP" "$DEST"
  if [ "$SIGN_MODE" = "developerid" ]; then
    codesign --force --deep --options runtime --timestamp --entitlements "$ENTS" --sign "$IDENTITY" "$DEST"
  else
    codesign --force --deep --options runtime --timestamp=none --entitlements "$ENTS" --sign - "$DEST"
  fi
  echo "==> Installed: $DEST"
fi

if [ "$LAUNCH_TEST" = "1" ]; then
  echo "==> Launch test: starting the bundled backend exactly as the app does"
  LAUNCH="$APP/Contents/Resources/backend/launch-backend.sh"
  PORT=8793   # spare port so we never collide with a running install on 8787
  TMPSTORE="$(mktemp -d)/trading.sqlite3"
  BLTD_PORT="$PORT" BLTD_STORE="$TMPSTORE" /bin/bash "$LAUNCH" --bg >/dev/null 2>&1 || true
  ok=""; body=""
  for i in $(seq 1 25); do
    body="$(curl -fsS "http://127.0.0.1:$PORT/health" 2>/dev/null || true)"
    if [ -n "$body" ]; then ok="yes"; break; fi
    sleep 0.4
  done
  # tear down the test backend
  pkill -f "bltd_api.py $PORT" 2>/dev/null || true
  if [ -z "$ok" ]; then echo "FAIL: bundled backend did not come up on :$PORT" >&2; exit 1; fi
  echo "==> BACKEND UP: /health -> $body"
  # Self-contained guard: must serve its OWN store, never Utah's Postgres.
  echo "$body" | grep -q '"store": "own"' || echo "$body" | grep -q '"store":"own"' \
    || { echo "FAIL: backend is not using its OWN store ($body)" >&2; exit 1; }
  echo "==> SELF-CONTAINED OK: backend serves its own empty SQLite store (not Utah)"
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

echo ""
echo "==> DONE — Developer-ID bundle: $APP"
echo "    Signing mode: $SIGN_MODE"
echo "    Stapled distributable zip: $ZIP"
