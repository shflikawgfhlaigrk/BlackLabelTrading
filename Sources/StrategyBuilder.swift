// Black Label Trading — visual strategy builder. PURE MATH (no SwiftUI/network).
//
// HONEST FRAMING: composes user-chosen entry conditions + filters into a strategy that runs
// through the SAME backtester math on the user's OWN imported bars, and can be exported as an
// alertable condition set. It NEVER fabricates prices, signals, or results — empty bars yield
// empty results, and a strategy that triggers nothing says so. The output is research, not a
// track record and not advice.
import Foundation

// MARK: - Indicator operands a condition can reference (all computed from the user's bars).
enum RuleIndicator: String, CaseIterable, Identifiable, Codable {
    case price = "Close"
    case sma = "SMA"
    case ema = "EMA"
    case rsi = "RSI"
    case priorHigh = "Prior N-bar high"
    case priorLow = "Prior N-bar low"
    case macdLine = "MACD line"
    case macdSignal = "MACD signal"
    var id: String { rawValue }
    var needsPeriod: Bool {
        switch self { case .price, .macdLine, .macdSignal: return false; default: return true }
    }
    // Series of this indicator over the bars, with the rule's period.
    func series(_ bars: [Bar], period: Int) -> [Double?] {
        let closes = bars.map { $0.close }
        switch self {
        case .price: return closes.map { Optional($0) }
        case .sma: return Indicators.sma(closes, period)
        case .ema: return Indicators.ema(closes, period)
        case .rsi: return Indicators.rsi(closes, period)
        case .priorHigh:
            var out = [Double?](repeating: nil, count: bars.count)
            for i in bars.indices where i >= period {
                out[i] = bars[(i-period)..<i].map { $0.high }.max()
            }
            return out
        case .priorLow:
            var out = [Double?](repeating: nil, count: bars.count)
            for i in bars.indices where i >= period {
                out[i] = bars[(i-period)..<i].map { $0.low }.min()
            }
            return out
        case .macdLine:  return ChartIndicators.macd(closes).macd
        case .macdSignal: return ChartIndicators.macd(closes).signal
        }
    }
}

enum RuleComparator: String, CaseIterable, Identifiable, Codable {
    case crossesAbove = "crosses above"
    case crossesBelow = "crosses below"
    case isAbove = "is above"
    case isBelow = "is below"
    var id: String { rawValue }
}

// The right-hand operand: either another indicator, or a constant the user types.
enum RuleOperand: Codable, Hashable {
    case indicator(RuleIndicator, period: Int)
    case constant(Double)
}

// One condition: leftIndicator <comparator> rightOperand.
struct RuleCondition: Identifiable, Codable, Hashable {
    var id = UUID()
    var left: RuleIndicator = .sma
    var leftPeriod: Int = 10
    var comparator: RuleComparator = .crossesAbove
    var right: RuleOperand = .indicator(.sma, period: 30)

    var summary: String {
        let l = left.needsPeriod ? "\(left.rawValue)(\(leftPeriod))" : left.rawValue
        let r: String
        switch right {
        case .indicator(let ind, let p): r = ind.needsPeriod ? "\(ind.rawValue)(\(p))" : ind.rawValue
        case .constant(let c): r = c == c.rounded() ? String(Int(c)) : String(format: "%.2f", c)
        }
        return "\(l) \(comparator.rawValue) \(r)"
    }
}

// A full visual strategy: a set of entry conditions (combined ALL/ANY), a direction, and the
// existing exit/risk model reused from StrategyConfig (so the backtester engine is shared).
struct VisualStrategy: Identifiable, Codable {
    var id = UUID()
    var name = "My strategy"
    var direction: TradeDirection = .long
    var combine: AlertCombine = .all
    var entry: [RuleCondition] = []
    var exit: ExitRule = .atrStopTarget
    var atrPeriod = 14
    var atrStopMult = 1.5
    var targetR = 2.0
    var timeStopBars = 10
    var commissionPerTrade = 0.0
    var slippagePerSide = 0.0
    var pointValue = 1.0
    var created = Date()
}

enum VisualStrategyEngine {
    // Evaluate one condition at bar i using precomputed series. "crosses" needs i>0.
    static func met(_ c: RuleCondition, _ bars: [Bar], at i: Int,
                    cache: inout [String: [Double?]]) -> Bool {
        func ser(_ ind: RuleIndicator, _ p: Int) -> [Double?] {
            let key = "\(ind.rawValue)|\(p)"
            if let s = cache[key] { return s }
            let s = ind.series(bars, period: p); cache[key] = s; return s
        }
        let lSeries = ser(c.left, c.leftPeriod)
        guard i < lSeries.count, let lNow = lSeries[i] else { return false }
        // Right-hand value(s).
        func rightValue(_ idx: Int) -> Double? {
            switch c.right {
            case .constant(let v): return v
            case .indicator(let ind, let p):
                let s = ser(ind, p); return idx < s.count ? s[idx] : nil
            }
        }
        guard let rNow = rightValue(i) else { return false }
        switch c.comparator {
        case .isAbove: return lNow > rNow
        case .isBelow: return lNow < rNow
        case .crossesAbove:
            guard i > 0, let lPrev = lSeries[i-1], let rPrev = rightValue(i-1) else { return false }
            return lPrev <= rPrev && lNow > rNow
        case .crossesBelow:
            guard i > 0, let lPrev = lSeries[i-1], let rPrev = rightValue(i-1) else { return false }
            return lPrev >= rPrev && lNow < rNow
        }
    }

    // Whether the strategy's entry fires at bar i (combining conditions ALL/ANY).
    static func entrySignal(_ s: VisualStrategy, _ bars: [Bar], at i: Int,
                            cache: inout [String: [Double?]]) -> Bool {
        guard !s.entry.isEmpty else { return false }
        let results = s.entry.map { met($0, bars, at: i, cache: &cache) }
        return s.combine == .all ? results.allSatisfy { $0 } : results.contains { $0 }
    }

    // Run the visual strategy through the SAME trade-management math as Backtester.run, but
    // driving entries from the composed conditions. Enters at next bar open (no look-ahead),
    // one position at a time, with the existing ATR-stop / target / time-stop / opposite logic.
    static func run(_ bars: [Bar], _ s: VisualStrategy) -> (trades: [BacktestTrade], stats: [TradeStat]) {
        guard bars.count > s.atrPeriod + 2, !s.entry.isEmpty else { return ([], []) }
        var cache: [String: [Double?]] = [:]
        let atr = Indicators.atr(bars, s.atrPeriod)
        let dir = s.direction
        var trades: [BacktestTrade] = []
        let n = bars.count
        var i = 1
        while i < n - 1 {
            if entrySignal(s, bars, at: i, cache: &cache) {
                let rawEntry = bars[i+1].open
                let entry = dir == .long ? rawEntry + s.slippagePerSide : rawEntry - s.slippagePerSide
                let a = atr[i] ?? atr[i+1] ?? (bars[i].high - bars[i].low)
                let stopDist = max(1e-9, a * s.atrStopMult)
                let stop = dir == .long ? entry - stopDist : entry + stopDist
                let target = dir == .long ? entry + stopDist * s.targetR : entry - stopDist * s.targetR
                var exitPrice = bars[n-1].close, exitIdx = n - 1
                var maeR = 0.0, mfeR = 0.0
                var j = i + 1
                while j < n {
                    let b = bars[j]
                    if dir == .long {
                        maeR = max(maeR, (entry - b.low) / stopDist); mfeR = max(mfeR, (b.high - entry) / stopDist)
                    } else {
                        maeR = max(maeR, (b.high - entry) / stopDist); mfeR = max(mfeR, (entry - b.low) / stopDist)
                    }
                    switch s.exit {
                    case .atrStopTarget:
                        if dir == .long {
                            if b.low <= stop { exitPrice = stop; exitIdx = j; j = n; continue }
                            if b.high >= target { exitPrice = target; exitIdx = j; j = n; continue }
                        } else {
                            if b.high >= stop { exitPrice = stop; exitIdx = j; j = n; continue }
                            if b.low <= target { exitPrice = target; exitIdx = j; j = n; continue }
                        }
                    case .oppositeSignal:
                        if dir == .long, b.low <= stop { exitPrice = stop; exitIdx = j; j = n; continue }
                        if dir == .short, b.high >= stop { exitPrice = stop; exitIdx = j; j = n; continue }
                        // Opposite = the entry set no longer holds AND price closed against us.
                        if !entrySignal(s, bars, at: j, cache: &cache) {
                            let against = dir == .long ? b.close < bars[j-1].close : b.close > bars[j-1].close
                            if against { exitPrice = b.close; exitIdx = j; j = n; continue }
                        }
                    case .nBarTimeStop:
                        if dir == .long, b.low <= stop { exitPrice = stop; exitIdx = j; j = n; continue }
                        if dir == .short, b.high >= stop { exitPrice = stop; exitIdx = j; j = n; continue }
                        if j - (i + 1) >= s.timeStopBars { exitPrice = b.close; exitIdx = j; j = n; continue }
                    }
                    j += 1
                }
                let exitFilled = dir == .long ? exitPrice - s.slippagePerSide : exitPrice + s.slippagePerSide
                let pnlPoints = dir == .long ? exitFilled - entry : entry - exitFilled
                let netDollars = pnlPoints * s.pointValue - s.commissionPerTrade
                let r = stopDist > 0 ? pnlPoints / stopDist : 0
                trades.append(BacktestTrade(entryDate: bars[i+1].date, exitDate: bars[exitIdx].date, direction: dir,
                                            entry: entry, exit: exitFilled, stop: stop, pnlPoints: pnlPoints,
                                            pnlDollars: netDollars, r: r, mae: maeR, mfe: mfeR, barsHeld: exitIdx-(i+1)))
                i = exitIdx + 1
            } else { i += 1 }
        }
        let stats = trades.map { t in
            TradeStat(symbol: "", direction: t.direction, pnl: t.pnlDollars, r: t.r,
                      date: t.exitDate, holdMinutes: Double(t.barsHeld), mae: t.mae, mfe: t.mfe)
        }
        return (trades, stats)
    }

    // Bars (by index) at which the entry fires — for chart markers / replay.
    static func entryBars(_ bars: [Bar], _ s: VisualStrategy) -> [Int] {
        guard !s.entry.isEmpty else { return [] }
        var cache: [String: [Double?]] = [:]
        return bars.indices.filter { entrySignal(s, bars, at: $0, cache: &cache) }
    }

    // Export a strategy's entry as an alertable TradeAlert where possible. Only conditions
    // whose operands map onto AlertMetric (last price, RSI) are exportable; the rest are
    // reported as unmappable so the UI stays honest (no silently-dropped logic).
    static func toAlert(_ s: VisualStrategy, symbol: String) -> (alert: TradeAlert?, unmappable: [String]) {
        var conds: [AlertCondition] = []
        var unmappable: [String] = []
        func metric(for ind: RuleIndicator) -> AlertMetric? {
            switch ind { case .price: return .last; case .rsi: return .rsi; default: return nil }
        }
        func op(for c: RuleComparator) -> AlertOp {
            switch c {
            case .crossesAbove: return .crossesAbove; case .crossesBelow: return .crossesBelow
            case .isAbove: return .above; case .isBelow: return .below
            }
        }
        for c in s.entry {
            guard let m = metric(for: c.left), case .constant(let thresh) = c.right else {
                unmappable.append(c.summary); continue
            }
            conds.append(AlertCondition(metric: m, op: op(for: c.comparator), threshold: thresh))
        }
        guard !conds.isEmpty else { return (nil, unmappable) }
        let alert = TradeAlert(symbol: symbol, conditions: conds,
                               combine: s.combine, enabled: true, repeats: true,
                               note: "From strategy: \(s.name)")
        return (alert, unmappable)
    }
}

// Persists the user's saved visual strategies (own data only; ships empty).
final class StrategyStore: ObservableObject {
    @Published var strategies: [VisualStrategy] = [] { didSet { save() } }
    private let url: URL
    init(filename: String = "strategies.json", baseDir: URL? = nil) {
        let base = baseDir ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BlackLabelTrading", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent(filename); load()
    }
    func add(_ s: VisualStrategy) { strategies.insert(s, at: 0) }
    func update(_ s: VisualStrategy) { if let i = strategies.firstIndex(where: { $0.id == s.id }) { strategies[i] = s } }
    func delete(_ id: UUID) { strategies.removeAll { $0.id == id } }
    private func load() {
        guard let d = try? Data(contentsOf: url), let box = try? JSONDecoder().decode([VisualStrategy].self, from: d) else { return }
        strategies = box
    }
    private func save() { if let d = try? JSONEncoder().encode(strategies) { try? d.write(to: url, options: .atomic) } }
}
