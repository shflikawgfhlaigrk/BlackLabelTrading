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
  echo "==> Installing executable into /Applications/$APPNAME.app"
  DEST="/Applications/$APPNAME.app"
  if [ ! -d "$DEST" ]; then
    echo "    No existing bundle — copying whole .app"
    cp -Rf "$APP" "$DEST"
  else
    cp -f "$APP/Contents/MacOS/$BIN_NAME" "$DEST/Contents/MacOS/$BIN_NAME"
    cp -f "$APP/Contents/Info.plist" "$DEST/Contents/Info.plist"
    # Keep the bundled self-contained backend (code only) in sync on install.
    if [ -d "$APP/Contents/Resources/backend" ]; then
      rm -rf "$DEST/Contents/Resources/backend"
      cp -Rf "$APP/Contents/Resources/backend" "$DEST/Contents/Resources/backend"
    fi
  fi
  # Keep the privacy manifest in sync on install too.
  [ -f "$SRC/PrivacyInfo.xcprivacy" ] && cp -f "$SRC/PrivacyInfo.xcprivacy" "$DEST/Contents/Resources/PrivacyInfo.xcprivacy"
  echo "==> Re-signing installed bundle (adhoc, with Developer-ID entitlements)"
  codesign --force --deep --sign - --entitlements "$SRC/app-developerid.entitlements" "$DEST"
  codesign -dv "$DEST" 2>&1 | sed 's/^/    /'
  echo "==> Installed: $DEST"
fi

echo "==> DONE"
