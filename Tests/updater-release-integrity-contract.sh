#!/bin/bash
# Fail-closed source contract for the AppKit replacement helper and distribution checks.
# The Swift headless suite exercises semantic manifest/checksum/bundle/assessment logic; this
# companion lock covers the UI helper that cannot be included in that non-AppKit test binary.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/Sources/Updater.swift"
UI="$ROOT/Sources/UpdaterUI.swift"
PASSED=0
FAILED=0

pass() {
  PASSED=$((PASSED + 1))
}

fail() {
  FAILED=$((FAILED + 1))
  echo "  FAIL: $1"
}

require_literal() {
  local file="$1"
  local literal="$2"
  local label="$3"
  if grep -Fq "$literal" "$file"; then pass; else fail "$label"; fi
}

require_regex() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if grep -Eq "$pattern" "$file"; then pass; else fail "$label"; fi
}

require_regex "$CORE" '^[[:space:]]*var sha256: String$' "updater manifest must require sha256"
require_regex "$CORE" '^[[:space:]]*var notarized: Bool$' "updater manifest must require notarized metadata"
require_regex "$CORE" '^[[:space:]]*var teamID: String$' "updater manifest must require team_id"
require_regex "$CORE" '^[[:space:]]*var downloadURL: String$' "updater manifest must require download_url"
require_literal "$CORE" "static let bundleIdentifier = \"com.blacklabel.trading\"" "exact Trading bundle id must be pinned"
require_literal "$CORE" "static let productSlug = \"trading\"" "exact Trading product slug must be pinned"
require_literal "$CORE" "static let teamID = \"745ZPGFRA5\"" "exact Apple team must be pinned"
require_literal "$CORE" "guard appURL.lastPathComponent == \"\\(productName).app\"" "staged app filename must match the exact product"
require_literal "$CORE" "url.scheme?.caseInsensitiveCompare(\"https\") == .orderedSame" "HTTPS predicate must remain fail closed"
require_literal "$CORE" "completionHandler(Self.redirectTargetIsAllowed(request.url) ? request : nil)" "every redirect hop must pass the HTTPS gate"
require_literal "$CORE" "URLSession(configuration: c, delegate: redirectDelegate, delegateQueue: nil)" "network session must install the redirect delegate"
final_url_checks="$(grep -Fc 'guard let finalURL = http.url, isHTTPSURL(finalURL)' "$CORE" || true)"
if [ "$final_url_checks" -eq 2 ]; then pass; else fail "manifest and download final URLs must both be HTTPS-checked"; fi
require_literal "$CORE" "let url = try validateInstallCandidate(m, currentBuild: installedBuild)" "stage must refuse downgrade or unknown installed build"
require_literal "$CORE" "try verifyChecksum(data, against: m)" "downloaded response bytes must be verified before staging"
require_literal "$CORE" "try verifyChecksum(try Data(contentsOf: zipURL), against: m)" "persisted zip bytes must be reverified"
require_literal "$CORE" "try applyQuarantine(to: zipURL, originURL: url)" "downloaded zip must be quarantined before extraction"
require_literal "$CORE" "try applyQuarantine(to: appURL, originURL: url)" "staged app must carry quarantine before assessment"
require_literal "$CORE" "[\"--rsrc\", \"--extattr\", \"--qtn\", \"--acl\", \"-x\", \"-k\"" "ditto must explicitly preserve quarantine and metadata"
require_literal "$CORE" "p.environment = sanitizedToolEnvironment()" "ditto must not inherit DITTONORSRC or COPYFILE_DISABLE"
require_literal "$CORE" "identifier \"\\(requiredBundleIdentifier)\" and anchor apple generic" "signature requirement must pin identifier and Apple anchor"
require_literal "$CORE" "certificate 1[field.1.2.840.113635.100.6.2.6] exists" "Developer ID intermediate OID must be required"
require_literal "$CORE" "certificate leaf[field.1.2.840.113635.100.6.1.13] exists" "Developer ID Application OID must be required"
require_literal "$CORE" "certificate leaf[subject.OU] = \"\\(requiredTeamID)\"" "signature requirement must pin the exact team OU"
require_literal "$CORE" "kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode" "all architectures and nested code must be strictly checked"
require_literal "$CORE" "source=Notarized Developer ID" "Gatekeeper result must name the notarized source"
require_literal "$CORE" "\"/usr/bin/stapler\"" "stapler must resolve from its fixed system path"
require_literal "$CORE" "arguments: [\"validate\", \"-v\", appURL.path]" "stapled ticket must be validated"
require_literal "$CORE" "try validateBundleMetadata(metadata, against: manifest)" "staged bundle identity must be checked"

if grep -Eq 'xattr[[:space:]]+(-d|-dr|-rd|--delete).*quarantine' "$UI" "$CORE"; then
  fail "replacement helper must never strip quarantine"
else
  pass
fi

require_literal "$UI" "try Updater.validateInstallCandidate(manifest, currentBuild: Updater.currentBuild())" "UI must repeat the no-downgrade gate"
require_literal "$UI" "try Updater.verifyDistribution(appURL: stagedApp, against: manifest)" "UI must reverify immediately before handoff"
require_literal "$UI" "/usr/bin/codesign --verify --deep --strict --all-architectures" "final-path strict codesign check must remain"
require_literal "$UI" "/usr/sbin/spctl --assess --type execute --verbose=4" "final-path Gatekeeper assessment must remain"
require_literal "$UI" "/usr/bin/stapler validate -v" "final-path staple validation must remain"
require_literal "$UI" "/usr/bin/xattr -p com.apple.quarantine" "final-path quarantine must be asserted, never stripped"
require_literal "$UI" "/usr/bin/grep -Fqx 'source=Notarized Developer ID'" "helper must parse an exact Gatekeeper source line"
require_literal "$UI" "trap rollback HUP INT TERM" "helper must restore backup on termination signals"
require_literal "$UI" "p.environment = Updater.sanitizedToolEnvironment()" "helper must run with a fixed environment"
require_literal "$UI" "Updater.bundleIdentifier," "helper must receive the exact bundle id"
require_literal "$UI" "String(manifest.latestBuild)," "helper must receive the exact manifest build"
require_literal "$UI" "Updater.teamID," "helper must receive the exact team id"
require_literal "$UI" 'support="${10}"' "helper must receive the exact Application Support path"
require_literal "$UI" 'expected_backend_mode="${11}"' "helper must receive the configured backend mode"
require_literal "$UI" 'expected_backend_port="${12}"' "helper must receive the validated bundled port"
require_literal "$UI" '/bin/bash "$staged_backend/launch-backend.sh" --stop-owned' "helper must use the staged verified teardown implementation"
require_literal "$UI" '"BLTD_OWNED_BACKEND_DIR=$installed/Contents/Resources/backend"' "helper must pin teardown to the exact installed backend"
require_literal "$UI" 'if ! /usr/bin/env "BLTD_SUPPORT_DIR=$support"' "helper must fail closed on teardown failure"
require_literal "$UI" 'pending="$support/update-backup.pending"' "helper must retain a deferred-cleanup marker"
require_literal "$UI" "scheduleDeferredBackupCleanup()" "launch path must schedule deferred backup cleanup"
require_literal "$UI" "45_000_000_000" "fallback cleanup must begin after the helper's 30-second window"
require_literal "$UI" '/usr/bin/open -n -W "$installed"' "helper must monitor a new exact GUI instance"
require_literal "$UI" "stable_seconds=30" "helper must require a 30-second stable GUI window"
require_literal "$UI" "health_is_expected() {" "helper must require an exact backend acknowledgement"
require_literal "$UI" 'body.get("runtimeContract") == "bltd-signals-only-runtime-v1"' "rollback health gate must pin the runtime contract"
require_literal "$UI" "health_is_expected || rollback" "failed backend health must restore the old bundle"
require_literal "$UI" '/usr/bin/osascript -e "tell application id' "failed-health rollback must quit the new GUI"
require_literal "$UI" '/bin/rm -rf "$backup"' "helper must delete backup only after stability acknowledgement"
require_literal "$UI" '"BLTD_PYCACHE_ROOT=$support/pycache"' "helper Python calls must use the product cache"
require_literal "$UI" '/bin/bash "$installed_backend/launch-backend.sh" --bg' "signed-out update must start its bundled backend"
require_literal "$UI" '[ "$expected_backend_mode" = "external" ] && return 0' "custom remote backend must skip bundled health"
require_literal "$UI" '"helperPID": int(sys.argv[3])' "recovery marker must bind the detached helper PID"
require_literal "$UI" '"watchdogPID": int(sys.argv[5])' "recovery marker must bind the independent watchdog PID"
require_literal "$UI" "/usr/bin/nohup /bin/sh -c" "update transaction must spawn an independent rollback watchdog"
require_literal "$UI" "mark_state pending || rollback" "watchdog state must exist before bundle replacement"
require_literal "$UI" "recoveryHelperIsAlive(recovery.helperPID)" "fallback must detect an active helper"
require_literal "$UI" "recoveryHelperIsAlive(recovery.watchdogPID)" "fallback must detect an active watchdog"
require_literal "$UI" "UpdateRecoveryPolicy.mayDeleteBackup" "fallback deletion must use the tested recovery policy"
require_literal "$CORE" "helperIsAlive: Bool" "pure recovery policy must receive helper liveness"
require_literal "$CORE" "watchdogIsAlive: Bool" "pure recovery policy must receive watchdog liveness"
require_literal "$CORE" "!helperIsAlive" "pure recovery policy must refuse an active helper"
require_literal "$CORE" "!watchdogIsAlive" "pure recovery policy must refuse an active watchdog"
if grep -Fq "pkill" "$UI"; then
  fail "replacement helper must never use process-name/global pkill"
else
  pass
fi

gate_line="$(grep -nF '/usr/sbin/spctl --assess --type execute --verbose=4' "$UI" | tail -1 | cut -d: -f1 || true)"
staple_line="$(grep -nF '/usr/bin/stapler validate -v' "$UI" | tail -1 | cut -d: -f1 || true)"
marker_line="$(grep -nF '/bin/mv "$pending.tmp.$$" "$pending"' "$UI" | tail -1 | cut -d: -f1 || true)"
open_line="$(grep -nF '/usr/bin/open -n -W "$installed"' "$UI" | tail -1 | cut -d: -f1 || true)"
if [ -n "$gate_line" ] && [ -n "$staple_line" ] && [ -n "$open_line" ] \
   && [ "$gate_line" -lt "$open_line" ] && [ "$staple_line" -lt "$open_line" ]; then
  pass
else
  fail "Gatekeeper and staple validation must precede relaunch"
fi
if [ -n "$marker_line" ] && [ -n "$open_line" ] && [ "$marker_line" -lt "$open_line" ]; then
  pass
else
  fail "rollback marker must be published atomically before the new app can launch"
fi

health_line="$(grep -nF 'health_is_expected || rollback' "$UI" | tail -1 | cut -d: -f1 || true)"
delete_line="$(grep -nF '/bin/rm -rf "$backup"' "$UI" | tail -1 | cut -d: -f1 || true)"
if [ -n "$health_line" ] && [ -n "$delete_line" ] && [ "$health_line" -lt "$delete_line" ]; then
  pass
else
  fail "rollback backup must survive until exact backend health acknowledgement"
fi

exit_wait_line="$(grep -nF 'while /bin/kill -0 "$pid"' "$UI" | tail -1 | cut -d: -f1 || true)"
stop_line="$(grep -nF '/bin/bash "$staged_backend/launch-backend.sh" --stop-owned' "$UI" | tail -1 | cut -d: -f1 || true)"
swap_line="$(grep -nF 'if ! /bin/mv "$installed" "$backup"' "$UI" | tail -1 | cut -d: -f1 || true)"
if [ -n "$exit_wait_line" ] && [ -n "$stop_line" ] && [ -n "$swap_line" ] \
   && [ "$exit_wait_line" -lt "$stop_line" ] && [ "$stop_line" -lt "$swap_line" ]; then
  pass
else
  fail "owned backend teardown must occur after app exit and before bundle replacement"
fi

if /bin/bash "$ROOT/Tests/updater-helper-process-regression.sh"; then
  pass
else
  fail "executable updater helper must abort before swap when teardown fails"
fi
if /bin/bash "$ROOT/Tests/updater-helper-rollback-regression.sh"; then
  pass
else
  fail "executable updater helper must restore the previous bundle after crash/failed health"
fi

echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
