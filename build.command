#!/bin/bash
# Reproducible build for Black Label Trading (no Xcode project / no XcodeGen required).
# Compiles Sources/*.swift with swiftc into a signed .app bundle.
#
#   ./build.command            -> builds into ./build/Black Label Trading.app
#   ./build.command --devid       -> unnotarized Developer-ID artifact for validation/notary input
#
# Signals-only product. Ships NO data. Entitlements applied at sign time.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
SRC="$ROOT/Sources"
BUILD="$ROOT/build"
APPNAME="Black Label Trading"
APP="$BUILD/$APPNAME.app"
BIN_NAME="Black Label Trading"
BUNDLE_ID="com.blacklabel.trading"
TEAM="745ZPGFRA5"

# --- mode flags --------------------------------------------------------------
# --devid   : sign Developer-ID + hardened runtime + NON-sandbox entitlements (app-developerid.entitlements
#             — network.client + disable-library-validation) — notarization-ready, and the ONLY build the in-app updater can
#             self-replace (the sandbox forbids self-replace). The adhoc default path is unchanged.
# --install : intentionally rejected here; canonical installs require notarization + stapling through
#             build-developer-id.sh --submit --install.
DEVID=0; INSTALL=0
for a in "$@"; do case "$a" in --devid) DEVID=1;; --install) INSTALL=1;; esac; done
if [ "$INSTALL" = "1" ]; then
  echo "ABORT: build.command produces an unnotarized artifact and cannot install to /Applications." >&2
  echo "       Use ./build-developer-id.sh --submit --install after Apple notarization." >&2
  exit 64
fi

echo "==> Signals-only release contract (source preflight)"
bash "$ROOT/Tests/signals-only-release-contract.sh"

# DEVID and ADHOC both sign with the HARDENED, non-sandbox Developer-ID entitlements
# (network.client + disable-library-validation). The bundled Python backend loads unsigned
# .so extensions, so library validation MUST be disabled on BOTH paths or the backend fails
# to start. The near-namesake app-devid.entitlements is an EMPTY <dict> and must NOT be used
# here — Tests/devid-entitlements-contract.sh guards this pointer. (See CHARTER §5.9 / memory
# "trading-two-entitlements-files-devid-is-an-empty-dict".)
DEVID_ENTITLEMENTS="$SRC/app-developerid.entitlements"
ADHOC_ENTITLEMENTS="$SRC/app-developerid.entitlements"
DEVID_IDENTITY=""
if [ "$DEVID" = "1" ]; then
  # Resolve the first VALID Developer ID Application identity by HASH (avoids the "ambiguous —
  # matches N identities" error when more than one valid cert is in the keychain).
  DEVID_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null |
      awk -v team="$TEAM" '/Developer ID Application/ && index($0, "(" team ")") { print $2; exit }' ||
      true
  )"
  if [ -z "$DEVID_IDENTITY" ]; then
    echo "ABORT: --devid requested but no team $TEAM Developer ID Application identity is in the keychain."; exit 1
  fi
  [ -f "$DEVID_ENTITLEMENTS" ] || { echo "ABORT: missing $DEVID_ENTITLEMENTS"; exit 1; }
fi

# Sign a bundle per mode: Dev-ID (hardened runtime + non-sandbox + secure timestamp, notarization-
# ready) or adhoc (the Developer-ID entitlements the bundled Python backend needs — the convenience
# local build). DEFAULT (no --devid) is byte-for-byte the prior adhoc behavior.
sign_bundle() {
  local target="$1"
  if [ "$DEVID" = "1" ]; then
    codesign --force --deep --options runtime --timestamp \
      --entitlements "$DEVID_ENTITLEMENTS" -s "$DEVID_IDENTITY" "$target"
  else
    codesign --force --deep --sign - --entitlements "$ADHOC_ENTITLEMENTS" "$target"
  fi
}

SDK="$(xcrun --sdk macosx --show-sdk-path)"
echo "==> SDK: $SDK"
echo "==> swiftc: $(xcrun --sdk macosx -f swiftc)"

# --- clean app skeleton ---
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# --- compile all Swift sources into one universal executable ---
echo "==> Compiling Sources/*.swift (universal2: arm64 + x86_64)"
SWIFT_FILES=( "$SRC"/*.swift )
TRD_FRAMEWORKS=( -framework SwiftUI -framework AppKit -framework Charts
  -framework AuthenticationServices -framework CryptoKit -framework Security )
build_trd_arch () {
  local arch="$1"
  echo "==> Compiling ${arch} (deployment target macOS 13.0)"
  xcrun --sdk macosx swiftc \
    -O \
    -sdk "$SDK" \
    -target "${arch}-apple-macosx13.0" \
    "${TRD_FRAMEWORKS[@]}" \
    -o "$BUILD/$BIN_NAME-${arch}" \
    "${SWIFT_FILES[@]}"
}
build_trd_arch arm64
build_trd_arch x86_64
echo "==> lipo -> universal"
lipo -create "$BUILD/$BIN_NAME-arm64" "$BUILD/$BIN_NAME-x86_64" -output "$APP/Contents/MacOS/$BIN_NAME"
rm -f "$BUILD/$BIN_NAME-arm64" "$BUILD/$BIN_NAME-x86_64"
echo "==> Linked executable: $APP/Contents/MacOS/$BIN_NAME (lipo -archs: $(lipo -archs "$APP/Contents/MacOS/$BIN_NAME"))"

# --- TR-10 PERMANENT zero-claims linter (⛔H1 mechanism) ----------------------
# Fail the build if any fabricated win-rate / P&L / return / track-record claim is present in the
# shipped source surface OR the freshly-linked binary. This is the standing mechanism that keeps a
# fabricated number from ever reaching a buyer through the app (CHARTER §5.1 / §5.7); the same
# linter runs in Tests/run-all.sh. Scans the compiled binary that will actually ship.
echo "==> Zero-claims linter (source surface + fresh binary)"
if ! python3 "$ROOT/backend/claim_linter.py" --binary "$APP/Contents/MacOS/$BIN_NAME"; then
  echo "ABORT: claim_linter found a forbidden performance claim — build fails (§5.1/§5.7)." >&2
  exit 65
fi

# --- Info.plist (includes GoogleClientID key, default empty; URL scheme; finance category) ---
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
  <key>CFBundleVersion</key><string>28</string>
  <key>GoogleClientID</key><string></string>
  <key>ITSAppUsesNonExemptEncryption</key><false/>
  <key>LSApplicationCategoryType</key><string>public.app-category.finance</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Black Label. All rights reserved.</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict><key>CFBundleURLSchemes</key><array><string>$BUNDLE_ID</string></array></dict>
  </array>
</dict>
</plist>
PLIST

# --- compile source-controlled assets (never inherit bytes from /Applications) ---
ASSET_CATALOG="$SRC/Assets.xcassets"
[ -d "$ASSET_CATALOG" ] || { echo "ABORT: missing source asset catalog: $ASSET_CATALOG" >&2; exit 1; }
xcrun actool "$ASSET_CATALOG" \
  --compile "$APP/Contents/Resources" \
  --platform macosx \
  --minimum-deployment-target 13.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$BUILD/asset-info.plist"
[ -f "$APP/Contents/Resources/AppIcon.icns" ] || { echo "ABORT: actool did not emit AppIcon.icns" >&2; exit 1; }
[ -f "$APP/Contents/Resources/Assets.car" ] || { echo "ABORT: actool did not emit Assets.car" >&2; exit 1; }
printf 'APPL????' > "$APP/Contents/PkgInfo"

# --- privacy manifest (REQUIRED, accurate: no tracking, no collection, UserDefaults reason) ---
[ -f "$SRC/PrivacyInfo.xcprivacy" ] && cp -f "$SRC/PrivacyInfo.xcprivacy" "$APP/Contents/Resources/PrivacyInfo.xcprivacy"

# --- bundle the SELF-CONTAINED data backend (stdlib-only Python; ships NO data) ---
# The buyer's app starts its bundled browser bridge and receives THEIR OWN feed into THEIR OWN
# local SQLite store over /webhook/feed. These are code only — the store is created empty at runtime.
if [ -d "$ROOT/backend" ]; then
  echo "==> Bundling self-contained backend (code only, no data)"
  mkdir -p "$APP/Contents/Resources/backend"
  BACKEND_RUNTIME=(
    bltd_alerts.py bltd_analytics.py bltd_api.py bltd_browser.py bltd_capture.py
    bltd_feeds.py bltd_optimizer.py bltd_optimizer_cli.py bltd_parsers.py
    bltd_paths.py bltd_store.py bltd_topstep_bridge.py
  )
  for module in "${BACKEND_RUNTIME[@]}"; do
    [ -f "$ROOT/backend/$module" ] || { echo "ABORT: missing backend runtime module $module" >&2; exit 1; }
    cp -f "$ROOT/backend/$module" "$APP/Contents/Resources/backend/"
  done
  cp -f "$ROOT/backend/launch-backend.sh" "$APP/Contents/Resources/backend/"
  chmod +x "$APP/Contents/Resources/backend/launch-backend.sh"
  # Reference OOS verdicts: Black Label's edge-gate result on OUR OWN historical ES bars (research,
  # not buyer data) so a cold buyer sees a real earned verdict at /api/reference. NOT the buyer's
  # account, NOT a promise. gen_reference.py (the build-time generator) is deliberately NOT shipped.
  [ -f "$ROOT/backend/reference_oos.json" ] && cp -f "$ROOT/backend/reference_oos.json" "$APP/Contents/Resources/backend/"

  RUNTIME_SRC="$ROOT/vendor/python-runtime"
  if [ ! -x "$RUNTIME_SRC/bin/python3.11" ] && [ ! -x "$RUNTIME_SRC/bin/python3" ]; then
    echo "ABORT: missing source-controlled backend runtime at $RUNTIME_SRC" >&2
    exit 1
  fi

  echo "==> Bundling source-controlled backend runtime"
  rm -rf "$APP/Contents/Resources/backend/python-runtime"
  cp -Rf "$RUNTIME_SRC" "$APP/Contents/Resources/backend/python-runtime"
  # Precompiled caches are mutable interpreter state, not release inputs. The wrapper below writes
  # any future cache outside the signed app.
  find "$APP/Contents/Resources/backend" -type d -name __pycache__ -prune -exec rm -rf {} +
  find "$APP/Contents/Resources/backend" -type f -name '*.pyc' -delete
  if find "$APP/Contents/Resources/backend" -type f \( -name 'bltd_exec.py' -o -name 'bltd_projectx.py' \) | grep -q .; then
    echo "ABORT: broker-order code entered the signals-only bundle" >&2
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
  if find "$APP/Contents/Resources/backend" \( -type d -name __pycache__ -o -type f -name '*.pyc' \) | grep -q .; then
    echo "ABORT: mutable Python cache found inside release bundle" >&2
    exit 1
  fi
fi

echo "==> Signals-only release contract (assembled artifact)"
bash "$ROOT/Tests/signals-only-release-contract.sh" "$APP"

# --- adhoc sign with the DEVELOPER-ID entitlements (NO app-sandbox, NO applesignin) ---
# Trading spawns its bundled Python backend, which the App Store sandbox would forbid — so even
# this convenience build uses the Developer-ID entitlements (network.client + the hardened-runtime
# library/dyld exceptions the python backend needs). It deliberately does NOT carry app-sandbox or
# the restricted applesignin entitlement (AMFI SIGKILLs an ad-hoc app that carries applesignin).
# The Apple button is runtime-gated on the entitlement, so this build hides it. For a notarizable,
# distributable bundle use ./build-developer-id.sh (hardened runtime + Developer ID + spctl/notary).
echo "==> Signing ($([ "$DEVID" = "1" ] && echo "Developer-ID + hardened runtime + non-sandbox (app-developerid.entitlements)" || echo "adhoc with Developer-ID entitlements"))"
if [ "$DEVID" = "1" ]; then
  # --deep does not discover arbitrary Mach-O files copied into Resources. The
  # embedded Python interpreter and modules must be signed before the app seal.
  python3 "$ROOT/scripts/sign-nested-runtime.py" "$APP" "$DEVID_IDENTITY"
fi
sign_bundle "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Built: $APP"
codesign -dv "$APP" 2>&1 | sed 's/^/    /'

# In Dev-ID mode, emit a notarization-ready zip + the exact next steps. (spctl will say "rejected"
# until the zip is notarized + stapled — that is expected here, not a failure.)
if [ "$DEVID" = "1" ]; then
  mkdir -p "$ROOT/dist"
  DEVID_ZIP="$ROOT/dist/trading-devid-unnotarized.zip"
  rm -f "$DEVID_ZIP"
  /usr/bin/ditto --norsrc --noextattr --noqtn -c -k --keepParent "$APP" "$DEVID_ZIP"
  echo "==> Dev-ID zip (UNNOTARIZED, ready to notarize): $DEVID_ZIP"
  echo "    sha256 (current): $(shasum -a 256 "$DEVID_ZIP" | cut -d' ' -f1)"
  codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Identifier|TeamIdentifier|flags|Authority=Developer ID" | sed 's/^/    /' || true
  echo "    NEXT: notarize (xcrun notarytool submit --wait / notarize.command), staple"
  echo "          (xcrun stapler staple), then take the STAPLED zip's sha256 for the manifest."
fi

echo "==> DONE"
