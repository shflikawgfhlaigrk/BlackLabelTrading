#!/bin/bash
# build-signed.command — PROVISIONED build of Black Label Trading that carries the restricted
# "Sign in with Apple" entitlement. This is the ONLY build in which the Apple sign-in button
# appears and works (the app gates it at runtime on the entitlement; ad-hoc builds hide it).
#
# It embeds the Xcode-managed Mac Team Provisioning Profile for com.blacklabel.trading and
# signs with an Apple Development (or Distribution) identity + Hardened Runtime.
#
#   ./build-signed.command                 # auto-pick Apple Development identity (local run/test)
#   IDENTITY="Apple Distribution: ... (745ZPGFRA5)" ./build-signed.command   # store/distribution
# The provisioned Apple Development/Distribution build stays in ./build. It is never
# allowed to replace the canonical Developer-ID production app in /Applications.
#
# Notarization (Developer ID path) is handled by the separate Developer-ID flow; this script
# targets the development/distribution-signed bundle that honors the restricted entitlement.
set -euo pipefail
cd "$(dirname "$0")"
if [[ $# -gt 0 ]]; then
  case "$1" in
    --install)
      echo "ABORT: provisioned Apple Development/Distribution builds cannot replace the canonical production app; use the Developer-ID release lane." >&2
      exit 64
      ;;
    --help|-h)
      echo "Usage: $0  # writes a provisioned test bundle under ./build only"
      exit 0
      ;;
    *) echo "ABORT: unknown argument: $1" >&2; exit 2 ;;
  esac
fi
ROOT="$(pwd)"
SRC="$ROOT/Sources"
BUILD="$ROOT/build"
APPNAME="Black Label Trading"
APP="$BUILD/$APPNAME.app"
BIN_NAME="Black Label Trading"
BUNDLE_ID="com.blacklabel.trading"
TEAM="745ZPGFRA5"
ENTS="$SRC/app-release.entitlements"

echo "==> Signals-only release contract (source preflight)"
bash "$ROOT/Tests/signals-only-release-contract.sh"

# Locate the Xcode-managed provisioning profile for this bundle id (development first).
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
find_profile() {
  local want_store="$1"   # "yes" = prefer the Store profile, else the dev profile
  for f in "$PROFILE_DIR"/*.provisionprofile; do
    [ -f "$f" ] || continue
    local name; name="$(security cms -D -i "$f" 2>/dev/null | plutil -extract Name raw - 2>/dev/null || true)"
    case "$name" in
      *"$BUNDLE_ID"*)
        if [ "$want_store" = "yes" ] && [[ "$name" == *Store* ]]; then echo "$f"; return 0; fi
        if [ "$want_store" != "yes" ] && [[ "$name" != *Store* ]]; then echo "$f"; return 0; fi
        ;;
    esac
  done
  return 1
}

# Identity: resolve to a SHA-1 HASH (names can be ambiguous when two certs share a name).
# IDENTITY may be a name substring ("Apple Distribution") or a hash; default = first dev cert.
IDENTITY_REQ="${IDENTITY:-Apple Development}"
IDENTITY="$(security find-identity -v -p codesigning | grep -m1 "$IDENTITY_REQ" | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-F]+).*/\1/')"
if [ -z "$IDENTITY" ]; then
  echo "FAIL: no signing identity matching '$IDENTITY_REQ'. Open Xcode > Settings > Accounts to create one." >&2
  security find-identity -v -p codesigning >&2
  exit 1
fi
IDENTITY_NAME="$(security find-identity -v -p codesigning | grep -m1 "$IDENTITY" | sed -E 's/.*"(.*)".*/\1/')"

# Pick a profile (dev for a dev identity, store for a distribution identity).
if [[ "$IDENTITY_NAME" == *Distribution* ]]; then PROFILE="$(find_profile yes || true)"; else PROFILE="$(find_profile no || true)"; fi
if [ -z "${PROFILE:-}" ]; then
  echo "FAIL: no provisioning profile for $BUNDLE_ID found in:" >&2
  echo "  $PROFILE_DIR" >&2
  echo "Open the project in Xcode once (it auto-creates a managed profile), or download it from" >&2
  echo "developer.apple.com, then re-run." >&2
  exit 1
fi

echo "==> Identity: $IDENTITY_NAME ($IDENTITY)"
echo "==> Profile : $(security cms -D -i "$PROFILE" 2>/dev/null | plutil -extract Name raw - 2>/dev/null)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling Sources/*.swift (universal2, Hardened-Runtime compatible)"
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
lipo -create "$BUILD/$BIN_NAME-arm64" "$BUILD/$BIN_NAME-x86_64" -output "$APP/Contents/MacOS/$BIN_NAME"
rm -f "$BUILD/$BIN_NAME-arm64" "$BUILD/$BIN_NAME-x86_64"
lipo -archs "$APP/Contents/MacOS/$BIN_NAME"

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
  <key>CFBundleVersion</key><string>27</string>
  <key>ITSAppUsesNonExemptEncryption</key><false/>
  <key>LSApplicationCategoryType</key><string>public.app-category.finance</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Black Label. All rights reserved.</string>
  <key>CFBundleURLTypes</key>
  <array><dict><key>CFBundleURLSchemes</key><array><string>$BUNDLE_ID</string></array></dict></array>
</dict>
</plist>
PLIST

# Compile the source-controlled asset catalog. A release build never inherits bytes from an older
# installed bundle.
xcrun actool "$SRC/Assets.xcassets" \
  --compile "$APP/Contents/Resources" \
  --platform macosx \
  --minimum-deployment-target 13.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$BUILD/asset-info.plist"
[ -f "$APP/Contents/Resources/AppIcon.icns" ] || { echo "FAIL: actool did not emit AppIcon.icns" >&2; exit 1; }
[ -f "$APP/Contents/Resources/Assets.car" ] || { echo "FAIL: actool did not emit Assets.car" >&2; exit 1; }
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Embedding provisioning profile"
cp -f "$PROFILE" "$APP/Contents/embedded.provisionprofile"

echo "==> Signing (Hardened Runtime, release entitlements incl. Apple Sign-In)"
codesign --force --options runtime --timestamp=none \
  --entitlements "$ENTS" --sign "$IDENTITY" "$APP"

echo "==> Verify signature + entitlement"
codesign --verify --strict --verbose=2 "$APP"
echo "--- entitlements on the signed binary ---"
codesign -d --entitlements :- "$APP" 2>/dev/null | grep -A2 applesignin || true
if codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "com.apple.developer.applesignin"; then
  echo "OK: Apple Sign-In entitlement present — the Apple button will appear at runtime."
else
  echo "FAIL: Apple Sign-In entitlement missing from the signed binary." >&2
  exit 1
fi

echo "==> DONE — provisioned bundle: $APP"
