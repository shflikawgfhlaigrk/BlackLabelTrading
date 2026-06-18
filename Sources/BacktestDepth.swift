// Black Label Trading — backtest DEPTH: walk-forward + Monte-Carlo. PURE MATH.
//
// HONEST FRAMING: these run ONLY on the user's own imported bars and the trades produced by
// the in-house Backtester. Walk-forward proves a rule is not curve-fit to one slice;
// Monte-Carlo bootstraps the realized trade list to show the *distribution* of outcomes
// (so a single lucky run isn't sold as a track record). Nothing is fabricated — empty input
// yields empty output, and the framing is explicitly "robustness analysis, not a guarantee".
import Foundation

// MARK: - Walk-forward analysis
// Splits the bar series into K contiguous, non-overlapping windows ("folds") and runs the
// SAME strategy config over each. Reports per-fold stats so the user can see whether edge is
// consistent across time or concentrated in one regime. (In-house, no optimizer to overfit —
// honest robustness, not a promise.)
struct WalkForwardFold: Identifiable {
    var id = UUID()
    var index: Int
    var startDate: Date
    var endDate: Date
    var bars: Int
    var report: PerfReport
    var trades: Int
}

struct WalkForwardResult {
    var folds: [WalkForwardFold] = []
    var consistency: Double = 0      // fraction of folds that were net-positive (0…1)
    var avgExpectancyR: Double = 0   // mean per-fold expectancy in R
    var positiveFolds: Int = 0
    var totalFolds: Int = 0
    var combinedReport: PerfReport = PerfReport()   // report over ALL trades across folds
}

enum WalkForward {
    /// Run `cfg` over `folds` contiguous slices of `bars`. Returns per-fold + combined honest stats.
    /// `folds < 2` or too-few bars per fold -> empty (no fabrication).
    static func run(_ bars: [Bar], _ cfg: StrategyConfig, folds: Int) -> WalkForwardResult {
        var out = WalkForwardResult()
        guard folds >= 2, bars.count >= folds * 10 else { return out }
        let sorted = bars.sorted { $0.date < $1.date }
        let size = sorted.count / folds
        var allStats: [TradeStat] = []
        for k in 0..<folds {
            let lo = k * size
            let hi = (k == folds - 1) ? sorted.count : (k + 1) * size   // last fold absorbs remainder
            let slice = Array(sorted[lo..<hi])
            let (trades, stats) = Backtester.run(slice, cfg)
            let rep = Analytics.report(stats)
            allStats.append(contentsOf: stats)
            out.folds.append(WalkForwardFold(index: k + 1,
                                             startDate: slice.first?.date ?? Date(),
                                             endDate: slice.last?.date ?? Date(),
                                             bars: slice.count, report: rep, trades: trades.count))
        }
        out.totalFolds = out.folds.count
        out.positiveFolds = out.folds.filter { $0.report.netPnL > 0 }.count
        out.consistency = out.totalFolds > 0 ? Double(out.positiveFolds) / Double(out.totalFolds) : 0
        let foldsWithTrades = out.folds.filter { $0.trades > 0 }
        out.avgExpectancyR = foldsWithTrades.isEmpty ? 0
            : foldsWithTrades.reduce(0) { $0 + $1.report.expectancyR } / Double(foldsWithTrades.count)
        out.combinedReport = Analytics.report(allStats)
        return out
    }
}

// MARK: - Monte-Carlo (trade-sequence bootstrap)
// Resamples the realized trade P&Ls (with replacement) many times to build a distribution of
// terminal equity and max-drawdown. Deterministic given a seed so results are reproducible
// and auditable — the opposite of a painted number. Reports percentiles + risk-of-ruin.
struct MonteCarloResult {
    var runs: Int = 0
    var samplePerRun: Int = 0
    var medianFinalEquity: Double = 0
    var p5FinalEquity: Double = 0     // 5th percentile terminal equity (downside)
    var p95FinalEquity: Double = 0    // 95th percentile terminal equity (upside)
    var medianMaxDrawdown: Double = 0
    var p95MaxDrawdown: Double = 0    // worst-case drawdown (95th pct of the DD distribution)
    var probProfit: Double = 0        // P(terminal equity > 0)
    var riskOfRuin: Double = 0        // P(equity ever drops below -ruinThreshold)
    var ruinThreshold: Double = 0
    var finals: [Double] = []         // sorted terminal equities (for a histogram)
}

// A tiny, seeded, reproducible PRNG (xorshift64*). Same seed -> same sequence on every
// platform/run, so Monte-Carlo output is auditable and re-runnable (not a one-off "result").
struct SeededRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state >> 12; state ^= state << 25; state ^= state >> 27
        return state &* 0x2545F4914F6CDD1D
    }
    // Uniform Int in 0..<n.
    mutating func int(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
}

enum MonteCarlo {
    /// Bootstrap the trade P&Ls. `runs` simulations, each drawing `samplePerRun` trades
    /// (default = realized count) with replacement. `ruinFraction` of starting capital defines
    /// ruin (e.g. 0.5 = lose half). Deterministic for a given `seed`.
    static func run(_ stats: [TradeStat], runs: Int = 1000, samplePerRun: Int? = nil,
                    startingCapital: Double = 0, ruinFraction: Double = 1.0, seed: UInt64 = 0xBADC0FFEE) -> MonteCarloResult {
        var out = MonteCarloResult()
        let pnls = stats.map { $0.pnl }
        guard !pnls.isEmpty, runs > 0 else { return out }
        let perRun = max(1, samplePerRun ?? pnls.count)
        out.runs = runs; out.samplePerRun = perRun
        out.ruinThreshold = startingCapital * ruinFraction

        var rng = SeededRNG(seed: seed)
        var finals: [Double] = []; finals.reserveCapacity(runs)
        var maxDDs: [Double] = []; maxDDs.reserveCapacity(runs)
        var ruined = 0, profitable = 0
        for _ in 0..<runs {
            var equity = startingCapital, peak = startingCapital, mdd = 0.0
            var didRuin = false
            for _ in 0..<perRun {
                equity += pnls[rng.int(pnls.count)]
                peak = max(peak, equity)
                mdd = max(mdd, peak - equity)
                if startingCapital > 0 && equity <= startingCapital - out.ruinThreshold { didRuin = true }
            }
            let terminal = equity - startingCapital   // express as net P&L (so it works with startingCapital 0)
            finals.append(terminal)
            maxDDs.append(mdd)
            if terminal > 0 { profitable += 1 }
            if didRuin { ruined += 1 }
        }
        finals.sort(); maxDDs.sort()
        func pct(_ arr: [Double], _ p: Double) -> Double {
            guard !arr.isEmpty else { return 0 }
            let idx = min(arr.count - 1, max(0, Int((p / 100) * Double(arr.count - 1) + 0.5)))
            return arr[idx]
        }
        out.finals = finals
        out.medianFinalEquity = pct(finals, 50)
        out.p5FinalEquity = pct(finals, 5)
        out.p95FinalEquity = pct(finals, 95)
        out.medianMaxDrawdown = pct(maxDDs, 50)
        out.p95MaxDrawdown = pct(maxDDs, 95)
        out.probProfit = Double(profitable) / Double(runs) * 100
        out.riskOfRuin = startingCapital > 0 ? Double(ruined) / Double(runs) * 100 : 0
        return out
    }

    // Histogram buckets of terminal equities for the distribution chart.
    struct Bucket: Identifiable { let mid: Double; let count: Int; var id: Double { mid } }
    static func histogram(_ finals: [Double], buckets: Int = 24) -> [Bucket] {
        guard let lo = finals.min(), let hi = finals.max(), hi > lo, buckets > 0 else { return [] }
        let width = (hi - lo) / Double(buckets)
        var counts = [Int](repeating: 0, count: buckets)
        for f in finals {
            let b = min(buckets - 1, max(0, Int((f - lo) / width)))
            counts[b] += 1
        }
        return counts.enumerated().map { (i, c) in Bucket(mid: lo + (Double(i) + 0.5) * width, count: c) }
    }
}
