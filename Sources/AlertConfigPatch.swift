import Foundation

// Status endpoints redact credentials and query parameters. Never write that
// display value back unless the buyer actually edits it. Blank secret inputs
// mean keep the saved value; the status API deliberately cannot round-trip them.
enum AlertConfigPatch {
    static func make(enabled: Bool, provider: String, endpoint: String?,
                     pushoverToken: String, pushoverUser: String) -> [String: Any] {
        var patch: [String: Any] = ["alertEnabled": enabled, "alertProvider": provider]
        if let endpoint {
            patch["alertEndpoint"] = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for (key, value) in [("alertPushoverToken", pushoverToken), ("alertPushoverUser", pushoverUser)] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { patch[key] = trimmed }
        }
        return patch
    }
}
