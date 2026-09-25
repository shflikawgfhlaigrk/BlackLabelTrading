// Black Label Trading — shared disk rules for every local JSON store (journal, paper book,
// strategies, watchlists, alerts, drawings). Two invariants protect user data:
//   1. an unreadable/corrupt store file is renamed aside — never silently ignored — so the next
//      save() can NEVER atomically overwrite the only recoverable copy of the user's data;
//   2. writes report success (each store's lastSaveOK), so "Saved." confirmations reflect the
//      real outcome instead of asserting it.
// Pure Foundation — compiled by both the app target and the headless test lane.
import Foundation

enum StoreDisk {
    /// Move a store file that exists but cannot be decoded aside as a timestamped .bak sidecar.
    /// Best-effort: on rename failure the original is left in place (a later save may still
    /// fail, but we never delete the evidence). Returns the backup URL when the rename landed.
    @discardableResult
    static func quarantine(_ url: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyyMMdd-HHmmss"
        let bak = url.appendingPathExtension("corrupt-\(df.string(from: Date())).bak")
        do { try FileManager.default.moveItem(at: url, to: bak); return bak } catch { return nil }
    }
}
