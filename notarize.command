#!/bin/bash
# Black Label Trading — guarded notarization wrapper (FOUNDER ONLY — needs Apple creds).
#
# The bundle in ./build is already FULLY Developer-ID-signed (hardened runtime + secure timestamp,
# real "Developer ID Application: 745ZPGFRA5" cert, no app-sandbox). The ONLY remaining step is
# Apple notarization, which requires your Apple-ID credentials — they are not (and must not be)
# stored in the agent environment. Run this once; ~2-5 min round trip to Apple.
#
# ONE-TIME credential setup (pick ONE), then this script reuses the stored profile:
#   A) App-specific password (appleid.apple.com -> Sign-In & Security -> App-Specific Passwords):
#        xcrun notarytool store-credentials BL_NOTARY \
#          --apple-id "you@appleid" --team-id 745ZPGFRA5 --password "abcd-efgh-ijkl-mnop"
#   B) App Store Connect API key (.p8):
#        xcrun notarytool store-credentials BL_NOTARY \
#          --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-uuid>
#
# Then, after Michael explicitly approves Apple contact:
#        ./notarize.command --submit
set -euo pipefail
cd "$(dirname "$0")"
NOTARY_PROFILE="${NOTARY_PROFILE:-BL_NOTARY}"
export NOTARY_PROFILE

case "${1:-}" in
  --submit)
    shift
    exec ./build-developer-id.sh --submit "$@"
    ;;
  -h|--help)
    echo "Usage: ./notarize.command --submit"
    echo "  Delegates to ./build-developer-id.sh --submit using NOTARY_PROFILE=$NOTARY_PROFILE."
    echo "  Default execution intentionally makes no Apple contact."
    exit 0
    ;;
  "")
    echo "==> NOTARIZATION HELD: no Apple contact made."
    echo "    This wrapper no longer submits directly; it delegates to the gated build script."
    echo "    After Michael's explicit approval, run: ./notarize.command --submit"
    echo "    Notary profile: $NOTARY_PROFILE"
    exit 0
    ;;
  *)
    echo "Unknown argument: $1" >&2
    echo "Usage: ./notarize.command --submit" >&2
    exit 2
    ;;
esac
