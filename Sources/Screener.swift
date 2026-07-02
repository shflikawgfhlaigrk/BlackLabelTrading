// Black Label Trading — screener / scanner. PURE logic (no SwiftUI/network).
//
// HONEST FRAMING: runs criteria over the USER'S OWN watch-symbol snapshots (values the user
// entered/imported). No live feed in this build → no symbol is invented. A symbol with a nil
// field cannot satisfy a numeric filter on that field (honest no-data), so the scanner never
// "passes" something on fabricated data. Presets mirror the category's standard signal set.
import Foundation

// The metric a filter targets — maps to a WatchSymbol field.
enum ScreenMetric: String, CaseIterable, Identifiable, Codable {
    case last = "Last price"
    case changePct = "% change"
    case volume = "Volume"
    case relVolume = "Relative volume"
    case rsi = "RSI(14)"
    case atr = "ATR"
    case marketCap = "Market cap"
    case peRatio = "P/E ratio"
    case sma50Rel = "Price vs 50-SMA %"
    case sma200Rel = "Price vs 200-SMA %"
    case high52wRel = "Dist from 52w high %"
    var id: String { rawValue }

    func value(_ s: WatchSymbol) -> Double? {
        switch self {
        case .last: return s.last
        case .changePct: return s.changePct
        case .volume: return s.volume
        case .relVolume: return s.relVolume
        case .rsi: return s.rsi
        case .atr: return s.atr
        case .marketCap: return s.marketCap
        case .peRatio: return s.peRatio
        case .sma50Rel: return s.sma50Rel
        case .sma200Rel: return s.sma200Rel
        case .high52wRel: return s.high52wRel
        }
    }
}

enum ScreenOp: String, CaseIterable, Identifiable, Codable {
    case gt = "greater than", lt = "less than", gte = "≥", lte = "≤", between = "between"
    var id: String { rawValue }
    func test(_ v: Double, _ a: Double, _ b: Double) -> Bool {
        switch self {
        case .gt: return v > a
        case .lt: return v < a
        case .gte: return v >= a
        case .lte: return v <= a
        case .between: return v >= min(a, b) && v <= max(a, b)
        }
    }
}

struct ScreenFilter: Identifiable, Codable, Hashable {
    var id = UUID()
    var metric: ScreenMetric
    var op: ScreenOp
    var a: Double
    var b: Double = 0
    // A symbol passes only if it HAS the metric and the comparison holds (nil never passes).
    func passes(_ s: WatchSymbol) -> Bool {
        guard let v = metric.value(s) else { return false }
        return op.test(v, a, b)
    }
    var summary: String {
        switch op {
        case .between: return "\(metric.rawValue) between \(trim(a)) and \(trim(b))"
        default: return "\(metric.rawValue) \(op.rawValue) \(trim(a))"
        }
    }
    private func trim(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v) }
}

enum ScreenLogic: String, Codable, CaseIterable, Identifiable { case all = "Match ALL", any = "Match ANY"; var id: String { rawValue } }

struct ScreenQuery: Codable {
    var logic: ScreenLogic = .all
    var filters: [ScreenFilter] = []
    var symbolContains: String = ""   // text filter on the ticker

    func matches(_ s: WatchSymbol) -> Bool {
        if !symbolContains.trimmingCharacters(in: .whitespaces).isEmpty,
           !s.symbol.uppercased().contains(symbolContains.uppercased()) { return false }
        guard !filters.isEmpty else { return true }
        switch logic {
        case .all: return filters.allSatisfy { $0.passes(s) }
        case .any: return filters.contains { $0.passes(s) }
        }
    }
}

enum Screener {
    static func run(_ query: ScreenQuery, over symbols: [WatchSymbol]) -> [WatchSymbol] {
        symbols.filter { query.matches($0) }
    }
}

// MARK: - Preset library (mirrors the category's standard scan presets — Finviz "Signals" etc.)
struct ScreenPreset: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    let blurb: String
    let query: ScreenQuery
}

enum ScreenPresets {
    static let all: [ScreenPreset] = [
        ScreenPreset(name: "Top gainers", icon: "arrow.up.right.circle.fill",
                     blurb: "Up more than 3% on the session.",
                     query: ScreenQuery(logic: .all, filters: [ScreenFilter(metric: .changePct, op: .gte, a: 3)])),
        ScreenPreset(name: "Top losers", icon: "arrow.down.right.circle.fill",
                     blurb: "Down more than 3% on the session.",
                     query: ScreenQuery(logic: .all, filters: [ScreenFilter(metric: .changePct, op: .lte, a: -3)])),
        ScreenPreset(name: "Unusual volume", icon: "waveform.path.ecg",
                     blurb: "Relative volume ≥ 2× average.",
                     query: ScreenQuery(logic: .all, filters: [ScreenFilter(metric: .relVolume, op: .gte, a: 2)])),
        ScreenPreset(name: "Oversold (RSI)", icon: "arrow.down.to.line",
                     blurb: "RSI(14) ≤ 30 — stretched to the downside.",
                     query: ScreenQuery(logic: .all, filters: [ScreenFilter(metric: .rsi, op: .lte, a: 30)])),
        ScreenPreset(name: "Overbought (RSI)", icon: "arrow.up.to.line",
                     blurb: "RSI(14) ≥ 70 — stretched to the upside.",
                     query: ScreenQuery(logic: .all, filters: [ScreenFilter(metric: .rsi, op: .gte, a: 70)])),
        ScreenPreset(name: "Above 50 & 200 SMA", icon: "chart.line.uptrend.xyaxis",
                     blurb: "Trading above both moving averages (trend up).",
                     query: ScreenQuery(logic: .all, filters: [
                        ScreenFilter(metric: .sma50Rel, op: .gt, a: 0),
                        ScreenFilter(metric: .sma200Rel, op: .gt, a: 0)])),
        ScreenPreset(name: "Near 52-week high", icon: "flag.checkered",
                     blurb: "Within 3% of the 52-week high.",
                     query: ScreenQuery(logic: .all, filters: [ScreenFilter(metric: .high52wRel, op: .gte, a: -3)])),
        ScreenPreset(name: "Momentum breakouts", icon: "bolt.fill",
                     blurb: "Up ≥ 2% on ≥ 1.5× volume, above the 50-SMA.",
                     query: ScreenQuery(logic: .all, filters: [
                        ScreenFilter(metric: .changePct, op: .gte, a: 2),
                        ScreenFilter(metric: .relVolume, op: .gte, a: 1.5),
                        ScreenFilter(metric: .sma50Rel, op: .gt, a: 0)])),
        ScreenPreset(name: "Value (low P/E)", icon: "dollarsign.circle",
                     blurb: "P/E below 15 — value screen for equities.",
                     query: ScreenQuery(logic: .all, filters: [ScreenFilter(metric: .peRatio, op: .lte, a: 15)]))
    ]
}
