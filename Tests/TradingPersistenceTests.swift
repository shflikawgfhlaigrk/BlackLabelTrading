import Foundation
import Security

private var failures = 0

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() {
        print("PASS: \(message)")
    } else {
        failures += 1
        print("FAIL: \(message)")
    }
}

private func temporaryDirectory(_ label: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("bltd-\(label)-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func baseQuery(service: String = "com.blacklabel.trading.test", account: String = "buyer@example.com") -> [String: Any] {
    [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
    ]
}

private func posixMode(_ url: URL) -> Int? {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs?[.posixPermissions] as? NSNumber)?.intValue
}

private func testPrivateCredentialStoreRoundTripAndPermissions() {
    let root = temporaryDirectory("credential-store")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TradingSecretStore(rootURL: root)
    let first = Data("first-private-value".utf8)
    let second = Data("replacement-private-value".utf8)

    check(store.write(first, service: "service-A", account: "account-A"),
          "private credential write reports success")
    check(store.contains(service: "service-A", account: "account-A"),
          "metadata-only credential presence check sees the saved item")
    check(store.read(service: "service-A", account: "account-A") == first,
          "private credential bytes round-trip exactly")
    check(posixMode(root) == 0o700, "credential directory is owner-only 0700")
    check(posixMode(store.fileURL(service: "service-A", account: "account-A")) == 0o600,
          "credential file is owner-only 0600")

    check(store.write(second, service: "service-A", account: "account-A"),
          "credential overwrite reports success")
    check(store.read(service: "service-A", account: "account-A") == second,
          "credential overwrite publishes only the replacement bytes")
    check(store.read(service: "service-A", account: "account-B") == nil,
          "different credential accounts remain isolated")

    check(store.remove(service: "service-A", account: "account-A"),
          "active credential removal reports success")
    check(!store.contains(service: "service-A", account: "account-A"),
          "active credential removal clears only the private-file item")
}

private func testKeychainRecoveryIsExplicitAndNonDestructive() {
    let root = temporaryDirectory("credential-recovery")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TradingSecretStore(rootURL: root)
    let query = baseQuery()
    let legacyBytes = Data("preserved-keychain-value".utf8)
    var legacyReadCount = 0
    let legacyStillPresent = true
    let repository = TradingCredentialRepository(activeStore: store) { _ in
        legacyReadCount += 1
        return legacyStillPresent ? legacyBytes : nil
    }

    check(!repository.hasActive(query), "cold presence probe starts from private-file metadata")
    check(legacyReadCount == 0, "cold presence probe never asks Keychain for secret data")
    check(repository.loadActive(query) == nil, "active read does not silently fall through to Keychain")
    check(legacyReadCount == 0, "ordinary active read never asks Keychain for secret data")

    check(repository.recoverExistingKeychainItem(query),
          "explicit foreground recovery copies an existing Keychain item")
    check(legacyReadCount == 1, "explicit recovery is the sole Keychain read")
    check(repository.loadActive(query) == legacyBytes,
          "recovered bytes become available from the prompt-free active store")
    check(legacyStillPresent, "recovery leaves the old Keychain item untouched")

    repository.removeActive(query)
    check(!repository.hasActive(query), "disconnect removes the active private-file credential")
    check(legacyStillPresent, "disconnect never deletes the preserved Keychain item")
}

private func testPersistedAppSessionRestoreAndScopedSignOut() {
    let suite = "com.blacklabel.trading.tests.session.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppSessionStore(defaults: defaults)

    let local = AppSessionIdentity(email: "buyer@example.com", kind: .local)
    store.save(local)
    check(store.restore(localAccountExists: { $0 == "buyer@example.com" }) == local,
          "a valid local app session restores after relaunch")

    defaults.set(["buyer@example.com": "account-hash"], forKey: "unrelated-local-accounts")
    store.clear()
    check(store.restore(localAccountExists: { _ in true }) == nil,
          "sign-out clears the remembered app session")
    check(defaults.dictionary(forKey: "unrelated-local-accounts")?["buyer@example.com"] as? String == "account-hash",
          "sign-out leaves the local account record intact")

    store.save(local)
    check(store.restore(localAccountExists: { _ in false }) == nil,
          "a removed local account cannot restore a stale signed-in session")

    let guest = AppSessionIdentity(email: "guest", kind: .guest)
    store.save(guest)
    check(store.restore(localAccountExists: { _ in false }) == guest,
          "an explicit guest app session restores without inventing an account")

    let google = AppSessionIdentity(email: "google@example.com", kind: .google)
    store.save(google)
    check(store.restore(localAccountExists: { _ in false }) == google,
          "a completed provider app session restores with its recorded auth kind")
}

@main
enum TradingPersistenceTestMain {
    static func main() {
        testPrivateCredentialStoreRoundTripAndPermissions()
        testKeychainRecoveryIsExplicitAndNonDestructive()
        testPersistedAppSessionRestoreAndScopedSignOut()
        if failures > 0 {
            print("\(failures) focused persistence test(s) failed")
            exit(1)
        }
        print("All focused Trading persistence tests passed")
    }
}
