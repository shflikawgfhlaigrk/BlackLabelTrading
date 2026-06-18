// Black Label Trading — paper-trade simulator. PURE MATH (no SwiftUI/network).
//
// HONEST FRAMING: this is a PRACTICE blotter. The user opens/closes simulated positions at
// prices THEY enter (or marks-to-market against bars THEY imported). P&L is computed with the
// same honest math as the backtester (points * pointValue - commission). It is NOT a live feed,
// NOT execution, and NOT a track record of real money — it is clearly a simulation the trader
// uses to rehearse and to grade their own discipline. Nothing is fabricated: an empty blotter
// is empty, an open position with no mark shows "no mark", never an invented price.
import Foundation

enum PaperStatus: String, Codable { case open, closed }

// A single simulated position.
struct PaperPosition: Identifiable, Codable, Hashable {
    var id = UUID()
    var symbol: String
    var direction: TradeDirection
    var quantity: Double
    var entryPrice: Double
    var entryDate: Date = Date()
    var stop: Double? = nil           // optional planned stop (for R math + discipline grading)
    var target: Double? = nil         // optional planned target
    var pointValue: Double = 1.0      // $ per point per unit
    var commission: Double = 0.0      // $ round-trip
    var note: String = ""
    var tags: [String] = []
    // Filled on close:
    var status: PaperStatus = .open
    var exitPrice: Double? = nil
    var exitDate: Date? = nil

    // Realized P&L in points (per unit) once closed.
    func realizedPoints() -> Double? {
        guard let x = exitPrice else { return nil }
        return direction == .long ? x - entryPrice : entryPrice - x
    }
    // Realized $ P&L (quantity-scaled, commission applied) once closed.
    func realizedDollars() -> Double? {
        guard let pts = realizedPoints() else { return nil }
        return pts * pointValue * quantity - commission
    }
    // Unrealized P&L at a supplied mark (the user's own current price). nil mark => nil.
    func unrealizedDollars(mark: Double?) -> Double? {
        guard status == .open, let m = mark else { return nil }
        let pts = direction == .long ? m - entryPrice : entryPrice - m
        return pts * pointValue * quantity
    }
    // Planned risk in points (entry→stop). nil if no stop set.
    func plannedRiskPoints() -> Double? {
        guard let s = stop else { return nil }
        return abs(entryPrice - s)
    }
    // Realized R-multiple once closed AND a stop was planned.
    func realizedR() -> Double? {
        guard let pts = realizedPoints(), let risk = plannedRiskPoints(), risk > 0 else { return nil }
        return pts / risk
    }
}

// The simulator: manage open positions, close them, and produce honest stats from CLOSED ones.
final class PaperBook: ObservableObject {
    @Published private(set) var positions: [PaperPosition] = [] { didSet { save() } }
    @Published var startingBalance: Double = 100_000 { didSet { save() } }
    private let url: URL

    init(filename: String = "paperbook.json", baseDir: URL? = nil) {
        let base = baseDir ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BlackLabelTrading", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent(filename); load()
    }

    var open: [PaperPosition] { positions.filter { $0.status == .open } }
    var closed: [PaperPosition] { positions.filter { $0.status == .closed } }

    @discardableResult
    func openPosition(_ p: PaperPosition) -> UUID { var x = p; x.status = .open; positions.insert(x, at: 0); return x.id }

    // Close an open position at the user's exit price. No-op if already closed / not found.
    func close(_ id: UUID, at exit: Double, on date: Date = Date()) {
        guard let i = positions.firstIndex(where: { $0.id == id }), positions[i].status == .open else { return }
        positions[i].exitPrice = exit
        positions[i].exitDate = date
        positions[i].status = .closed
    }
    func delete(_ id: UUID) { positions.removeAll { $0.id == id } }
    func reset() { positions = [] }

    // Realized $ across all closed positions.
    func realizedPnL() -> Double { closed.compactMap { $0.realizedDollars() }.reduce(0, +) }

    // Current simulated equity = starting + realized + unrealized (given user marks per symbol).
    func equity(marks: [String: Double] = [:]) -> Double {
        let unreal = open.compactMap { $0.unrealizedDollars(mark: marks[$0.symbol.uppercased()]) }.reduce(0, +)
        return startingBalance + realizedPnL() + unreal
    }

    // Honest performance stats from CLOSED positions only (open ones are not a record yet).
    func stats() -> [TradeStat] {
        closed.compactMap { p in
            guard let dollars = p.realizedDollars(), let date = p.exitDate else { return nil }
            let holdMin = date.timeIntervalSince(p.entryDate) / 60.0
            return TradeStat(symbol: p.symbol, direction: p.direction, pnl: dollars,
                             r: p.realizedR() ?? 0, date: date, holdMinutes: holdMin, tags: p.tags)
        }
    }

    private func load() {
        guard let d = try? Data(contentsOf: url),
              let box = try? JSONDecoder().decode(Box.self, from: d) else { return }
        positions = box.positions; startingBalance = box.startingBalance
    }
    private func save() {
        if let d = try? JSONEncoder().encode(Box(positions: positions, startingBalance: startingBalance)) {
            try? d.write(to: url, options: .atomic)
        }
    }
    private struct Box: Codable { var positions: [PaperPosition]; var startingBalance: Double }
}
