// Black Label Trading — prompt-free active credential storage + explicit legacy recovery.
//
// Active credentials live in an atomic, owner-only file under Application Support. Unlike a
// legacy login-keychain ACL, that location does not bind access to one exact signed executable, so
// rebuilding or updating the app cannot cause a recurring macOS password prompt. Existing Keychain
// items are never deleted or read automatically. A Keychain read is available only through the
// explicitly named foreground recovery operation invoked by a buyer-facing button.
import CryptoKit
import Foundation
import Security

struct TradingSecretStore {
    let rootURL: URL

    static var live: TradingSecretStore {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return TradingSecretStore(rootURL: appSupport
            .appendingPathComponent("Black Label Trading", isDirectory: true)
            .appendingPathComponent("credentials-v1", isDirectory: true))
    }

    func fileURL(service: String, account: String) -> URL {
        let identity = Data((service + "\u{0}" + account).utf8)
        let digest = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        return rootURL.appendingPathComponent(digest + ".secret", isDirectory: false)
    }

    @discardableResult
    func write(_ data: Data, service: String, account: String) -> Bool {
        guard !data.isEmpty, prepareDirectory() else { return false }
        let url = fileURL(service: service, account: account)
        if let type = try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType,
           type == .typeSymbolicLink {
            return false
        }
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = url
            try? mutableURL.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }

    func read(service: String, account: String) -> Data? {
        let url = fileURL(service: service, account: account)
        guard isRegularCredentialFile(url) else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// Presence is based only on file metadata; it never reads credential bytes.
    func contains(service: String, account: String) -> Bool {
        isRegularCredentialFile(fileURL(service: service, account: account))
    }

    /// Removes the active private-file copy only. Preserved Keychain items are out of scope.
    @discardableResult
    func remove(service: String, account: String) -> Bool {
        let url = fileURL(service: service, account: account)
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        guard isRegularCredentialFile(url) else { return false }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    private func prepareDirectory() -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: rootURL.path) {
            guard let attrs = try? fm.attributesOfItem(atPath: rootURL.path),
                  attrs[.type] as? FileAttributeType == .typeDirectory else { return false }
        } else {
            do {
                try fm.createDirectory(at: rootURL, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
            } catch {
                return false
            }
        }
        do {
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
            return true
        } catch {
            return false
        }
    }

    private func isRegularCredentialFile(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular else { return false }
        return true
    }
}

/// Separates prompt-free active storage from the one explicit, foreground Keychain recovery path.
final class TradingCredentialRepository {
    typealias LegacyReader = ([String: Any]) -> Data?

    private let activeStore: TradingSecretStore
    private let legacyReader: LegacyReader

    init(activeStore: TradingSecretStore, legacyReader: @escaping LegacyReader) {
        self.activeStore = activeStore
        self.legacyReader = legacyReader
    }

    @discardableResult
    func saveActive(_ base: [String: Any], data: Data) -> Bool {
        guard let id = identity(base) else { return false }
        return activeStore.write(data, service: id.service, account: id.account)
    }

    func loadActive(_ base: [String: Any]) -> Data? {
        guard let id = identity(base) else { return nil }
        return activeStore.read(service: id.service, account: id.account)
    }

    func hasActive(_ base: [String: Any]) -> Bool {
        guard let id = identity(base) else { return false }
        return activeStore.contains(service: id.service, account: id.account)
    }

    @discardableResult
    func removeActive(_ base: [String: Any]) -> Bool {
        guard let id = identity(base) else { return false }
        return activeStore.remove(service: id.service, account: id.account)
    }

    /// Must be called only from an explicit foreground user action. The source item remains intact.
    @discardableResult
    func recoverExistingKeychainItem(_ base: [String: Any]) -> Bool {
        guard let data = legacyReader(base), !data.isEmpty else { return false }
        return saveActive(base, data: data)
    }

    private func identity(_ base: [String: Any]) -> (service: String, account: String)? {
        guard let service = base[kSecAttrService as String] as? String, !service.isEmpty,
              let account = base[kSecAttrAccount as String] as? String, !account.isEmpty else {
            return nil
        }
        return (service, account)
    }
}

enum TradingKeychain {
    private static let repository = TradingCredentialRepository(activeStore: .live) {
        readExistingKeychainItem($0)
    }

    @discardableResult
    static func set(_ base: [String: Any], data: Data) -> Bool {
        repository.saveActive(base, data: data)
    }

    /// Reads the prompt-free active file only. There is deliberately no automatic Keychain fallback.
    static func copy(_ base: [String: Any]) -> Data? {
        repository.loadActive(base)
    }

    /// Metadata-only active-file probe for startup and passive UI rendering.
    static func contains(_ base: [String: Any]) -> Bool {
        repository.hasActive(base)
    }

    /// Removes the active file only; existing Keychain records are preserved for explicit recovery.
    static func delete(_ base: [String: Any]) {
        repository.removeActive(base)
    }

    /// The only real-Keychain read in Trading. Call only from a foreground button action.
    @discardableResult
    static func recoverExistingKeychainItem(_ base: [String: Any]) -> Bool {
        repository.recoverExistingKeychainItem(base)
    }

    private static func readExistingKeychainItem(_ base: [String: Any]) -> Data? {
        func copy(_ query: [String: Any]) -> Data? {
            var q = query
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
            return out as? Data
        }

        var dataProtection = base
        dataProtection[kSecUseDataProtectionKeychain as String] = true
        return copy(dataProtection) ?? copy(base)
    }
}
