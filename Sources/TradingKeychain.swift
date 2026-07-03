// Black Label Trading — Keychain routing helper.
//
// WHY THIS EXISTS (Founder 2026-07-03): keychain items written with a plain SecItemAdd (no
// kSecUseDataProtectionKeychain) land in the LEGACY login keychain, whose access-control list is
// bound to the calling binary's CODE SIGNATURE. Local Trading builds are adhoc re-signed on every
// rebuild, so each rebuild is a NEW identity to that ACL → macOS re-prompts ("Black Label Trading
// wants to use your confidential information…") and "Always Allow" can never stick.
//
// THE FIX: route ALL SecItem traffic through here so items land in the DATA-PROTECTION keychain,
// whose access is keyed to the APP IDENTIFIER (stable across rebuilds) rather than the per-binary
// signature. On read, an item found only in the legacy keychain is migrated forward (rewritten to
// the data-protection keychain + legacy copy deleted), so a signature-bound ACL can prompt at most
// once more, then never again. Builds without an application identifier (adhoc/dev) get
// errSecMissingEntitlement from the data-protection keychain and fall through to the legacy path
// unchanged — nothing regresses on unsigned builds.
//
// This mirrors `enum SovereignKeychain` in ~/BlackLabelSovereign/Sources/ExternalAuth.swift.
//
// HONESTY: this changes only WHERE the buyer's OWN credential is stored on THIS Mac. It ships no
// secret, logs no secret, and syncs nothing — the credential still lives only in the local keychain.
import Foundation
import Security

/// All real-Keychain traffic for Trading routes through here. Callers pass a `base` query dict
/// (class + service + account, no value/return keys) and this helper adds the storage-location and
/// return keys. Keeps the data-protection-first + legacy-migrate + adhoc-fallback logic in one place.
enum TradingKeychain {
    /// Overwrite-style write: clears any prior item in BOTH keychains (so a stale legacy copy can't
    /// shadow the new one), then adds to the data-protection keychain, falling back to legacy when
    /// the build has no application identifier (errSecMissingEntitlement).
    static func set(_ base: [String: Any], data: Data) {
        delete(base)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        var dp = add
        dp[kSecUseDataProtectionKeychain as String] = true
        if SecItemAdd(dp as CFDictionary, nil) == errSecMissingEntitlement {
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// Read, preferring the data-protection keychain. A hit found only in the legacy keychain is
    /// migrated forward (rewrite + legacy delete), so its signature-bound ACL can prompt at most
    /// once more; a fresh install with no legacy item never prompts at all. Returns nil when absent.
    static func copy(_ base: [String: Any]) -> Data? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var dp = q
        dp[kSecUseDataProtectionKeychain as String] = true
        var out: AnyObject?
        let dpStatus = SecItemCopyMatching(dp as CFDictionary, &out)
        if dpStatus == errSecSuccess, let d = out as? Data { return d }
        out = nil
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        if dpStatus != errSecMissingEntitlement { set(base, data: d) }
        return d
    }

    /// Delete from both keychains (data-protection + legacy). Neither delete ever prompts.
    static func delete(_ base: [String: Any]) {
        var dp = base
        dp[kSecUseDataProtectionKeychain as String] = true
        SecItemDelete(dp as CFDictionary)
        SecItemDelete(base as CFDictionary)
    }
}
