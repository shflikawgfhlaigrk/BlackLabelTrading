#!/bin/bash
# Reproducible build for Black Label Trading (no Xcode project / no XcodeGen required).
# Compiles Sources/*.swift with swiftc into a signed .app bundle.
#
#   ./build.command            -> builds into ./build/Black Label Trading.app
#   ./build.command --install  -> also installs into /Applications and adhoc re-signs it
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

# --- mode flags --------------------------------------------------------------
# --devid   : sign Developer-ID + hardened runtime + NON-sandbox entitlements (app-devid.entitlements,
#             an empty dict) — notarization-ready, and the ONLY build the in-app updater can
#             self-replace (the sandbox forbids self-replace). The adhoc default path is unchanged.
# --install : after building, install the fresh bundle into /Applications (atomic swap).
DEVID=0; INSTALL=0
for a in "$@"; do case "$a" in --devid) DEVID=1;; --install) INSTALL=1;; esac; done

DEVID_ENTITLEMENTS="$SRC/app-devid.entitlements"
ADHOC_ENTITLEMENTS="$SRC/app-developerid.entitlements"
DEVID_IDENTITY=""
if [ "$DEVID" = "1" ]; then
  # Resolve the first VALID Developer ID Application identity by HASH (avoids the "ambiguous —
  # matches N identities" error when more than one valid cert is in the keychain).
  DEVID_IDENTITY="$(security find-identity -v -p codesigning | awk '/Developer ID Application/{print $2; exit}')"
  if [ -z "$DEVID_IDENTITY" ]; then
    echo "ABORT: --devid requested but no 'Developer ID Application' identity is in the keychain."; exit 1
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
  -framework AuthenticationServices -framework CryptoKit -framework LocalAuthentication -framework Security )
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
  <key>CFBundleVersion</key><string>14</string>
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

# --- copy resources if present (icon/assets/fonts) ---
[ -f "$SRC/Assets.xcassets/AppIcon.appiconset"/*.icns ] 2>/dev/null && true
# Prefer resources already built into the installed app if our source lacks compiled assets.
if [ -f "/Applications/$APPNAME.app/Contents/Resources/AppIcon.icns" ]; then
  cp -f "/Applications/$APPNAME.app/Contents/Resources/AppIcon.icns" "$APP/Contents/Resources/" || true
fi
if [ -d "/Applications/$APPNAME.app/Contents/Resources/Fonts" ]; then
  cp -Rf "/Applications/$APPNAME.app/Contents/Resources/Fonts" "$APP/Contents/Resources/" || true
fi
if [ -f "/Applications/$APPNAME.app/Contents/Resources/Assets.car" ]; then
  cp -f "/Applications/$APPNAME.app/Contents/Resources/Assets.car" "$APP/Contents/Resources/" || true
fi

# --- privacy manifest (REQUIRED, accurate: no tracking, no collection, UserDefaults reason) ---
[ -f "$SRC/PrivacyInfo.xcprivacy" ] && cp -f "$SRC/PrivacyInfo.xcprivacy" "$APP/Contents/Resources/PrivacyInfo.xcprivacy"

# --- bundle the SELF-CONTAINED data backend (stdlib-only Python; ships NO data) ---
# The buyer's app starts its bundled browser bridge and receives THEIR OWN feed into THEIR OWN
# local SQLite store over /webhook/feed. These are code only — the store is created empty at runtime.
if [ -d "$ROOT/backend" ]; then
  echo "==> Bundling self-contained backend (code only, no data)"
  mkdir -p "$APP/Contents/Resources/backend"
  cp -f "$ROOT/backend"/bltd_*.py "$APP/Contents/Resources/backend/"
  cp -f "$ROOT/backend/launch-backend.sh" "$APP/Contents/Resources/backend/"
  chmod +x "$APP/Contents/Resources/backend/launch-backend.sh"
  # Reference OOS verdicts: Black Label's edge-gate result on OUR OWN historical ES bars (research,
  # not buyer data) so a cold buyer sees a real earned verdict at /api/reference. NOT the buyer's
  # account, NOT a promise. gen_reference.py (the build-time generator) is deliberately NOT shipped.
  [ -f "$ROOT/backend/reference_oos.json" ] && cp -f "$ROOT/backend/reference_oos.json" "$APP/Contents/Resources/backend/"

  RUNTIME_SRC=""
  if [ -d "$ROOT/vendor/python-runtime" ]; then
    RUNTIME_SRC="$ROOT/vendor/python-runtime"
  elif [ -d "/Applications/$APPNAME.app/Contents/Resources/backend/python-runtime" ]; then
    RUNTIME_SRC="/Applications/$APPNAME.app/Contents/Resources/backend/python-runtime"
  fi
  if [ -z "$RUNTIME_SRC" ]; then
    echo "ABORT: missing bundled backend runtime (expected vendor/python-runtime)."; exit 1
  fi

  echo "==> Bundling backend runtime"
  rm -rf "$APP/Contents/Resources/backend/python-runtime"
  cp -Rf "$RUNTIME_SRC" "$APP/Contents/Resources/backend/python-runtime"
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
fi

# --- adhoc sign with the DEVELOPER-ID entitlements (NO app-sandbox, NO applesignin) ---
# Trading spawns its bundled Python backend, which the App Store sandbox would forbid — so even
# this convenience build uses the Developer-ID entitlements (network.client + the hardened-runtime
# library/dyld exceptions the python backend needs). It deliberately does NOT carry app-sandbox or
# the restricted applesignin entitlement (AMFI SIGKILLs an ad-hoc app that carries applesignin).
# The Apple button is runtime-gated on the entitlement, so this build hides it. For a notarizable,
# distributable bundle use ./build-developer-id.sh (hardened runtime + Developer ID + spctl/notary).
echo "==> Signing ($([ "$DEVID" = "1" ] && echo "Developer-ID + hardened runtime + non-sandbox (app-devid.entitlements)" || echo "adhoc with Developer-ID entitlements"))"
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

if [ "$INSTALL" = "1" ]; then
  echo "==> Installing into /Applications/$APPNAME.app (atomic stage → verify → swap)"
  DEST="/Applications/$APPNAME.app"
  # §5.9 ATOMIC install (was: cp -Rf "$APP" "$DEST" straight into the live path on
  # first install / in-place file copies + in-place re-sign). A kill mid-copy (3600s
  # dispatch timeout / crash / disk-full) left a half-written DOA bundle in
  # /Applications a buyer can't launch. Fix: stage the freshly built, complete bundle
  # (icon/fonts/Assets.car/backend already assembled above) to a sibling, re-sign +
  # verify the STAGE, then atomically rename it into place. Matches the proven
  # Homefront/Sovereign/Marketing pattern (support-escalation P0 nonatomic-install).
  STAGE="$DEST.staging.$$"
  OLD="$DEST.old.$$"
  rm -rf "$STAGE" "$OLD"
  # Keep the privacy manifest in sync inside the fresh bundle before staging.
  [ -f "$SRC/PrivacyInfo.xcprivacy" ] && cp -f "$SRC/PrivacyInfo.xcprivacy" "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
  echo "==> Staging build into $STAGE"
  cp -Rf "$APP" "$STAGE"
  echo "==> Re-signing staged bundle ($([ "$DEVID" = "1" ] && echo "Developer-ID + hardened runtime + non-sandbox" || echo "adhoc, with Developer-ID entitlements"))"
  codesign --remove-signature "$STAGE" 2>/dev/null || true
  sign_bundle "$STAGE"
  # Verify the staged bundle is whole + signed BEFORE disturbing the live bundle.
  [ -f "$STAGE/Contents/Info.plist" ] || { echo "ABORT: staged bundle incomplete (no Info.plist)"; rm -rf "$STAGE"; exit 1; }
  codesign --verify --deep --strict "$STAGE" || { echo "ABORT: staged bundle fails codesign"; rm -rf "$STAGE"; exit 1; }
  # Atomic swap — keep a rollback copy until the rename lands.
  [ -d "$DEST" ] && mv "$DEST" "$OLD"
  mv "$STAGE" "$DEST"
  rm -rf "$OLD"
  codesign -dv "$DEST" 2>&1 | sed 's/^/    /'
  echo "==> Installed (atomic): $DEST"
fi

echo "==> DONE"
