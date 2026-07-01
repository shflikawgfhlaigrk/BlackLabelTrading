// Black Label Trading — pattern auto-detection. PURE MATH (no SwiftUI/network).
//
// HONEST FRAMING: every detection here runs ONLY on the bars the user imported (the same
// OHLC CSV the backtester/chart eat). Nothing is downloaded, sampled, or invented. Empty
// bars -> empty output. A detected pattern is a geometric fact about the user's bars, NOT a
// prediction or a track record. The UI must present these as observations the trader confirms,
// never as signals with implied edge.
import Foundation

// MARK: - Candlestick patterns (single / two-bar)
enum CandlePattern: String, CaseIterable, Identifiable, Codable {
    case bullishEngulfing = "Bullish engulfing"
    case bearishEngulfing = "Bearish engulfing"
    case hammer = "Hammer"
    case shootingStar = "Shooting star"
    case doji = "Doji"
    case bullishMarubozu = "Bullish marubozu"
    case bearishMarubozu = "Bearish marubozu"
    case insideBar = "Inside bar"
    var id: String { rawValue }
    // Directional bias of the *shape* (not a forecast): bullish reversal/continuation = +1,
    // bearish = -1, neutral (doji/inside) = 0.
    var bias: Int {
        switch self {
        case .bullishEngulfing, .hammer, .bullishMarubozu: return 1
        case .bearishEngulfing, .shootingStar, .bearishMarubozu: return -1
        case .doji, .insideBar: return 0
        }
    }
    var icon: String {
        switch self {
        case .bullishEngulfing, .bullishMarubozu, .hammer: return "arrow.up.right.circle.fill"
        case .bearishEngulfing, .bearishMarubozu, .shootingStar: return "arrow.down.right.circle.fill"
        case .doji: return "plus.circle"
        case .insideBar: return "rectangle.compress.vertical"
        }
    }
}

// A pattern occurrence located at a specific bar index in the user's series.
struct PatternHit: Identifiable, Hashable {
    var id = UUID()
    let index: Int               // bar index where the pattern completes
    let date: Date
    let candle: CandlePattern?   // set for candlestick hits
    let chart: ChartPattern?     // set for chart-structure hits
    let label: String
    let bias: Int                // +1 bullish, -1 bearish, 0 neutral
}

enum CandleScan {
    // Tunables exposed so the UI can let a buyer tailor sensitivity (no magic constants buried).
    struct Params {
        var dojiBodyFrac = 0.1        // body <= 10% of range => doji
        var hammerWickFrac = 2.0      // lower wick >= 2x body
        var hammerOppFrac = 0.3       // upper wick <= 30% of range
        var marubozuWickFrac = 0.05   // wicks <= 5% of range each
    }

    // Geometry helpers on one bar.
    private static func body(_ b: Bar) -> Double { abs(b.close - b.open) }
    private static func range(_ b: Bar) -> Double { max(1e-12, b.high - b.low) }
    private static func upperWick(_ b: Bar) -> Double { b.high - max(b.open, b.close) }
    private static func lowerWick(_ b: Bar) -> Double { min(b.open, b.close) - b.low }

    static func isDoji(_ b: Bar, _ p: Params = Params()) -> Bool {
        body(b) <= p.dojiBodyFrac * range(b)
    }
    static func isHammer(_ b: Bar, _ p: Params = Params()) -> Bool {
        let bd = body(b); guard bd > 0 else { return false }
        return lowerWick(b) >= p.hammerWickFrac * bd && upperWick(b) <= p.hammerOppFrac * range(b)
    }
    static func isShootingStar(_ b: Bar, _ p: Params = Params()) -> Bool {
        let bd = body(b); guard bd > 0 else { return false }
        return upperWick(b) >= p.hammerWickFrac * bd && lowerWick(b) <= p.hammerOppFrac * range(b)
    }
    static func isBullishMarubozu(_ b: Bar, _ p: Params = Params()) -> Bool {
        b.close > b.open && upperWick(b) <= p.marubozuWickFrac * range(b) && lowerWick(b) <= p.marubozuWickFrac * range(b)
    }
    static func isBearishMarubozu(_ b: Bar, _ p: Params = Params()) -> Bool {
        b.close < b.open && upperWick(b) <= p.marubozuWickFrac * range(b) && lowerWick(b) <= p.marubozuWickFrac * range(b)
    }
    // Two-bar engulfing: current real body fully engulfs the prior real body, opposite color.
    static func isBullishEngulfing(_ prev: Bar, _ cur: Bar) -> Bool {
        prev.close < prev.open && cur.close > cur.open &&
        cur.close >= prev.open && cur.open <= prev.close
    }
    static func isBearishEngulfing(_ prev: Bar, _ cur: Bar) -> Bool {
        prev.close > prev.open && cur.close < cur.open &&
        cur.open >= prev.close && cur.close <= prev.open
    }
    static func isInsideBar(_ prev: Bar, _ cur: Bar) -> Bool {
        cur.high <= prev.high && cur.low >= prev.low && range(cur) < range(prev)
    }

    // Scan the whole series. One bar may carry multiple hits (e.g. doji + inside).
    static func scan(_ bars: [Bar], _ p: Params = Params()) -> [PatternHit] {
        var hits: [PatternHit] = []
        for i in bars.indices {
            let b = bars[i]
            func add(_ cp: CandlePattern) {
                hits.append(PatternHit(index: i, date: b.date, candle: cp, chart: nil, label: cp.rawValue, bias: cp.bias))
            }
            // single-bar
            if isBullishMarubozu(b, p) { add(.bullishMarubozu) }
            else if isBearishMarubozu(b, p) { add(.bearishMarubozu) }
            if isHammer(b, p) { add(.hammer) }
            if isShootingStar(b, p) { add(.shootingStar) }
            if isDoji(b, p) { add(.doji) }
            // two-bar
            if i > 0 {
                let prev = bars[i-1]
                if isBullishEngulfing(prev, b) { add(.bullishEngulfing) }
                if isBearishEngulfing(prev, b) { add(.bearishEngulfing) }
                if isInsideBar(prev, b) { add(.insideBar) }
            }
        }
        return hits
    }
}

// MARK: - Chart-structure patterns (pivots, S/R, double top/bottom, triangle/flag)
enum ChartPattern: String, CaseIterable, Identifiable, Codable {
    case support = "Support"
    case resistance = "Resistance"
    case doubleTop = "Double top"
    case doubleBottom = "Double bottom"
    case ascendingTriangle = "Ascending triangle"
    case descendingTriangle = "Descending triangle"
    case symmetricalTriangle = "Symmetrical triangle"
    case bullFlag = "Bull flag"
    case bearFlag = "Bear flag"
    var id: String { rawValue }
    var bias: Int {
        switch self {
        case .support, .doubleBottom, .ascendingTriangle, .bullFlag: return 1
        case .resistance, .doubleTop, .descendingTriangle, .bearFlag: return -1
        case .symmetricalTriangle: return 0
        }
    }
}

// A swing pivot (local extreme) used to build structure.
struct Pivot: Identifiable, Hashable {
    var id = UUID()
    let index: Int
    let price: Double
    let isHigh: Bool
}

enum StructureScan {
    // Fractal pivots: a bar is a swing high if its high is the max over ±`lookback` bars
    // (strictly greater than neighbors on each side). Symmetric for swing lows.
    static func pivots(_ bars: [Bar], lookback: Int = 3) -> [Pivot] {
        guard lookback > 0, bars.count > lookback * 2 else { return [] }
        var out: [Pivot] = []
        for i in lookback..<(bars.count - lookback) {
            let h = bars[i].high, l = bars[i].low
            var isHigh = true, isLow = true
            for j in (i-lookback)...(i+lookback) where j != i {
                if bars[j].high >= h { isHigh = false }
                if bars[j].low <= l { isLow = false }
            }
            if isHigh { out.append(Pivot(index: i, price: h, isHigh: true)) }
            if isLow { out.append(Pivot(index: i, price: l, isHigh: false)) }
        }
        return out.sorted { $0.index < $1.index }
    }

    // Horizontal S/R: cluster pivot prices that fall within `tolFrac` of each other and were
    // touched >= `minTouches` times. Returns one level per cluster (price = mean of touches).
    struct Level: Identifiable, Hashable {
        var id = UUID(); let price: Double; let touches: Int; let isSupport: Bool
    }
    static func levels(_ bars: [Bar], lookback: Int = 3, tolFrac: Double = 0.004, minTouches: Int = 2) -> [Level] {
        let pv = pivots(bars, lookback: lookback)
        guard !pv.isEmpty else { return [] }
        var levels: [Level] = []
        func cluster(_ pts: [Pivot], support: Bool) {
            var used = [Bool](repeating: false, count: pts.count)
            for i in pts.indices where !used[i] {
                var group = [pts[i].price]; used[i] = true
                for j in pts.indices where !used[j] {
                    if abs(pts[j].price - pts[i].price) <= tolFrac * pts[i].price { group.append(pts[j].price); used[j] = true }
                }
                if group.count >= minTouches {
                    levels.append(Level(price: group.reduce(0,+)/Double(group.count), touches: group.count, isSupport: support))
                }
            }
        }
        cluster(pv.filter { !$0.isHigh }, support: true)
        cluster(pv.filter { $0.isHigh }, support: false)
        return levels.sorted { $0.touches > $1.touches }
    }

    // Double top/bottom: two swing highs (lows) at a similar price separated by a meaningful
    // pullback. Reports a hit at the second peak/trough.
    static func doubleTopsBottoms(_ bars: [Bar], lookback: Int = 3, tolFrac: Double = 0.01,
                                  minBarGap: Int = 3, minPullbackFrac: Double = 0.03) -> [PatternHit] {
        let pv = pivots(bars, lookback: lookback)
        var hits: [PatternHit] = []
        let highs = pv.filter { $0.isHigh }, lows = pv.filter { !$0.isHigh }
        func pairs(_ pts: [Pivot], top: Bool) {
            guard pts.count >= 2 else { return }
            for k in 1..<pts.count {
                let a = pts[k-1], b = pts[k]
                guard abs(a.price - b.price) <= tolFrac * a.price else { continue }   // similar price
                guard b.index - a.index >= minBarGap else { continue }                 // separated peaks
                // Require a MEANINGFUL counter-move between the two peaks (the documented pullback),
                // not just two similar prices — else any flat drift fabricates a double top/bottom.
                let lo = a.index, hi = b.index
                guard hi > lo, hi < bars.count else { continue }
                let between = bars[lo...hi]
                let pullback: Double = top
                    ? (a.price - (between.map { $0.low }.min() ?? a.price)) / a.price    // deepest dip
                    : ((between.map { $0.high }.max() ?? a.price) - a.price) / a.price    // tallest bounce
                guard pullback >= minPullbackFrac else { continue }
                let cp: ChartPattern = top ? .doubleTop : .doubleBottom
                hits.append(PatternHit(index: b.index, date: bars[b.index].date, candle: nil, chart: cp, label: cp.rawValue, bias: cp.bias))
            }
        }
        pairs(highs, top: true); pairs(lows, top: false)
        return hits
    }

    // Linear regression slope of a price series (per-index). Used for trendline direction.
    static func slope(_ ys: [Double]) -> Double {
        let n = Double(ys.count); guard n > 1 else { return 0 }
        let xs = (0..<ys.count).map(Double.init)
        let mx = xs.reduce(0,+)/n, my = ys.reduce(0,+)/n
        var num = 0.0, den = 0.0
        for i in ys.indices { num += (xs[i]-mx)*(ys[i]-my); den += (xs[i]-mx)*(xs[i]-mx) }
        return den == 0 ? 0 : num/den
    }

    // Triangle detection over the most-recent window: compare slope of pivot-highs vs
    // pivot-lows. Converging highs+lows = symmetrical; flat highs + rising lows = ascending; etc.
    static func triangle(_ bars: [Bar], lookback: Int = 3, window: Int = 40, flatFrac: Double = 0.0008) -> PatternHit? {
        guard bars.count >= window else { return nil }
        let start = bars.count - window
        let recent = Array(bars[start...])
        let pv = pivots(recent, lookback: lookback)
        let highs = pv.filter { $0.isHigh }, lows = pv.filter { !$0.isHigh }
        guard highs.count >= 2, lows.count >= 2 else { return nil }
        let avgPx = recent.map(\.close).reduce(0,+)/Double(recent.count)
        let flat = flatFrac * avgPx
        let hs = slope(highs.map(\.price)), ls = slope(lows.map(\.price))
        let lastIdx = bars.count - 1
        func hit(_ cp: ChartPattern) -> PatternHit {
            PatternHit(index: lastIdx, date: bars[lastIdx].date, candle: nil, chart: cp, label: cp.rawValue, bias: cp.bias)
        }
        let highsFlat = abs(hs) <= flat, lowsFlat = abs(ls) <= flat
        if highsFlat && ls > flat { return hit(.ascendingTriangle) }
        if lowsFlat && hs < -flat { return hit(.descendingTriangle) }
        if hs < -flat && ls > flat { return hit(.symmetricalTriangle) }
        return nil
    }

    // Flag: a strong directional impulse (pole) followed by a shallow counter-trend drift.
    static func flag(_ bars: [Bar], pole: Int = 8, flagLen: Int = 6, poleFrac: Double = 0.03) -> PatternHit? {
        guard bars.count >= pole + flagLen else { return nil }
        let n = bars.count
        let flagStart = n - flagLen
        let poleStart = flagStart - pole
        let poleMove = bars[flagStart-1].close - bars[poleStart].close
        let avgPx = bars[poleStart].close
        guard avgPx > 0 else { return nil }
        let poleRet = poleMove / avgPx
        let flagSlope = slope(Array(bars[flagStart...]).map(\.close))
        let last = n - 1
        // Bull flag: strong up pole, flag drifts flat/down.
        if poleRet >= poleFrac && flagSlope <= 0 {
            return PatternHit(index: last, date: bars[last].date, candle: nil, chart: .bullFlag, label: ChartPattern.bullFlag.rawValue, bias: 1)
        }
        if poleRet <= -poleFrac && flagSlope >= 0 {
            return PatternHit(index: last, date: bars[last].date, candle: nil, chart: .bearFlag, label: ChartPattern.bearFlag.rawValue, bias: -1)
        }
        return nil
    }
}

// MARK: - Unified scanner the UI calls. Aggregates candlestick + structure + most-recent
// triangle/flag into one chronologically-ordered hit list (newest last). Pure; ships empty.
enum PatternScanner {
    struct Summary {
        var hits: [PatternHit]
        var levels: [StructureScan.Level]
        var bullish: Int { hits.filter { $0.bias > 0 }.count }
        var bearish: Int { hits.filter { $0.bias < 0 }.count }
        var neutral: Int { hits.filter { $0.bias == 0 }.count }
    }
    static func scan(_ bars: [Bar],
                     candleParams: CandleScan.Params = CandleScan.Params(),
                     pivotLookback: Int = 3) -> Summary {
        guard !bars.isEmpty else { return Summary(hits: [], levels: []) }
        var hits = CandleScan.scan(bars, candleParams)
        hits += StructureScan.doubleTopsBottoms(bars, lookback: pivotLookback)
        if let t = StructureScan.triangle(bars, lookback: pivotLookback) { hits.append(t) }
        if let f = StructureScan.flag(bars) { hits.append(f) }
        hits.sort { $0.index < $1.index }
        let levels = StructureScan.levels(bars, lookback: pivotLookback)
        return Summary(hits: hits, levels: levels)
    }
}
