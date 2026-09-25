import Foundation

enum AppSessionKind: String, Codable {
    case local
    case guest
    case apple
    case google
}

struct AppSessionIdentity: Codable, Equatable {
    let email: String
    let kind: AppSessionKind
}

/// Persists only the app's local UI session identity. It is not a provider access token and is not
/// presented as live provider authorization. Provider sign-in is required again after sign-out.
struct AppSessionStore {
    static let key = "com.blacklabel.trading.appSession.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(_ identity: AppSessionIdentity) {
        let normalized = normalize(identity)
        guard isStructurallyValid(normalized),
              let data = try? JSONEncoder().encode(normalized) else {
            clear()
            return
        }
        defaults.set(data, forKey: Self.key)
    }

    func restore(localAccountExists: (String) -> Bool) -> AppSessionIdentity? {
        guard let data = defaults.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode(AppSessionIdentity.self, from: data) else {
            if defaults.object(forKey: Self.key) != nil { clear() }
            return nil
        }
        let identity = normalize(decoded)
        guard isStructurallyValid(identity) else { clear(); return nil }
        if identity.kind == .local && !localAccountExists(identity.email) {
            clear()
            return nil
        }
        return identity
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }

    private func normalize(_ identity: AppSessionIdentity) -> AppSessionIdentity {
        let email = identity.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return AppSessionIdentity(email: email, kind: identity.kind)
    }

    private func isStructurallyValid(_ identity: AppSessionIdentity) -> Bool {
        guard !identity.email.isEmpty else { return false }
        switch identity.kind {
        case .local:
            return identity.email.contains("@") && identity.email.contains(".")
        case .guest:
            return identity.email == "guest"
        case .apple, .google:
            return identity.email != "guest"
        }
    }
}
