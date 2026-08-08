# Trading CI and release pipeline

`Trading CI` runs on pull requests, branch pushes, and manual dispatch. It executes
`Tests/run-all.sh`, then creates a build-27 universal app with
`build-developer-id.sh --no-submit --launch-test`. The uploaded seven-day artifact is
ad-hoc signed for CI launch verification and is deliberately named
`UNSIGNED-ADHOC-NOT-FOR-DISTRIBUTION`.

`Trading notarized release` runs only for the exact `v1.0.27` tag or a manual dispatch
whose tag input is exactly `v1.0.27`. It uses the protected `production` environment,
requires the release commit to be reachable from the repository's default branch, runs
the canonical test gate, signs with the Developer ID certificate, submits to Apple,
staples the accepted ticket, repeats bundle and Gatekeeper verification, publishes the
immutable zip to the public updater origin, verifies its SHA through an unauthenticated
download, atomically switches the live manifest, reads the exact manifest back, and only
then creates the GitHub Release. Neither workflow invokes `--install`.

Before any public R2 object or manifest changes, the workflow preserves the notarized zip,
checksum, notarization ID, and exact proposed manifest as an immutable Actions artifact.
Signing then ends. A separate public-distribution job downloads that artifact and is the only
job given the rotated R2 credentials. If publication or live readback fails, GitHub's
“re-run failed jobs” resumes from the identical preserved bytes without rebuilding,
re-signing, or generating a different notarization ticket.
Before any R2 mutation, that job binds the preserved zip, checksum, manifest,
notarization ID, release commit, and configured public download URL to one exact release.
Both CI and release also inspect every Mach-O in the bundled Python runtime; every binary
must contain exactly the `arm64` and `x86_64` slices. Release repeats that inspection after
extracting the final stapled zip.

Configure the `production` GitHub environment with a required reviewer, then add these
environment secrets:

- `DEVELOPER_ID_P12_BASE64`: base64 of the Developer ID Application PKCS#12 file for
  Apple team `745ZPGFRA5`.
- `DEVELOPER_ID_P12_PASSWORD`: the PKCS#12 export password.
- `NOTARY_API_KEY_P8_BASE64`: base64 of the App Store Connect team API `.p8` key.
- `NOTARY_API_KEY_ID`: App Store Connect API key ID.
- `NOTARY_API_ISSUER_ID`: App Store Connect team API issuer UUID.
- `ROTATED_R2_ACCESS_KEY_ID`: a newly rotated R2 S3 access key.
- `ROTATED_R2_SECRET_ACCESS_KEY`: its newly rotated R2 secret key.
- `ROTATED_R2_S3_ENDPOINT`: the credential-free HTTPS R2 S3 endpoint.
- `ROTATED_R2_BUCKET`: the release bucket.
- `ROTATED_R2_TRADING_MANIFEST_KEY`: the object key consumed by
  `https://blacklabelbots.com/api/version/trading`.
- `TRADING_PUBLIC_DOWNLOAD_URL`: the unauthenticated HTTPS URL ending in
  `/trading/27.zip`.

The credentials are decoded only into runner-temporary files, imported into an
ephemeral keychain, and deleted in an unconditional cleanup step. Previously exposed
Cloudflare/R2 credentials must not be placed in these secrets; release remains failed
closed until newly rotated credentials and a working public download origin are present.
