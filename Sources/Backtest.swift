// Black Label Trading — no-code strategy backtester. PURE MATH (no SwiftUI/network).
//
// HONEST FRAMING: the user pastes/imports their OWN historical OHLC bars (CSV) for a symbol.
// The backtest runs a rule set over THOSE bars and reports the full honest metric set
// (profit factor, expectancy, Sharpe, Sortino, SQN, max drawdown, R-distribution, MAE/MFE,
// per-trade list, equity curve). It NEVER fabricates prices or a track record — empty input
// yields an empty result. This is a research tool, not a live feed and not advice.
import Foundation

// One OHLC bar the user supplies.
struct Bar: Identifiable, Codable, Hashable {
    var id = UUID()
    var date: Date
    var open: Double
    var high: Double
    var low: Double
    var close: Double
    var volume: Double = 0
    var delta: Double = 0      // order-flow delta: quote-rule buy vol − sell vol over the bar
}

// CSV import for bars: accepts `date,open,high,low,close[,volume]` with a header row optional.
// Dates: ISO-8601, `yyyy-MM-dd`, or `yyyy-MM-dd HH:mm`. Returns parsed bars (sorted) + a count
// of rows skipped, so the UI can be honest about what imported.
enum BarCSV {
    static func parse(_ text: String) -> (bars: [Bar], skipped: Int) {
        var bars: [Bar] = []; var skipped = 0
        let iso = ISO8601DateFormatter()
        let f1 = DateFormatter(); f1.dateFormat = "yyyy-MM-dd"; f1.locale = Locale(identifier: "en_US_POSIX"); f1.timeZone = TimeZone(identifier: "UTC")
        let f2 = DateFormatter(); f2.dateFormat = "yyyy-MM-dd HH:mm"; f2.locale = Locale(identifier: "en_US_POSIX"); f2.timeZone = TimeZone(identifier: "UTC")
        let f3 = DateFormatter(); f3.dateFormat = "MM/dd/yyyy"; f3.locale = Locale(identifier: "en_US_POSIX"); f3.timeZone = TimeZone(identifier: "UTC")
        func parseDate(_ s: String) -> Date? {
            let t = s.trimmingCharacters(in: .whitespaces)
            return iso.date(from: t) ?? f2.date(from: t) ?? f1.date(from: t) ?? f3.date(from: t)
        }
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let cols = line.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 5 else { skipped += 1; continue }
            guard let d = parseDate(cols[0]),
                  let o = Double(cols[1]), let h = Double(cols[2]),
                  let l = Double(cols[3]), let c = Double(cols[4]) else { skipped += 1; continue }
            let v = cols.count >= 6 ? (Double(cols[5]) ?? 0) : 0
            bars.append(Bar(date: d, open: o, high: h, low: l, close: c, volume: v))
        }
        return (bars.sorted { $0.date < $1.date }, skipped)
    }
}

// MARK: - Indicators over a bar series (close-based). Pure functions.
enum Indicators {
    static func sma(_ closes: [Double], _ period: Int) -> [Double?] {
        guard period > 0 else { return closes.map { _ in nil } }
        var out = [Double?](repeating: nil, count: closes.count)
        guard closes.count >= period else { return out }
        var sum = closes[0..<period].reduce(0, +)
        out[period-1] = sum / Double(period)
        for i in period..<closes.count { sum += closes[i] - closes[i-period]; out[i] = sum / Double(period) }
        return out
    }
    static func ema(_ closes: [Double], _ period: Int) -> [Double?] {
        guard period > 0, !closes.isEmpty else { return closes.map { _ in nil } }
        var out = [Double?](repeating: nil, count: closes.count)
        let k = 2.0 / (Double(period) + 1)
        var prev = closes[0]; out[0] = closes.count >= period ? nil : nil
        for i in 0..<closes.count {
            prev = i == 0 ? closes[0] : closes[i] * k + prev * (1 - k)
            out[i] = i >= period - 1 ? prev : nil
        }
        return out
    }
    // Wilder's RSI.
    static func rsi(_ closes: [Double], _ period: Int = 14) -> [Double?] {
        var out = [Double?](repeating: nil, count: closes.count)
        guard closes.count > period, period > 0 else { return out }
        var gain = 0.0, loss = 0.0
        for i in 1...period { let ch = closes[i] - closes[i-1]; if ch >= 0 { gain += ch } else { loss -= ch } }
        var avgG = gain / Double(period), avgL = loss / Double(period)
        out[period] = avgL == 0 ? 100 : 100 - 100 / (1 + avgG / avgL)
        for i in (period+1)..<closes.count {
            let ch = closes[i] - closes[i-1]
            let g = max(0, ch), l = max(0, -ch)
            avgG = (avgG * Double(period-1) + g) / Double(period)
            avgL = (avgL * Double(period-1) + l) / Double(period)
            out[i] = avgL == 0 ? 100 : 100 - 100 / (1 + avgG / avgL)
        }
        return out
    }
    // True-range based ATR (Wilder smoothing).
    static func atr(_ bars: [Bar], _ period: Int = 14) -> [Double?] {
        var out = [Double?](repeating: nil, count: bars.count)
        guard bars.count > period, period > 0 else { return out }
        var trs: [Double] = []
        for i in 1..<bars.count {
            let h = bars[i].high, l = bars[i].low, pc = bars[i-1].close
            trs.append(max(h - l, max(abs(h - pc), abs(l - pc))))
        }
        // trs[i] corresponds to bars[i+1]
        guard trs.count >= period else { return out }
        var atrPrev = trs[0..<period].reduce(0, +) / Double(period)
        out[period] = atrPrev
        for i in period..<trs.count {
            atrPrev = (atrPrev * Double(period-1) + trs[i]) / Double(period)
            out[i+1] = atrPrev
        }
        return out
    }
}

// MARK: - Strategy definition (user-built, no code)
enum EntryRule: String, CaseIterable, Identifiable, Codable {
    case smaCrossUp = "Fast SMA crosses above slow SMA"
    case smaCrossDown = "Fast SMA crosses below slow SMA"
    case rsiOversold = "RSI crosses up through oversold"
    case rsiOverbought = "RSI crosses down through overbought"
    case breakoutHigh = "Close breaks N-bar high"
    case breakoutLow = "Close breaks N-bar low"
    var id: String { rawValue }
    var isLong: Bool {
        switch self { case .smaCrossUp, .rsiOversold, .breakoutHigh: return true; default: return false }
    }
}

enum ExitRule: String, CaseIterable, Identifiable, Codable {
    case atrStopTarget = "ATR stop + R-multiple target"
    case oppositeSignal = "Exit on opposite entry signal"
    case nBarTimeStop = "Time stop after N bars"
    var id: String { rawValue }
}

struct StrategyConfig: Codable {
    var entry: EntryRule = .smaCrossUp
    var exit: ExitRule = .atrStopTarget
    var fastSMA = 10
    var slowSMA = 30
    var rsiPeriod = 14
    var rsiOversold = 30.0
    var rsiOverbought = 70.0
    var breakoutLookback = 20
    var atrPeriod = 14
    var atrStopMult = 1.5
    var targetR = 2.0            // reward:risk for the target
    var timeStopBars = 10
    var commissionPerTrade = 0.0 // $ per round trip (modeled honestly)
    var slippagePerSide = 0.0    // price units per side
    var pointValue = 1.0         // $ per point (so $ P&L = points * pointValue)
    var initialRiskPoints = 0.0  // 0 = derive from ATR stop; else fixed risk used for R math
}

struct BacktestTrade: Identifiable {
    var id = UUID()
    var entryDate: Date
    var exitDate: Date
    var direction: TradeDirection
    var entry: Double
    var exit: Double
    var stop: Double
    var pnlPoints: Double
    var pnlDollars: Double
    var r: Double
    var mae: Double          // R
    var mfe: Double          // R
    var barsHeld: Int
}

enum Backtester {
    // Run a strategy over user-supplied bars. Long-only or short-only per the entry rule's
    // direction (keeps the honest semantics simple and unambiguous). One position at a time.
    static func run(_ bars: [Bar], _ cfg: StrategyConfig) -> (trades: [BacktestTrade], stats: [TradeStat]) {
        guard bars.count > max(cfg.slowSMA, cfg.atrPeriod, cfg.breakoutLookback, cfg.rsiPeriod) + 2 else { return ([], []) }
        let closes = bars.map { $0.close }
        let fast = Indicators.sma(closes, cfg.fastSMA)
        let slow = Indicators.sma(closes, cfg.slowSMA)
        let rsi = Indicators.rsi(closes, cfg.rsiPeriod)
        let atr = Indicators.atr(bars, cfg.atrPeriod)
        let dir: TradeDirection = cfg.entry.isLong ? .long : .short

        func entrySignal(_ i: Int) -> Bool {
            guard i > 0 else { return false }
            switch cfg.entry {
            case .smaCrossUp:
                guard let f0 = fast[i-1], let s0 = slow[i-1], let f1 = fast[i], let s1 = slow[i] else { return false }
                return f0 <= s0 && f1 > s1
            case .smaCrossDown:
                guard let f0 = fast[i-1], let s0 = slow[i-1], let f1 = fast[i], let s1 = slow[i] else { return false }
                return f0 >= s0 && f1 < s1
            case .rsiOversold:
                guard let r0 = rsi[i-1], let r1 = rsi[i] else { return false }
                return r0 <= cfg.rsiOversold && r1 > cfg.rsiOversold
            case .rsiOverbought:
                guard let r0 = rsi[i-1], let r1 = rsi[i] else { return false }
                return r0 >= cfg.rsiOverbought && r1 < cfg.rsiOverbought
            case .breakoutHigh:
                guard i >= cfg.breakoutLookback else { return false }
                let prior = bars[(i-cfg.breakoutLookback)..<i].map { $0.high }.max() ?? .infinity
                return bars[i].close > prior
            case .breakoutLow:
                guard i >= cfg.breakoutLookback else { return false }
                let prior = bars[(i-cfg.breakoutLookback)..<i].map { $0.low }.min() ?? -.infinity
                return bars[i].close < prior
            }
        }

        var trades: [BacktestTrade] = []
        var i = 1
        let n = bars.count
        while i < n - 1 {
            if entrySignal(i) {
                // Enter at next bar's open (no look-ahead). Apply slippage against us.
                let rawEntry = bars[i+1].open
                let entry = dir == .long ? rawEntry + cfg.slippagePerSide : rawEntry - cfg.slippagePerSide
                let a = atr[i] ?? atr[i+1] ?? (bars[i].high - bars[i].low)
                let stopDist = cfg.initialRiskPoints > 0 ? cfg.initialRiskPoints : max(1e-9, a * cfg.atrStopMult)
                let stop = dir == .long ? entry - stopDist : entry + stopDist
                let target = dir == .long ? entry + stopDist * cfg.targetR : entry - stopDist * cfg.targetR

                var exitPrice = bars[n-1].close
                var exitIdx = n - 1
                var maeR = 0.0, mfeR = 0.0
                var j = i + 1
                while j < n {
                    let b = bars[j]
                    // Track MAE/MFE in R.
                    if dir == .long {
                        maeR = max(maeR, (entry - b.low) / stopDist)
                        mfeR = max(mfeR, (b.high - entry) / stopDist)
                    } else {
                        maeR = max(maeR, (b.high - entry) / stopDist)
                        mfeR = max(mfeR, (entry - b.low) / stopDist)
                    }
                    // Exit logic.
                    switch cfg.exit {
                    case .atrStopTarget:
                        if dir == .long {
                            if b.low <= stop { exitPrice = stop; exitIdx = j; j = n; continue }
                            if b.high >= target { exitPrice = target; exitIdx = j; j = n; continue }
                        } else {
                            if b.high >= stop { exitPrice = stop; exitIdx = j; j = n; continue }
                            if b.low <= target { exitPrice = target; exitIdx = j; j = n; continue }
                        }
                    case .oppositeSignal:
                        // Opposite of the entry direction's signal closes the trade at next open.
                        let opp: Bool = {
                            switch cfg.entry {
                            case .smaCrossUp:
                                guard let f0 = fast[j-1], let s0 = slow[j-1], let f1 = fast[j], let s1 = slow[j] else { return false }
                                return f0 >= s0 && f1 < s1
                            case .smaCrossDown:
                                guard let f0 = fast[j-1], let s0 = slow[j-1], let f1 = fast[j], let s1 = slow[j] else { return false }
                                return f0 <= s0 && f1 > s1
                            default: return false
                            }
                        }()
                        // Always honor the stop even in opposite-signal mode (risk control).
                        if dir == .long, b.low <= stop { exitPrice = stop; exitIdx = j; j = n; continue }
                        if dir == .short, b.high >= stop { exitPrice = stop; exitIdx = j; j = n; continue }
                        if opp { exitPrice = b.close; exitIdx = j; j = n; continue }
                    case .nBarTimeStop:
                        if dir == .long, b.low <= stop { exitPrice = stop; exitIdx = j; j = n; continue }
                        if dir == .short, b.high >= stop { exitPrice = stop; exitIdx = j; j = n; continue }
                        if j - (i + 1) >= cfg.timeStopBars { exitPrice = b.close; exitIdx = j; j = n; continue }
                    }
                    j += 1
                }
                // Apply exit slippage against us.
                let exitFilled = dir == .long ? exitPrice - cfg.slippagePerSide : exitPrice + cfg.slippagePerSide
                let pnlPoints = (dir == .long ? exitFilled - entry : entry - exitFilled)
                let grossDollars = pnlPoints * cfg.pointValue
                let netDollars = grossDollars - cfg.commissionPerTrade
                let r = stopDist > 0 ? pnlPoints / stopDist : 0
                let t = BacktestTrade(entryDate: bars[i+1].date, exitDate: bars[exitIdx].date, direction: dir,
                                      entry: entry, exit: exitFilled, stop: stop,
                                      pnlPoints: pnlPoints, pnlDollars: netDollars, r: r,
                                      mae: maeR, mfe: mfeR, barsHeld: exitIdx - (i + 1))
                trades.append(t)
                i = exitIdx + 1   // flat until the position closes
            } else {
                i += 1
            }
        }
        let stats = trades.map { t in
            TradeStat(symbol: "", direction: t.direction, pnl: t.pnlDollars, r: t.r,
                      date: t.exitDate, holdMinutes: Double(t.barsHeld), mae: t.mae, mfe: t.mfe)
        }
        return (trades, stats)
    }
}
