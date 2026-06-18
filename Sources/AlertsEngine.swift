// Black Label Trading — alerts model + condition evaluation + manager. PURE logic.
// The actual macOS notification POST lives in the SwiftUI layer (Screens2.swift) so this
// engine stays headlessly testable. Alerts evaluate against the user's own watch-symbol
// snapshots (user-entered values) — honest framing, no live feed, nothing fabricated.
import Foundation
import Combine

enum AlertMetric: String, CaseIterable, Identifiable, Codable {
    case last = "Last price"
    case changePct = "% change"
    case relVolume = "Relative volume"
    case rsi = "RSI(14)"
    case volume = "Volume"
    var id: String { rawValue }
    func value(_ s: WatchSymbol) -> Double? {
        switch self {
        case .last: return s.last
        case .changePct: return s.changePct
        case .relVolume: return s.relVolume
        case .rsi: return s.rsi
        case .volume: return s.volume
        }
    }
}

enum AlertOp: String, CaseIterable, Identifiable, Codable {
    case crossesAbove = "crosses above", crossesBelow = "crosses below"
    case above = "is above", below = "is below"
    var id: String { rawValue }
}

// One condition within an alert (multi-condition supported).
struct AlertCondition: Identifiable, Codable, Hashable {
    var id = UUID()
    var metric: AlertMetric
    var op: AlertOp
    var threshold: Double
}

enum AlertCombine: String, Codable, CaseIterable, Identifiable { case all = "ALL", any = "ANY"; var id: String { rawValue } }

struct TradeAlert: Identifiable, Codable, Hashable {
    var id = UUID()
    var symbol: String
    var conditions: [AlertCondition]
    var combine: AlertCombine = .all
    var enabled: Bool = true
    var repeats: Bool = false       // re-arm after firing, else one-shot
    var created = Date()
    var lastFired: Date? = nil
    var fireCount: Int = 0
    var note: String = ""

    var summary: String {
        let parts = conditions.map { "\($0.metric.rawValue) \($0.op.rawValue) \(trim($0.threshold))" }
        return parts.joined(separator: combine == .all ? " AND " : " OR ")
    }
    private func trim(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v) }
}

// The result of evaluating one alert against a previous + current snapshot.
struct AlertFire: Identifiable {
    let id = UUID()
    let alertID: UUID
    let symbol: String
    let message: String
    let at: Date
}

enum AlertEvaluator {
    // Evaluate a single condition. "crosses" needs a previous value (the snapshot before this
    // update); "above"/"below" are level checks. nil current value => never fires (honest).
    static func conditionMet(_ c: AlertCondition, current: WatchSymbol, previous: WatchSymbol?) -> Bool {
        guard let now = c.metric.value(current) else { return false }
        switch c.op {
        case .above: return now > c.threshold
        case .below: return now < c.threshold
        case .crossesAbove:
            guard let prev = previous.flatMap({ c.metric.value($0) }) else { return false }
            return prev <= c.threshold && now > c.threshold
        case .crossesBelow:
            guard let prev = previous.flatMap({ c.metric.value($0) }) else { return false }
            return prev >= c.threshold && now < c.threshold
        }
    }

    // Should this alert fire given a current + previous snapshot? (Ignores enabled/one-shot;
    // the store applies those rules.)
    static func shouldFire(_ a: TradeAlert, current: WatchSymbol, previous: WatchSymbol?) -> Bool {
        guard !a.conditions.isEmpty else { return false }
        let results = a.conditions.map { conditionMet($0, current: current, previous: previous) }
        return a.combine == .all ? results.allSatisfy { $0 } : results.contains { $0 }
    }
}

// Persistent alert store + the snapshot-diff fire loop.
final class AlertStore: ObservableObject {
    @Published var alerts: [TradeAlert] = [] { didSet { save() } }
    @Published private(set) var fireLog: [AlertFire] = []   // session log (not persisted; ephemeral)

    // Hook the SwiftUI layer sets to actually post a macOS notification when an alert fires.
    var onFire: ((TradeAlert, WatchSymbol) -> Void)?

    private let url: URL
    // Last-seen snapshot per symbol, so "crosses" has a previous value across updates.
    private var lastSeen: [String: WatchSymbol] = [:]

    // `baseDir` defaults to the app-support container; tests pass a temp dir.
    init(filename: String = "alerts.json", baseDir: URL? = nil) {
        let base = baseDir ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BlackLabelTrading", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent(filename)
        load()
    }
    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([TradeAlert].self, from: data) else { return }
        alerts = decoded
    }
    private func save() {
        if let data = try? JSONEncoder().encode(alerts) { try? data.write(to: url, options: .atomic) }
    }

    func add(_ a: TradeAlert) { alerts.insert(a, at: 0) }
    func delete(_ id: UUID) { alerts.removeAll { $0.id == id } }
    func toggle(_ id: UUID) { if let i = alerts.firstIndex(where: { $0.id == id }) { alerts[i].enabled.toggle() } }
    func clone(_ id: UUID) {
        guard let a = alerts.first(where: { $0.id == id }) else { return }
        var copy = a; copy.id = UUID(); copy.created = Date(); copy.lastFired = nil; copy.fireCount = 0
        alerts.insert(copy, at: 0)
    }

    var activeCount: Int { alerts.filter { $0.enabled }.count }

    // Feed the latest snapshots (e.g. the whole watchlist). Fires any enabled alert whose
    // condition is newly satisfied vs the previous snapshot, honoring one-shot vs repeat.
    @discardableResult
    func evaluate(_ symbols: [WatchSymbol], now: Date = Date()) -> [AlertFire] {
        var fired: [AlertFire] = []
        let byTicker = Dictionary(symbols.map { ($0.symbol.uppercased(), $0) }) { a, _ in a }
        for idx in alerts.indices {
            let a = alerts[idx]
            guard a.enabled, let cur = byTicker[a.symbol.uppercased()] else { continue }
            let prev = lastSeen[a.symbol.uppercased()]
            if AlertEvaluator.shouldFire(a, current: cur, previous: prev) {
                let fire = AlertFire(alertID: a.id, symbol: a.symbol.uppercased(),
                                     message: "\(a.symbol.uppercased()): \(a.summary)", at: now)
                fired.append(fire)
                alerts[idx].lastFired = now
                alerts[idx].fireCount += 1
                if !a.repeats { alerts[idx].enabled = false }   // one-shot disarms
                onFire?(alerts[idx], cur)
            }
        }
        // Record current as previous for next pass.
        for s in symbols { lastSeen[s.symbol.uppercased()] = s }
        if !fired.isEmpty { fireLog.insert(contentsOf: fired, at: 0); if fireLog.count > 200 { fireLog = Array(fireLog.prefix(200)) } }
        return fired
    }

    func clearLog() { fireLog = [] }
    // Test seam: prime the previous snapshot so "crosses" can be exercised deterministically.
    func _primePrevious(_ symbols: [WatchSymbol]) { for s in symbols { lastSeen[s.symbol.uppercased()] = s } }
}
