#!/bin/bash
# Black Label Trading — notarize + staple the Developer-ID build (FOUNDER ONLY — needs Apple creds).
#
# The bundle in ./build is already FULLY Developer-ID-signed (hardened runtime + secure timestamp,
# real "Developer ID Application: 745ZPGFRA5" cert, no app-sandbox). The ONLY remaining step is
# Apple notarization, which requires your Apple-ID credentials — they are not (and must not be)
# stored in the agent environment. Run this once; ~2-5 min round trip to Apple.
#
# ONE-TIME credential setup (pick ONE), then this script reuses the stored profile:
#   A) App-specific password (appleid.apple.com -> Sign-In & Security -> App-Specific Passwords):
#        xcrun notarytool store-credentials blacklabel-notary \
#          --apple-id "you@appleid" --team-id 745ZPGFRA5 --password "abcd-efgh-ijkl-mnop"
#   B) App Store Connect API key (.p8):
#        xcrun notarytool store-credentials blacklabel-notary \
#          --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-uuid>
#
# Then:  ./notarize.command
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Black Label Trading.app"
ZIP="build/Black-Label-Trading-DeveloperID.zip"
PROFILE="${NOTARY_PROFILE:-blacklabel-notary}"

[ -d "$APP" ] || { echo "FAIL: $APP not found — run ./build-developer-id.sh first." >&2; exit 1; }

echo "==> Pre-flight: signature must be valid Developer-ID + hardened runtime before submitting"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvvv "$APP" 2>&1 | grep -q "flags=0x10000(runtime)" || { echo "FAIL: hardened runtime missing" >&2; exit 1; }

echo "==> (Re)packing notarization zip (ditto preserves the signature)"
rm -f "$ZIP"; /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple notary (profile: $PROFILE) — waits for the verdict"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "==> Stapling the notarization ticket onto the .app"
xcrun stapler staple "$APP"

echo "==> Re-packing the STAPLED, distributable zip"
rm -f "$ZIP"; /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Final Gatekeeper assessment (should now ACCEPT):"
spctl -a -t exec -vv "$APP"
xcrun stapler validate "$APP"
echo ""
echo "==> NOTARIZED + STAPLED. Distributable: $ZIP"
