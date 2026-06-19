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
#   ./build-developer-id.sh --install       # also install to /Applications
#   ./build-developer-id.sh --launch-test   # build, sign, launch, prove backend up, then quit
#
# Signals-only product. Ships NO data — the SQLite store is created empty at runtime.
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
ENTS="$SRC/app-developerid.entitlements"

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

# --- compile (hardened-runtime compatible) ---
echo "==> Compiling Sources/*.swift"
SWIFT_FILES=( "$SRC"/*.swift )
xcrun --sdk macosx swiftc \
  -O -sdk "$SDK" -target arm64-apple-macosx13.0 \
  -framework SwiftUI -framework AppKit -framework Charts \
  -framework AuthenticationServices -framework CryptoKit -framework UserNotifications \
  -o "$APP/Contents/MacOS/$BIN_NAME" \
  "${SWIFT_FILES[@]}"

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
  <key>CFBundleVersion</key><string>1</string>
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

# Zero-data guard: fail loudly if any database/data file slipped into the bundle.
STRAY="$(find "$APP" -type f \( -name '*.sqlite3' -o -name '*.db' -o -name '*.sqlite' -o -name 'bars_log.csv' -o -name 'fires*.json' \) 2>/dev/null || true)"
if [ -n "$STRAY" ]; then echo "FAIL: data files in bundle (must ship EMPTY):" >&2; echo "$STRAY" >&2; exit 1; fi

# --- sign with HARDENED RUNTIME + Developer ID entitlements (NO app-sandbox, NO applesignin) ----
# --deep signs the nested launcher script's resources too. --options runtime = hardened runtime,
# required for notarization. --timestamp is used for a Developer ID identity (notary needs a secure
# timestamp); ad-hoc skips it.
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

# Assert the forbidden entitlements are ABSENT and the hardened-runtime exceptions are PRESENT.
ENTDUMP="$(codesign -d --entitlements - "$APP" 2>/dev/null || true)"
echo "$ENTDUMP" | grep -q 'app-sandbox'  && { echo "FAIL: app-sandbox must NOT be present for the Developer-ID backend-spawn build" >&2; exit 1; } || true
echo "$ENTDUMP" | grep -q 'applesignin' && { echo "FAIL: applesignin must NOT be present (AMFI SIGKILL without a profile)" >&2; exit 1; } || true
echo "$ENTDUMP" | grep -q 'disable-library-validation' || { echo "FAIL: disable-library-validation missing (python backend won't load its libs)" >&2; exit 1; }

# --- Gatekeeper assessment (informational for adhoc; real verdict needs notarization) ----
echo "==> spctl -a -t exec assessment:"
spctl -a -t exec -vv "$APP" 2>&1 | sed 's/^/    /' || true

if [ "${1:-}" == "--install" ]; then
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

if [ "${1:-}" == "--launch-test" ]; then
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
  echo "      3) Notarize:  xcrun notarytool submit \"$APP.zip\" --apple-id <id> --team-id $TEAM --wait"
  echo "         then:       xcrun stapler staple \"$APP\""
fi
