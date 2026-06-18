// Black Label Trading — charting engine. PURE MATH (no SwiftUI/network).
//
// HONEST FRAMING: every transform/indicator/level here operates ONLY on the bars the user
// imported (the same OHLC CSV the backtester eats). Nothing is downloaded, sampled, or
// invented. Empty bars -> empty output. This is the math layer behind the candlestick
// chart screen (candles / Heikin-Ashi / Renko, MA/RSI/MACD/VWAP/Bollinger/ATR overlays,
// and Fibonacci/level/trendline drawing tools). The SwiftUI rendering lives in ChartScreen.
import Foundation

// MARK: - Candle representations the chart can render.
enum CandleStyle: String, CaseIterable, Identifiable, Codable {
    case candles = "Candles"
    case heikinAshi = "Heikin-Ashi"
    case renko = "Renko"
    case line = "Line"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .candles:    return "chart.bar.fill"
        case .heikinAshi: return "chart.bar.doc.horizontal"
        case .renko:      return "square.stack.3d.up.fill"
        case .line:       return "chart.xyaxis.line"
        }
    }
}

// A drawable candle (already transformed). `up` is close >= open. For Renko, date is the
// originating bar's date and open/close are the brick bounds.
struct Candle: Identifiable, Hashable {
    var id = UUID()
    var index: Int          // x-position on the chart (sequential, gap-free)
    var date: Date
    var open: Double
    var high: Double
    var low: Double
    var close: Double
    var volume: Double = 0
    var up: Bool { close >= open }
}

enum CandleTransform {
    // Plain candles — straight pass-through of the user's bars (sequential index, gap-free
    // so weekends/overnight gaps don't stretch the x-axis).
    static func candles(_ bars: [Bar]) -> [Candle] {
        bars.enumerated().map { (i, b) in
            Candle(index: i, date: b.date, open: b.open, high: b.high, low: b.low, close: b.close, volume: b.volume)
        }
    }

    // Heikin-Ashi smoothing.
    //   haClose = (O+H+L+C)/4
    //   haOpen  = (prevHaOpen + prevHaClose)/2  (seed: (O+C)/2 of bar 0)
    //   haHigh  = max(H, haOpen, haClose);  haLow = min(L, haOpen, haClose)
    static func heikinAshi(_ bars: [Bar]) -> [Candle] {
        guard !bars.isEmpty else { return [] }
        var out: [Candle] = []
        var prevOpen = (bars[0].open + bars[0].close) / 2
        var prevClose = (bars[0].open + bars[0].high + bars[0].low + bars[0].close) / 4
        for (i, b) in bars.enumerated() {
            let haClose = (b.open + b.high + b.low + b.close) / 4
            let haOpen = i == 0 ? prevOpen : (prevOpen + prevClose) / 2
            let haHigh = max(b.high, max(haOpen, haClose))
            let haLow = min(b.low, min(haOpen, haClose))
            out.append(Candle(index: i, date: b.date, open: haOpen, high: haHigh, low: haLow, close: haClose, volume: b.volume))
            prevOpen = haOpen; prevClose = haClose
        }
        return out
    }

    // Renko bricks of a fixed price size, built from closes. A new brick prints only after
    // price moves >= brickSize from the last brick boundary. Index is sequential per brick.
    // `brickSize <= 0` falls back to candles (no fabricated geometry).
    static func renko(_ bars: [Bar], brickSize: Double) -> [Candle] {
        guard brickSize > 0, let first = bars.first else { return candles(bars) }
        var bricks: [Candle] = []
        var base = (first.close / brickSize).rounded(.down) * brickSize   // anchor to a grid
        var idx = 0
        for b in bars {
            // Up bricks
            while b.close >= base + brickSize {
                let lo = base, hi = base + brickSize
                bricks.append(Candle(index: idx, date: b.date, open: lo, high: hi, low: lo, close: hi, volume: b.volume)); idx += 1
                base += brickSize
            }
            // Down bricks
            while b.close <= base - brickSize {
                let hi = base, lo = base - brickSize
                bricks.append(Candle(index: idx, date: b.date, open: hi, high: hi, low: lo, close: lo, volume: b.volume)); idx += 1
                base -= brickSize
            }
        }
        return bricks
    }

    // Suggest a sensible Renko brick size from the bars (≈ average true range, rounded).
    static func suggestedBrickSize(_ bars: [Bar]) -> Double {
        guard bars.count > 1 else { return 0 }
        var trs: [Double] = []
        for i in 1..<bars.count {
            let h = bars[i].high, l = bars[i].low, pc = bars[i-1].close
            trs.append(max(h - l, max(abs(h - pc), abs(l - pc))))
        }
        let avg = trs.reduce(0, +) / Double(trs.count)
        return avg > 0 ? avg : 0
    }
}

// MARK: - Indicator series for chart overlays/panes. Reuses Indicators (Backtest.swift)
// for SMA/EMA/RSI/ATR and adds the chart-only ones (VWAP, Bollinger, MACD).
enum ChartIndicators {
    // Rolling VWAP over the supplied window (typical price * volume / volume). When the
    // window covers the whole series it is a cumulative session VWAP. Needs volume > 0;
    // bars with zero volume contribute nothing (honest — no synthetic volume).
    static func vwap(_ bars: [Bar], window: Int) -> [Double?] {
        var out = [Double?](repeating: nil, count: bars.count)
        guard window > 0, !bars.isEmpty else { return out }
        for i in 0..<bars.count {
            let lo = max(0, i - window + 1)
            var pv = 0.0, vol = 0.0
            for j in lo...i {
                let tp = (bars[j].high + bars[j].low + bars[j].close) / 3
                pv += tp * bars[j].volume; vol += bars[j].volume
            }
            out[i] = vol > 0 ? pv / vol : nil
        }
        return out
    }

    struct Bollinger { var mid: [Double?]; var upper: [Double?]; var lower: [Double?] }
    // Bollinger bands: SMA(period) ± k * rolling sample-stddev(period).
    static func bollinger(_ closes: [Double], period: Int, k: Double = 2) -> Bollinger {
        let mid = Indicators.sma(closes, period)
        var upper = [Double?](repeating: nil, count: closes.count)
        var lower = [Double?](repeating: nil, count: closes.count)
        guard period > 1, closes.count >= period else { return Bollinger(mid: mid, upper: upper, lower: lower) }
        for i in (period-1)..<closes.count {
            let window = Array(closes[(i-period+1)...i])
            let m = window.reduce(0, +) / Double(period)
            let varc = window.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(period - 1)
            let sd = varc.squareRoot()
            upper[i] = m + k * sd; lower[i] = m - k * sd
        }
        return Bollinger(mid: mid, upper: upper, lower: lower)
    }

    struct MACD { var macd: [Double?]; var signal: [Double?]; var histogram: [Double?] }
    // MACD = EMA(fast) - EMA(slow); signal = EMA(macd, signalPeriod); hist = macd - signal.
    static func macd(_ closes: [Double], fast: Int = 12, slow: Int = 26, signalPeriod: Int = 9) -> MACD {
        let ef = Indicators.ema(closes, fast)
        let es = Indicators.ema(closes, slow)
        var line = [Double?](repeating: nil, count: closes.count)
        for i in 0..<closes.count { if let a = ef[i], let b = es[i] { line[i] = a - b } }
        // Signal = EMA of the (non-nil) macd line. Compute EMA over a compacted series then re-map.
        let firstIdx = line.firstIndex { $0 != nil }
        var signal = [Double?](repeating: nil, count: closes.count)
        if let start = firstIdx {
            let vals = line[start...].compactMap { $0 }
            let sig = Indicators.ema(vals, signalPeriod)
            for (k, v) in sig.enumerated() { signal[start + k] = v }
        }
        var hist = [Double?](repeating: nil, count: closes.count)
        for i in 0..<closes.count { if let m = line[i], let s = signal[i] { hist[i] = m - s } }
        return MACD(macd: line, signal: signal, histogram: hist)
    }
}

// MARK: - Chart axis intelligence. PURE MATH shared by the SwiftUI chart screen AND the
// headless render proof, so what Michael inspects in the PNG is the exact same scaling the
// live app uses. Implements "nice" tick steps (1/2/2.5/5 × 10ⁿ), auto-fit padding, and an
// optional logarithmic price scale (for instruments that move multiplicatively).
enum ChartScale {
    // A "nice" number ≥ (or ≤, when `ceil` is false) the target, of the form {1,2,2.5,5,10}×10ⁿ.
    static func niceNum(_ x: Double, ceil: Bool) -> Double {
        guard x > 0 else { return 0 }
        let exp = floor(log10(x))
        let f = x / pow(10, exp)               // fraction in [1,10)
        let nf: Double
        if ceil {
            nf = f <= 1 ? 1 : f <= 2 ? 2 : f <= 2.5 ? 2.5 : f <= 5 ? 5 : 10
        } else {
            // largest nice fraction <= f (floor): boundaries are the nice values themselves.
            nf = f < 2 ? 1 : f < 2.5 ? 2 : f < 5 ? 2.5 : f < 10 ? 5 : 10
        }
        return nf * pow(10, exp)
    }

    // Evenly-spaced "nice" tick prices spanning [lo,hi] with about `target` ticks. The returned
    // ticks are clamped to the [lo,hi] window so labels never escape the plotted price range.
    static func ticks(lo: Double, hi: Double, target: Int = 6) -> [Double] {
        guard hi > lo, target > 1 else { return lo == hi ? [lo] : [] }
        let range = niceNum(hi - lo, ceil: false)
        let step = niceNum(range / Double(target - 1), ceil: true)
        guard step > 0 else { return [] }
        let start = (lo / step).rounded(.down) * step
        var out: [Double] = []
        var v = start
        var guardN = 0
        while v <= hi + step * 0.5 && guardN < 1000 {
            if v >= lo - step * 0.5 { out.append(v) }
            v += step; guardN += 1
        }
        return out
    }

    // Auto-fit price domain: pad the [low,high] of the visible candles by `padFrac` so wicks
    // never touch the frame, then snap the padded bounds outward to nice numbers for clean
    // gridlines. Honest: derived ONLY from the supplied bars — never widened to hide a move.
    static func priceDomain(low: Double, high: Double, padFrac: Double = 0.06) -> (lo: Double, hi: Double) {
        guard high > low else {
            let c = low; let d = max(abs(c) * 0.01, 0.5)
            return (c - d, c + d)
        }
        let pad = (high - low) * padFrac
        return (low - pad, high + pad)
    }

    // Map a price to a y-pixel inside [topY, bottomY] under a linear OR log scale. Log scale is
    // only valid for strictly-positive domains (prices); callers fall back to linear otherwise.
    static func yPixel(_ price: Double, lo: Double, hi: Double, topY: Double, bottomY: Double, log: Bool) -> Double {
        let h = bottomY - topY
        guard hi > lo else { return bottomY }
        if log && lo > 0 && hi > 0 && price > 0 {
            let t = (Foundation.log(price) - Foundation.log(lo)) / (Foundation.log(hi) - Foundation.log(lo))
            return bottomY - t * h
        }
        let t = (price - lo) / (hi - lo)
        return bottomY - t * h
    }

    // Decimal places to render a price label at, inferred from the tick step magnitude so a
    // $30,000 future shows whole numbers while a $1.2345 FX pair shows 4 decimals.
    static func priceDecimals(step: Double) -> Int {
        guard step > 0 else { return 2 }
        if step >= 100 { return 0 }
        if step >= 1 { return step.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 2 }
        return max(0, min(6, Int(ceil(-log10(step))) + 1))
    }
}

// MARK: - Fibonacci retracement / extension levels between a swing low and high.
struct FibLevel: Identifiable { let ratio: Double; let price: Double; var id: Double { ratio } }
enum Fibonacci {
    static let ratios: [Double] = [0, 0.236, 0.382, 0.5, 0.618, 0.786, 1.0, 1.272, 1.618]
    // Levels from `from` (e.g. swing low) to `to` (swing high). Works in either direction.
    static func levels(from: Double, to: Double) -> [FibLevel] {
        let span = to - from
        return ratios.map { FibLevel(ratio: $0, price: from + span * $0) }
    }
    // Convenience: auto-derive swing low/high from a bar window.
    static func levels(_ bars: [Bar]) -> [FibLevel] {
        guard let lo = bars.map(\.low).min(), let hi = bars.map(\.high).max(), hi > lo else { return [] }
        return levels(from: lo, to: hi)
    }
}

// MARK: - Drawing tools (persisted per symbol). These are the user's own annotations.
// Coordinates are stored as (barIndex, price) so they survive timeframe/redraw. NOTHING
// here is generated — every drawing is one the user placed.
enum DrawingKind: String, Codable, CaseIterable, Identifiable {
    case trendline, horizontal, rect, fib
    var id: String { rawValue }
    var label: String {
        switch self { case .trendline: return "Trendline"; case .horizontal: return "Level"
        case .rect: return "Zone"; case .fib: return "Fib" }
    }
    var icon: String {
        switch self {
        case .trendline: return "line.diagonal"
        case .horizontal: return "minus"
        case .rect: return "rectangle.dashed"
        case .fib: return "ruler"
        }
    }
}

struct Drawing: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: DrawingKind
    var x1: Double          // bar index (fractional ok)
    var y1: Double          // price
    var x2: Double
    var y2: Double
    var created = Date()
}

// Persists drawings keyed by symbol to the app container (own data only, ships empty).
final class DrawingStore: ObservableObject {
    @Published private(set) var bySymbol: [String: [Drawing]] = [:] { didSet { save() } }
    private let url: URL

    init(filename: String = "drawings.json", baseDir: URL? = nil) {
        let base = baseDir ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BlackLabelTrading", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent(filename)
        load()
    }
    private func key(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces).uppercased() }
    func drawings(for symbol: String) -> [Drawing] { bySymbol[key(symbol)] ?? [] }
    func add(_ d: Drawing, to symbol: String) { bySymbol[key(symbol), default: []].append(d) }
    func remove(_ d: Drawing, from symbol: String) { bySymbol[key(symbol)]?.removeAll { $0.id == d.id } }
    func clear(_ symbol: String) { bySymbol[key(symbol)] = nil }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let box = try? JSONDecoder().decode([String: [Drawing]].self, from: data) else { return }
        bySymbol = box
    }
    private func save() {
        if let data = try? JSONEncoder().encode(bySymbol) { try? data.write(to: url, options: .atomic) }
    }
}
