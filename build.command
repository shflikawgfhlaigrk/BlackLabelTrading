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

SDK="$(xcrun --sdk macosx --show-sdk-path)"
echo "==> SDK: $SDK"
echo "==> swiftc: $(xcrun --sdk macosx -f swiftc)"

# --- clean app skeleton ---
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# --- compile all Swift sources into one executable ---
echo "==> Compiling Sources/*.swift"
SWIFT_FILES=( "$SRC"/*.swift )
xcrun --sdk macosx swiftc \
  -O \
  -sdk "$SDK" \
  -target arm64-apple-macosx13.0 \
  -framework SwiftUI -framework AppKit -framework Charts \
  -framework AuthenticationServices -framework CryptoKit \
  -o "$APP/Contents/MacOS/$BIN_NAME" \
  "${SWIFT_FILES[@]}"
echo "==> Linked executable: $APP/Contents/MacOS/$BIN_NAME"

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
  <key>CFBundleVersion</key><string>1</string>
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
# The buyer's app captures THEIR OWN WealthCharts feed into THEIR OWN local SQLite store and
# serves it on 127.0.0.1:8787. These are code only — the store is created empty at runtime.
if [ -d "$ROOT/backend" ]; then
  echo "==> Bundling self-contained backend (code only, no data)"
  mkdir -p "$APP/Contents/Resources/backend"
  cp -f "$ROOT/backend"/bltd_*.py "$APP/Contents/Resources/backend/"
  cp -f "$ROOT/backend/launch-backend.sh" "$APP/Contents/Resources/backend/"
  chmod +x "$APP/Contents/Resources/backend/launch-backend.sh"
fi

# --- adhoc sign with the DEVELOPER-ID entitlements (NO app-sandbox, NO applesignin) ---
# Trading spawns its bundled Python backend, which the App Store sandbox would forbid — so even
# this convenience build uses the Developer-ID entitlements (network.client + the hardened-runtime
# library/dyld exceptions the python backend needs). It deliberately does NOT carry app-sandbox or
# the restricted applesignin entitlement (AMFI SIGKILLs an ad-hoc app that carries applesignin).
# The Apple button is runtime-gated on the entitlement, so this build hides it. For a notarizable,
# distributable bundle use ./build-developer-id.sh (hardened runtime + Developer ID + spctl/notary).
echo "==> Signing (adhoc) with Developer-ID entitlements"
codesign --force --deep --sign - \
  --entitlements "$SRC/app-developerid.entitlements" \
  "$APP"

echo "==> Built: $APP"
codesign -dv "$APP" 2>&1 | sed 's/^/    /'

if [ "${1:-}" == "--install" ]; then
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
  echo "==> Re-signing staged bundle (adhoc, with Developer-ID entitlements)"
  codesign --force --deep --sign - --entitlements "$SRC/app-developerid.entitlements" "$STAGE"
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
