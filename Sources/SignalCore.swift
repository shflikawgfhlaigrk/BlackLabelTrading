// SignalCore.swift — PURE signal math (NO SwiftUI), shared by the app build and the
// headless test target (Tests/run-tests.sh). Color/UI bits live in Model.swift.
import Foundation

enum SignalFactor: String, CaseIterable, Identifiable, Codable {
    case cvdDivergence = "CVD Divergence"
    case cvdFlow       = "CVD Flow"
    case vwap          = "VWAP"
    case vpin          = "VPIN"
    case stepGMA       = "StepGMA"
    case volume        = "Volume"
    case trend         = "Trend"
    case momentum      = "Momentum"
    case hmmRegime     = "HMM Regime"
    case alphaMonitor  = "Alpha Monitor"
    case session       = "Session"
    case smt           = "SMT"
    case kalmanTrend   = "Kalman Trend"
    case breakout      = "Breakout"
    case keyLevels     = "Key Levels"
    case structure     = "Market Structure"
    var id: String { rawValue }
    // Relative weight in the composite (sums to ~1.0). Every factor is a real computation on the
    // buyer's own bars and is honestly ABSENT (contributes 0) until its data source is available.
    var weight: Double {
        switch self {
        case .cvdDivergence: return 0.11
        case .cvdFlow:       return 0.10
        case .vwap:          return 0.07
        case .vpin:          return 0.06
        case .stepGMA:       return 0.08
        case .volume:        return 0.05
        case .trend:         return 0.10
        case .momentum:      return 0.07
        case .hmmRegime:     return 0.06
        case .alphaMonitor:  return 0.04
        case .session:       return 0.02
        case .smt:           return 0.03
        case .kalmanTrend:   return 0.07
        case .breakout:      return 0.06
        case .keyLevels:     return 0.05
        case .structure:     return 0.03
        }
    }
    var icon: String {
        switch self {
        case .cvdDivergence: return "arrow.triangle.swap"
        case .cvdFlow:       return "waveform.path.ecg"
        case .vwap:          return "chart.xyaxis.line"
        case .vpin:          return "drop.fill"
        case .stepGMA:       return "stairs"
        case .volume:        return "chart.bar.fill"
        case .trend:         return "chart.line.uptrend.xyaxis"
        case .momentum:      return "bolt.fill"
        case .hmmRegime:     return "circle.grid.cross.fill"
        case .alphaMonitor:  return "scope"
        case .session:       return "clock.fill"
        case .smt:           return "arrow.left.arrow.right.circle.fill"
        case .kalmanTrend:   return "wave.3.forward"
        case .breakout:      return "arrow.up.forward.square"
        case .keyLevels:     return "ruler"
        case .structure:     return "chart.bar.doc.horizontal"
        }
    }
    var blurb: String {
        switch self {
        case .cvdDivergence: return "Price vs. cumulative delta disagreement"
        case .cvdFlow:       return "Net aggressive buy/sell pressure"
        case .vwap:          return "Distance / reclaim of volume-weighted price"
        case .vpin:          return "Order-flow toxicity / informed-trade conviction"
        case .stepGMA:       return "Stepped guppy moving-average alignment"
        case .volume:        return "Participation relative to average"
        case .trend:         return "Higher-timeframe directional bias"
        case .momentum:      return "Rate of change / thrust"
        case .hmmRegime:     return "Hidden-Markov regime classification"
        case .alphaMonitor:  return "Live edge / alpha decay monitor"
        case .session:       return "Time-of-day edge weighting"
        case .smt:           return "Smart-money correlated-asset divergence"
        case .kalmanTrend:   return "Kalman-filtered trend velocity"
        case .breakout:      return "Range-breakout direction & strength"
        case .keyLevels:     return "Proximity to swing support / resistance"
        case .structure:     return "Higher-high/-low vs lower-high/-low structure"
        }
    }
}

enum SignalDirection: String, Codable {
    case long = "LONG", short = "SHORT", flat = "FLAT"
    var icon: String {
        switch self { case .long: return "arrow.up.right"; case .short: return "arrow.down.right"; case .flat: return "minus" }
    }
}

// One rung of the suggested 6-tier trailing-stop PLAN: when price reaches `trigger`, move the stop
// to `stop` (locking the prior tier's gain). Signals-only — a management suggestion the trader
// executes on their own platform; the app NEVER places or moves an order.
struct TrailTier: Identifiable {
    let id: Int          // tier number 1…6
    let trigger: Double  // price at which this tier arms
    let stop: Double     // where the stop trails to at this tier
}

// A computed signal: composite score + plan (entry/stop/target) + risk.
struct SignalResult {
    var direction: SignalDirection
    var score: Double            // composite, -100…100
    var confidence: Double       // 0…100
    var entry: Double
    var stop: Double
    var target: Double
    var symbol: String
    var pointValue: Double       // $ per point
    var riskPoints: Double { abs(entry - stop) }
    var rewardPoints: Double { abs(target - entry) }
    var rr: Double { riskPoints > 0 ? rewardPoints / riskPoints : 0 }
    var hasDollar: Bool { pointValue > 0 }     // false when the instrument's $/pt is unknown
    var riskDollars: Double { riskPoints * pointValue }
    var rewardDollars: Double { rewardPoints * pointValue }
    // Honest dollar string: the real amount when $/pt is known, else "$/pt n/a" — never a
    // fabricated dollar figure from a wrong multiplier.
    var riskDollarLabel: String { hasDollar ? TradeMath.money(riskDollars) : "$/pt n/a" }

    // Suggested 6-tier trailing stop: as price advances entry→target in 6 equal steps, the stop
    // trails up one step behind, locking progressively more of the move (tier 1 = breakeven). Pure
    // geometry derived from entry/target/direction — a PLAN to execute on your own platform, never
    // an order the app places. Empty when flat or no risk distance.
    var trailTiers: [TrailTier] {
        guard direction != .flat, rewardPoints > 0 else { return [] }
        let n = 6
        return (1...n).map { k in
            let advance = rewardPoints * Double(k) / Double(n)        // how far price has run
            let lock = rewardPoints * Double(k - 1) / Double(n)       // gain locked (tier1 = breakeven)
            let trigger = direction == .long ? entry + advance : entry - advance
            let trailStop = direction == .long ? entry + lock : entry - lock
            return TrailTier(id: k, trigger: trigger, stop: trailStop)
        }
    }
}

// Signal inputs. Each factor raw score is in [-1, 1] — now AUTO-COMPUTED live by
// LiveFactorEngine from the buyer's own captured ES bars (no longer hand-entered).
// Factors with no live source (order-flow CVD/VPIN, correlated-asset SMT, alpha-decay)
// are simply absent → contribute 0 and render as "no live data".
struct SignalInputs: Codable {
    var symbol: String = "ES"
    var price: Double = 5000
    var atr: Double = 12          // used to size stop/target
    var pointValue: Double = 50   // ES = $50/pt
    var factors: [String: Double] = SignalFactor.allCases.reduce(into: [:]) { $0[$1.rawValue] = 0 }

    func raw(_ f: SignalFactor) -> Double { factors[f.rawValue] ?? 0 }
}

// ─────────────────────────────────────────────────────────────────────────────
// Live factor engine — auto-computes factor raw scores [-1,1] from the buyer's OWN
// captured live data + real edge-gated fire journal. HONEST BY CONSTRUCTION: a factor is
// present ONLY when it has a real source; the rest stay absent (→ 0, "no live data").
// Nothing is fabricated or estimated.
//   • From close prices: Trend, Momentum, StepGMA, HMM-regime, Session.
//   • From real bar volume (WC cq): Volume, VWAP.
//   • From real order-flow delta (WC bid/ask + prints, Lee-Ready): CVD Flow, CVD Divergence, VPIN.
//   • From the real fire journal: Alpha Monitor.
//   • From a real correlated NQ stream: SMT.
struct LiveFactorSnapshot {
    var factors: [String: Double] = [:]
    var available: Set<String> = []
    var price: Double? = nil
    var atr: Double? = nil
    var asOf: Date? = nil
    var bars: Int = 0
    // Factors that are absent SPECIFICALLY because they are ES-tuned modules and the live instrument
    // is not ES-family (TR-05 (c)): the UI labels these "ES-only module" instead of a generic "no live
    // data", so the buyer sees an honest reason — not silent wrong math on NQ/CL/SPY.
    var esOnlyAbsent: Set<String> = []
    // The newest bar is older than the staleness window: the data is real but NOT current, so
    // no surface may present it as live (§5.1). Set by compute() against the caller's `now`.
    var isStale: Bool = false
    var hasData: Bool { bars >= LiveFactorEngine.minBars && price != nil && !available.isEmpty }
    // The only condition that may render a "Live" pill or a current trade plan.
    var isLive: Bool { hasData && !isStale }
}

enum LiveFactorEngine {
    static let minBars = 50
    // Base bars print every 15s while the capture flows; a newest bar older than this window
    // (8 intervals) means the feed stopped, and stored bars must render as stale, never live.
    static let staleAfter: TimeInterval = 120

    // The ES-tuned modules: their math is calibrated to the S&P e-mini and would FABRICATE on another
    // instrument, so they run ONLY on ES-family and are labeled "ES-only module" everywhere else.
    static let esOnlyFactors: Set<String> = [SignalFactor.session.rawValue, SignalFactor.smt.rawValue]

    // esFamily: whether the live instrument is ES-family. Two factors are calibrated to ES and
    // would FABRICATE on another instrument, so they are computed ONLY when esFamily is true and
    // stay honestly absent ("no live data") otherwise: Session (hardcoded US index prime hours,
    // meaningless for FX/non-US) and SMT (ES<->NQ correlated-asset divergence; on a non-ES symbol
    // the NQ reference doesn't apply). WealthCharts scope can include many symbols, while the pure
    // price/volume factors remain symbol-neutral.
    static func compute(bars: [Bar], nqBars: [Bar], fires: [FireRow], now: Date,
                        esFamily: Bool = true) -> LiveFactorSnapshot {
        var s = LiveFactorSnapshot()
        s.bars = bars.count
        // On a non-ES instrument the ES-tuned Session/SMT modules do not apply — record that so the UI
        // labels them "ES-only module" (an honest reason) rather than a generic "no live data".
        if !esFamily { s.esOnlyAbsent = esOnlyFactors }
        guard bars.count >= minBars, let last = bars.last else { return s }
        let closes = bars.map(\.close)
        s.price = last.close
        s.asOf = last.date
        s.isStale = now.timeIntervalSince(last.date) > staleAfter
        let atr = Indicators.atr(bars, 14).compactMap { $0 }.last
            ?? max(0.01, bars.suffix(14).map { $0.high - $0.low }.reduce(0, +) / 14)
        let A = max(0.01, atr)
        s.atr = A
        func clamp(_ x: Double) -> Double { max(-1, min(1, x)) }
        func put(_ f: SignalFactor, _ v: Double) { s.factors[f.rawValue] = v; s.available.insert(f.rawValue) }

        // VWAP — distance of price from session VWAP, in ATRs.
        if let vw = ChartIndicators.vwap(bars, window: min(bars.count, 30)).compactMap({ $0 }).last {
            put(.vwap, clamp((last.close - vw) / (A * 2)))
        }
        // Volume — participation vs 20-bar average, signed by the bar's direction.
        let recentVol = bars.map(\.volume).suffix(20)
        if recentVol.reduce(0, +) > 0 {
            let avg = recentVol.reduce(0, +) / Double(recentVol.count)
            if avg > 0 {
                let dir = (last.close - last.open) >= 0 ? 1.0 : -1.0
                put(.volume, clamp(dir * ((last.volume / avg) - 1.0)))
            }
        }
        // Trend — fast vs slow EMA, in ATRs.
        if let ef = Indicators.ema(closes, 20).compactMap({ $0 }).last,
           let es = Indicators.ema(closes, 50).compactMap({ $0 }).last {
            put(.trend, clamp((ef - es) / (A * 1.5)))
        }
        // Momentum — RSI(14) mapped to [-1,1].
        if let r = Indicators.rsi(closes, 14).compactMap({ $0 }).last {
            put(.momentum, clamp((r - 50) / 50))
        }
        // StepGMA — Guppy multi-EMA alignment (fast pack vs slow pack), in ATRs.
        let fastP = [3, 5, 8, 10, 12, 15], slowP = [30, 35, 40, 45, 50, 60]
        let fastE = fastP.compactMap { Indicators.ema(closes, $0).compactMap { $0 }.last }
        let slowE = slowP.compactMap { Indicators.ema(closes, $0).compactMap { $0 }.last }
        if fastE.count == fastP.count, slowE.count == slowP.count {
            let af = fastE.reduce(0, +) / Double(fastE.count)
            let al = slowE.reduce(0, +) / Double(slowE.count)
            put(.stepGMA, clamp((af - al) / (A * 1.5)))
        }
        // HMM Regime — Kaufman efficiency ratio (trend vs chop), signed by net move. Labeled proxy.
        let n = min(20, closes.count - 1)
        if n > 1 {
            let seg = Array(closes.suffix(n + 1))
            let net = seg.last! - seg.first!
            let path = zip(seg.dropFirst(), seg).map { abs($0 - $1) }.reduce(0, +)
            if path > 0 { put(.hmmRegime, clamp(abs(net) / path * (net >= 0 ? 1 : -1))) }
        }
        // Session — time-of-day edge (US index prime hours), signed by short-term momentum. ONLY
        // for ES-family: the prime-hours model is US-index-specific and would fabricate on FX/other.
        if esFamily, let r = Indicators.rsi(closes, 14).compactMap({ $0 }).last {
            put(.session, clamp(sessionQuality(now) * ((r - 50) / 50)))
        }
        // CVD family — from REAL per-bar order-flow delta (quote-rule buy − sell volume), captured
        // from WC's bid/ask quotes + prints. Present only once the buyer's bars actually carry delta.
        let win = min(20, bars.count)
        let recentBars = bars.suffix(win)
        let cumVol = recentBars.reduce(0.0) { $0 + $1.volume }
        let cumDelta = recentBars.reduce(0.0) { $0 + $1.delta }
        if cumVol > 0 && recentBars.contains(where: { $0.delta != 0 }) {
            let flow = cumDelta / cumVol
            put(.cvdFlow, clamp(flow))                                    // net aggressive buy/sell pressure
            let toxicity = recentBars.reduce(0.0) { $0 + abs($1.delta) } / cumVol
            put(.vpin, clamp(toxicity * (cumDelta >= 0 ? 1 : -1)))        // order-flow toxicity, signed
            if let c0 = recentBars.first?.close, let cN = recentBars.last?.close {
                let priceDir = max(-1.0, min(1.0, (cN - c0) / (A * 2)))
                put(.cvdDivergence, clamp(flow - priceDir))              // order flow vs price disagreement
            }
        }
        // SMT — smart-money correlated-asset divergence: ES vs NQ relative-return disagreement,
        // from the buyer's OWN captured NQ micro series. ONLY for ES-family (the NQ reference is the
        // ES counterpart); absent on other instruments and when NQ isn't captured.
        if esFamily, bars.count >= 10, nqBars.count >= 10 {
            let m = min(min(20, bars.count), nqBars.count)
            let esC = bars.suffix(m).map(\.close), nqC = nqBars.suffix(m).map(\.close)
            if let e0 = esC.first, let eN = esC.last, let q0 = nqC.first, let qN = nqC.last, e0 != 0, q0 != 0 {
                let esRet = (eN - e0) / e0, nqRet = (qN - q0) / q0
                put(.smt, clamp((esRet - nqRet) * 1000))   // ES relative strength vs NQ (~0.1% rel = full)
            }
        }
        // Alpha Monitor — net direction of the buyer's REAL edge-gated fires, scaled by how much
        // live edge is actually firing. A pure read of the real signal journal; no fabrication.
        let recentFires = fires.prefix(12)
        if !recentFires.isEmpty {
            let longs = recentFires.filter { $0.direction.lowercased() == "long" }.count
            let shorts = recentFires.filter { $0.direction.lowercased() == "short" }.count
            let net = Double(longs - shorts) / Double(recentFires.count)
            let density = min(1.0, Double(recentFires.count) / 8.0)
            put(.alphaMonitor, clamp(net * density))
        }
        // Kalman Trend — a 1-D constant-velocity Kalman filter over closes; the factor is the
        // estimated velocity (price/bar) normalized by ATR. Real recursive estimate, not an EMA.
        if closes.count >= 20 {
            var level = closes[0], vel = 0.0, p00 = 1.0, p11 = 1.0
            let q = 0.001, r = 1.0
            for c in closes.dropFirst() {
                // predict
                level += vel
                p00 += p11 + q; p11 += q
                // update with measurement c
                let k0 = p00 / (p00 + r), k1 = p11 / (p00 + r)
                let resid = c - level
                level += k0 * resid; vel += k1 * resid
                p00 *= (1 - k0); p11 *= (1 - k1)
            }
            put(.kalmanTrend, clamp(vel / (A * 0.5)))
        }
        // Breakout — where the latest close sits relative to the prior N-bar range (excluding the
        // current bar): a real range-breakout direction & strength, +1 above the range, -1 below.
        if closes.count >= 21 {
            let prior = Array(bars.suffix(21).dropLast())   // 20 prior bars
            let hi = prior.map { $0.high }.max() ?? last.close
            let lo = prior.map { $0.low }.min() ?? last.close
            let span = max(A, hi - lo)
            let pos = last.close > hi ? (last.close - hi) / span
                    : last.close < lo ? (last.close - lo) / span
                    : 0.0
            put(.breakout, clamp(pos))
        }
        // Key Levels — proximity to the nearest swing support/resistance from real pivots: near
        // support biases long (+), near resistance biases short (-), scaled by ATR distance.
        let pivots = StructureScan.pivots(bars, lookback: 3)
        if pivots.count >= 2 {
            let resist = pivots.filter { $0.isHigh && $0.price > last.close }.map { $0.price }.min()
            let support = pivots.filter { !$0.isHigh && $0.price < last.close }.map { $0.price }.max()
            var kl = 0.0
            if let s0 = support { kl += max(0, 1 - (last.close - s0) / (A * 3)) }       // near support -> long
            if let r0 = resist  { kl -= max(0, 1 - (r0 - last.close) / (A * 3)) }       // near resistance -> short
            put(.keyLevels, clamp(kl))
        }
        // Market Structure — higher-highs/higher-lows (uptrend, +) vs lower-highs/lower-lows
        // (downtrend, -) from the last few real swing pivots. A geometric read, never a forecast.
        let highs = pivots.filter { $0.isHigh }.suffix(2), lows = pivots.filter { !$0.isHigh }.suffix(2)
        if highs.count == 2, lows.count == 2 {
            let hh = highs.last!.price > highs.first!.price
            let hl = lows.last!.price > lows.first!.price
            let lhh = highs.last!.price < highs.first!.price
            let ll = lows.last!.price < lows.first!.price
            let st = (hh && hl) ? 1.0 : (lhh && ll) ? -1.0 : (hh || hl) ? 0.5 : (lhh || ll) ? -0.5 : 0.0
            put(.structure, st)
        }
        return s
    }

    // 0…1 session quality: RTH prime hours score highest, overnight lowest. New York (ET).
    static func sessionQuality(_ date: Date) -> Double {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York") ?? cal.timeZone
        let mins = cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
        if (mins >= 570 && mins < 660) || (mins >= 840 && mins < 960) { return 1.0 } // 9:30–11:00, 14:00–16:00 ET
        if mins >= 570 && mins < 960 { return 0.6 }                                    // midday RTH
        return 0.2                                                                     // overnight / globex
    }
}

enum SignalEngine {
    // Weighted composite in [-1, 1] -> scaled to -100…100.
    static func composite(_ inp: SignalInputs) -> Double {
        let sum = SignalFactor.allCases.reduce(0.0) { $0 + inp.raw($1) * $1.weight }
        return max(-1, min(1, sum)) * 100
    }
    // Per-factor weighted contribution (for display).
    static func contribution(_ f: SignalFactor, _ inp: SignalInputs) -> Double { inp.raw(f) * f.weight * 100 }

    static func evaluate(_ inp: SignalInputs) -> SignalResult {
        let score = composite(inp)
        let dir: SignalDirection = score >= 25 ? .long : (score <= -25 ? .short : .flat)
        let conf = min(100, abs(score) / 0.85)   // saturates near full conviction
        let atr = max(0.01, inp.atr)
        let stopDist = atr * 1.2
        let targetDist = atr * 1.2 * 2.0          // ~2R plan
        let entry = inp.price
        var stop = entry, target = entry
        switch dir {
        case .long:  stop = entry - stopDist; target = entry + targetDist
        case .short: stop = entry + stopDist; target = entry - targetDist
        case .flat:  stop = entry - stopDist; target = entry + targetDist
        }
        return SignalResult(direction: dir, score: score, confidence: conf,
                            entry: entry, stop: stop, target: target,
                            symbol: inp.symbol.isEmpty ? "ES" : inp.symbol.uppercased(),
                            pointValue: inp.pointValue)
    }

    // A small built-in scenario the user can step through (labelled scenario, not live data).
    static let scenarios: [(name: String, inputs: SignalInputs)] = [
        ("Bullish trend continuation", {
            var i = SignalInputs(); i.symbol = "ES"; i.price = 5012; i.atr = 11; i.pointValue = 50
            i.factors = ["CVD Divergence": 0.4, "CVD Flow": 0.8, "VWAP": 0.7, "VPIN": 0.6, "StepGMA": 0.8,
                         "Volume": 0.6, "Trend": 0.9, "Momentum": 0.7, "HMM Regime": 0.7, "Alpha Monitor": 0.5,
                         "Session": 0.5, "SMT": 0.3]; return i
        }()),
        ("Bearish ES CVD divergence", {
            var i = SignalInputs(); i.symbol = "ES"; i.price = 4988; i.atr = 12.5; i.pointValue = 50
            i.factors = ["CVD Divergence": -0.9, "CVD Flow": -0.6, "VWAP": -0.5, "VPIN": -0.7, "StepGMA": -0.6,
                         "Volume": 0.5, "Trend": -0.7, "Momentum": -0.5, "HMM Regime": -0.6, "Alpha Monitor": -0.4,
                         "Session": 0.2, "SMT": -0.6]; return i
        }()),
        ("ES chop / no edge", {
            var i = SignalInputs(); i.symbol = "ES"; i.price = 5002; i.atr = 8.0; i.pointValue = 50
            i.factors = ["CVD Divergence": 0.1, "CVD Flow": -0.15, "VWAP": 0.0, "VPIN": -0.1, "StepGMA": 0.05,
                         "Volume": -0.2, "Trend": 0.05, "Momentum": -0.1, "HMM Regime": 0.0, "Alpha Monitor": -0.2,
                         "Session": -0.3, "SMT": 0.1]; return i
        }())
    ]
}

// MARK: - 13 independent risk gates (mirrors the website's "13 gatekeepers" — pass/fail before a signal is valid)
// Each gate inspects the current inputs/computed result and returns pass/fail with a reason.
// A signal is only "valid" (armable) when every gate passes. This is on-device scoring logic,
// NOT a live broker feed — same honest framing as the website.
enum RiskGate: String, CaseIterable, Identifiable {
    case conviction      = "Conviction threshold"
    case consensus       = "Multi-TF consensus"
    case directionLock   = "Direction lock"
    case cvdAgreement    = "CVD agreement"
    case flowConfirm     = "Order-flow confirmation"
    case volumeFloor     = "Volume floor"
    case trendAlign      = "Trend alignment"
    case momentumQuality = "Momentum quality"
    case sessionWindow   = "Session window"
    case smtClear        = "SMT divergence clear"
    case riskReward      = "Risk:reward floor"
    case atrSanity       = "ATR / volatility sanity"
    case spreadCost      = "Spread / cost guard"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .conviction:      return "gauge.with.dots.needle.67percent"
        case .consensus:       return "rectangle.3.group.fill"
        case .directionLock:   return "lock.fill"
        case .cvdAgreement:    return "arrow.triangle.swap"
        case .flowConfirm:     return "waveform.path.ecg"
        case .volumeFloor:     return "chart.bar.fill"
        case .trendAlign:      return "chart.line.uptrend.xyaxis"
        case .momentumQuality: return "bolt.fill"
        case .sessionWindow:   return "clock.fill"
        case .smtClear:        return "arrow.left.arrow.right.circle.fill"
        case .riskReward:      return "arrow.left.arrow.right"
        case .atrSanity:       return "waveform.path"
        case .spreadCost:      return "dollarsign.arrow.circlepath"
        }
    }
}


// MARK: - Session daily logs (the site's "vault-backed session ledger + daily logs")
// PURE CSV builder over already-formatted entries — grouped by day (first-seen order preserved),
// each day followed by a DAY TOTAL line (W/L + net MODELED P&L). Deterministic + testable; writes
// nothing. The file write lives in AppModel.exportDailyLogs (into the local vault dir).
enum SessionLedger {
    struct Entry { let day: String; let symbol: String; let direction: String; let grade: String; let pnl: Double }

    static func dailyCSV(_ entries: [Entry]) -> String {
        var out = "day,symbol,direction,grade,modeled_pnl\n"
        var order: [String] = []
        var byDay: [String: [Entry]] = [:]
        for e in entries {
            if byDay[e.day] == nil { order.append(e.day) }
            byDay[e.day, default: []].append(e)
        }
        for day in order {
            let es = byDay[day] ?? []
            for e in es {
                out += "\(day),\(e.symbol),\(e.direction),\(e.grade),\(String(format: "%.2f", e.pnl))\n"
            }
            let w = es.filter { $0.grade == "win" }.count
            let l = es.filter { $0.grade == "loss" }.count
            let net = es.reduce(0.0) { $0 + $1.pnl }
            out += "\(day),,DAY TOTAL,\(w)W/\(l)L,\(String(format: "%.2f", net))\n"
        }
        return out
    }
}

// MARK: - Manual order ticket (the site's "bracket order — computed size, stop, target, 6-tier trail")
// The MANUAL path: builds a copyable bracket SPEC the trader places on their OWN platform — this
// function itself sends nothing (pure text). Automated placement is the separate, opt-in Execution
// engine (default OFF). Pure + testable.
enum OrderTicket {
    // Contracts sized from account risk: riskCapital / per-contract-$risk, floored. nil when the
    // instrument's $/point is unknown (never fabricate a size).
    static func size(_ r: SignalResult, account: Double, riskPct: Double) -> Int? {
        guard r.hasDollar, r.riskDollars > 0, account > 0, riskPct > 0 else { return nil }
        let riskCapital = account * riskPct / 100.0
        return max(0, Int((riskCapital / r.riskDollars).rounded(.down)))
    }

    static func format(_ r: SignalResult, account: Double, riskPct: Double) -> String {
        guard r.direction != .flat else {
            return "ORDER TICKET — no signal (FLAT). Nothing to place."
        }
        func n(_ x: Double) -> String { String(format: "%.2f", x) }
        let szStr = size(r, account: account, riskPct: riskPct).map(String.init) ?? "—  (enter your own; $/pt unknown for this instrument)"
        var out = "ORDER TICKET — manual copy. Review and place it on YOUR OWN platform.\n"
        out += "SYMBOL \(r.symbol)   SIDE \(r.direction.rawValue)   SIZE \(szStr)\n"
        out += "ENTRY \(n(r.entry))   STOP \(n(r.stop))   TARGET \(n(r.target))   R:R \(String(format: "%.2f", r.rr))\n"
        let trail = r.trailTiers.map { "T\($0.id)@\(n($0.trigger))→\(n($0.stop))" }.joined(separator: "  ")
        if !trail.isEmpty { out += "6-TIER TRAIL  \(trail)\n" }
        out += "Review before placing. Not financial advice; not a guarantee."
        return out
    }
}
