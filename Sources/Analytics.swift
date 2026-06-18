// Black Label Trading — performance analytics + backtest metrics + unified risk panel.
// PURE MATH. No SwiftUI, no network, no fabricated data. Every statistic is computed
// from the user's OWN closed trades (or a user-built backtest's results). Honest framing:
// these are analytics over real inputs the user supplies — never an invented track record.
//
// The "unified risk panel" (Sharpe + Sortino + SQN + Kelly + Z-score of streaks) is the
// gap the leading journals (Tradezella / Edgewonk / TraderSync) do NOT bundle in one view.
import Foundation

// MARK: - A single completed result fed to the analytics engine.
// Deliberately decoupled from the UI `Trade` so the math is independently testable and
// can also score backtest output. `r` is the realized R-multiple; `pnl` is dollars.
struct TradeStat {
    var symbol: String
    var direction: TradeDirection
    var pnl: Double           // realized $ (positive win, negative loss)
    var r: Double             // realized R-multiple (pnl / initial risk)
    var date: Date            // close time
    var holdMinutes: Double   // time in trade
    var mae: Double           // maximum adverse excursion in R (>= 0; 0 if unknown)
    var mfe: Double           // maximum favorable excursion in R (>= 0; 0 if unknown)
    var tags: [String]        // user setup/mistake/emotion tags

    init(symbol: String = "", direction: TradeDirection = .long, pnl: Double, r: Double = 0,
         date: Date = Date(), holdMinutes: Double = 0, mae: Double = 0, mfe: Double = 0, tags: [String] = []) {
        self.symbol = symbol; self.direction = direction; self.pnl = pnl; self.r = r
        self.date = date; self.holdMinutes = holdMinutes; self.mae = mae; self.mfe = mfe; self.tags = tags
    }
}

// MARK: - Core performance report
struct PerfReport {
    var trades = 0
    var wins = 0
    var losses = 0
    var breakeven = 0
    var netPnL = 0.0
    var grossProfit = 0.0
    var grossLoss = 0.0          // stored as a negative number
    var winRate = 0.0            // % of decided (win/loss) trades
    var profitFactor = 0.0       // grossProfit / |grossLoss|; .infinity if no losses
    var expectancyR = 0.0        // average R per trade
    var expectancyDollar = 0.0   // average $ per trade
    var avgWin = 0.0
    var avgLoss = 0.0            // negative
    var payoffRatio = 0.0        // avgWin / |avgLoss|
    var largestWin = 0.0
    var largestLoss = 0.0
    var maxWinStreak = 0
    var maxLossStreak = 0
    var maxDrawdown = 0.0        // largest peak-to-valley drop in cumulative $ (>= 0)
    var maxRunup = 0.0           // largest valley-to-peak rise (>= 0)
    var avgHoldMinutes = 0.0
    var avgMAE = 0.0
    var avgMFE = 0.0
    var longWinRate = 0.0
    var shortWinRate = 0.0
}

enum Analytics {
    // Build the core report from a set of trade results.
    static func report(_ stats: [TradeStat]) -> PerfReport {
        var rep = PerfReport()
        guard !stats.isEmpty else { return rep }
        let sorted = stats.sorted { $0.date < $1.date }
        rep.trades = sorted.count

        for s in sorted {
            rep.netPnL += s.pnl
            if s.pnl > 0 { rep.wins += 1; rep.grossProfit += s.pnl; rep.largestWin = max(rep.largestWin, s.pnl) }
            else if s.pnl < 0 { rep.losses += 1; rep.grossLoss += s.pnl; rep.largestLoss = min(rep.largestLoss, s.pnl) }
            else { rep.breakeven += 1 }
        }
        let decided = rep.wins + rep.losses
        rep.winRate = decided > 0 ? Double(rep.wins) / Double(decided) * 100 : 0
        rep.profitFactor = rep.grossLoss < 0 ? rep.grossProfit / abs(rep.grossLoss)
                                             : (rep.grossProfit > 0 ? .infinity : 0)
        rep.expectancyDollar = rep.netPnL / Double(rep.trades)
        rep.expectancyR = sorted.reduce(0) { $0 + $1.r } / Double(rep.trades)
        rep.avgWin = rep.wins > 0 ? rep.grossProfit / Double(rep.wins) : 0
        rep.avgLoss = rep.losses > 0 ? rep.grossLoss / Double(rep.losses) : 0
        rep.payoffRatio = rep.avgLoss < 0 ? rep.avgWin / abs(rep.avgLoss) : (rep.avgWin > 0 ? .infinity : 0)

        // Streaks (chronological).
        var curW = 0, curL = 0
        for s in sorted {
            if s.pnl > 0 { curW += 1; curL = 0; rep.maxWinStreak = max(rep.maxWinStreak, curW) }
            else if s.pnl < 0 { curL += 1; curW = 0; rep.maxLossStreak = max(rep.maxLossStreak, curL) }
            else { curW = 0; curL = 0 }
        }

        // Drawdown / run-up on cumulative equity.
        var equity = 0.0, peak = 0.0, trough = 0.0
        for s in sorted {
            equity += s.pnl
            peak = max(peak, equity); trough = min(trough, equity)
            rep.maxDrawdown = max(rep.maxDrawdown, peak - equity)
            rep.maxRunup = max(rep.maxRunup, equity - trough)
        }

        rep.avgHoldMinutes = sorted.reduce(0) { $0 + $1.holdMinutes } / Double(rep.trades)
        rep.avgMAE = sorted.reduce(0) { $0 + $1.mae } / Double(rep.trades)
        rep.avgMFE = sorted.reduce(0) { $0 + $1.mfe } / Double(rep.trades)

        let longs = sorted.filter { $0.direction == .long }
        let shorts = sorted.filter { $0.direction == .short }
        rep.longWinRate = winRate(longs)
        rep.shortWinRate = winRate(shorts)
        return rep
    }

    private static func winRate(_ s: [TradeStat]) -> Double {
        let decided = s.filter { $0.pnl != 0 }
        guard !decided.isEmpty else { return 0 }
        return Double(decided.filter { $0.pnl > 0 }.count) / Double(decided.count) * 100
    }

    // MARK: - Unified risk panel (the differentiator no journal bundles in one place)

    /// Sample mean of an array.
    static func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }

    /// Sample standard deviation (n-1). Returns 0 for < 2 points.
    static func stdDev(_ xs: [Double]) -> Double {
        guard xs.count > 1 else { return 0 }
        let m = mean(xs)
        let ss = xs.reduce(0) { $0 + ($1 - m) * ($1 - m) }
        return (ss / Double(xs.count - 1)).squareRoot()
    }

    /// Sharpe ratio of per-trade R-multiples (mean / stddev). Not annualized — a per-trade
    /// risk-adjusted return, which is the honest read for a trade journal. 0 when undefined.
    static func sharpe(_ rs: [Double]) -> Double {
        let sd = stdDev(rs)
        return sd > 0 ? mean(rs) / sd : 0
    }

    /// Sortino ratio: mean R divided by downside deviation (only negative R contributes).
    static func sortino(_ rs: [Double]) -> Double {
        guard rs.count > 1 else { return 0 }
        let downside = rs.map { min(0, $0) }
        let dd = (downside.reduce(0) { $0 + $1 * $1 } / Double(rs.count)).squareRoot()
        return dd > 0 ? mean(rs) / dd : 0
    }

    /// Van Tharp's System Quality Number: mean(R) / stddev(R) * sqrt(n). 0 when undefined.
    static func sqn(_ rs: [Double]) -> Double {
        let sd = stdDev(rs)
        guard sd > 0, rs.count > 1 else { return 0 }
        return mean(rs) / sd * Double(rs.count).squareRoot()
    }

    /// Kelly fraction from win rate (0…1) and payoff ratio b = avgWin/|avgLoss|.
    /// f* = W - (1-W)/b. Clamped to [0,1]; 0 when payoff <= 0 or no edge.
    static func kelly(winRate W: Double, payoff b: Double) -> Double {
        guard b > 0 else { return 0 }
        let f = W - (1 - W) / b
        return max(0, min(1, f))
    }

    /// Z-score of the win/loss streak distribution (Wald–Wolfowitz runs test).
    /// Tests whether wins/losses cluster more (or less) than chance — i.e. is there
    /// serial dependence in outcomes. |Z| > ~1.96 ⇒ statistically non-random streaks.
    /// Positive Z ⇒ fewer runs than expected (streaky); negative ⇒ more runs (choppy).
    static func streakZScore(_ stats: [TradeStat]) -> Double {
        let outcomes = stats.sorted { $0.date < $1.date }.compactMap { s -> Bool? in
            if s.pnl > 0 { return true }; if s.pnl < 0 { return false }; return nil
        }
        let n = Double(outcomes.count)
        let w = Double(outcomes.filter { $0 }.count)
        let l = n - w
        guard w > 0, l > 0, n > 1 else { return 0 }
        // Count runs (maximal same-outcome streaks).
        var runs = 1
        for i in 1..<outcomes.count where outcomes[i] != outcomes[i-1] { runs += 1 }
        let R = Double(runs)
        let expected = (2 * w * l) / n + 1
        let variance = (2 * w * l * (2 * w * l - n)) / (n * n * (n - 1))
        guard variance > 0 else { return 0 }
        // Negative because positive Z conventionally indicates *streakiness* (fewer runs).
        return (expected - R) / variance.squareRoot()
    }

    struct RiskPanel {
        var sharpe = 0.0
        var sortino = 0.0
        var sqn = 0.0
        var kelly = 0.0          // suggested fraction of capital to risk (full Kelly)
        var halfKelly = 0.0      // common practical sizing (half Kelly)
        var streakZ = 0.0
        var streaksNonRandom: Bool = false   // |Z| > 1.96
        var sampleSize = 0
    }

    static func riskPanel(_ stats: [TradeStat]) -> RiskPanel {
        var p = RiskPanel()
        p.sampleSize = stats.count
        guard stats.count > 1 else { return p }
        let rs = stats.map { $0.r }
        p.sharpe = sharpe(rs)
        p.sortino = sortino(rs)
        p.sqn = sqn(rs)
        let rep = report(stats)
        p.kelly = kelly(winRate: rep.winRate / 100, payoff: rep.payoffRatio.isFinite ? rep.payoffRatio : 0)
        p.halfKelly = p.kelly / 2
        p.streakZ = streakZScore(stats)
        p.streaksNonRandom = abs(p.streakZ) > 1.96
        return p
    }

    // MARK: - R-multiple distribution (histogram buckets for the journal chart)
    struct RBucket: Identifiable { let label: String; let lo: Double; let hi: Double; let count: Int; var id: String { label } }
    static func rDistribution(_ stats: [TradeStat]) -> [RBucket] {
        let edges: [(String, Double, Double)] = [
            ("≤ -3R", -.infinity, -3), ("-3 to -2R", -3, -2), ("-2 to -1R", -2, -1),
            ("-1 to 0R", -1, 0), ("0 to 1R", 0, 1), ("1 to 2R", 1, 2),
            ("2 to 3R", 2, 3), ("≥ 3R", 3, .infinity)
        ]
        return edges.map { (label, lo, hi) in
            let c = stats.filter { $0.r > lo && $0.r <= hi || (lo == -.infinity && $0.r <= hi) || (hi == .infinity && $0.r > lo) }.count
            return RBucket(label: label, lo: lo, hi: hi, count: c)
        }
    }

    // MARK: - Time-of-day performance (24 hourly buckets, local time)
    struct HourBucket: Identifiable { let hour: Int; let trades: Int; let netPnL: Double; let winRate: Double; var id: Int { hour } }
    static func byHour(_ stats: [TradeStat], calendar: Calendar = .current) -> [HourBucket] {
        (0..<24).map { h in
            let inHour = stats.filter { calendar.component(.hour, from: $0.date) == h }
            let decided = inHour.filter { $0.pnl != 0 }
            let wr = decided.isEmpty ? 0 : Double(decided.filter { $0.pnl > 0 }.count) / Double(decided.count) * 100
            return HourBucket(hour: h, trades: inHour.count, netPnL: inHour.reduce(0) { $0 + $1.pnl }, winRate: wr)
        }
    }

    // MARK: - Day-of-week performance (1=Sun … 7=Sat to match Calendar)
    struct DayBucket: Identifiable { let weekday: Int; let name: String; let trades: Int; let netPnL: Double; let winRate: Double; var id: Int { weekday } }
    static func byWeekday(_ stats: [TradeStat], calendar: Calendar = .current) -> [DayBucket] {
        let names = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return (1...7).map { wd in
            let inDay = stats.filter { calendar.component(.weekday, from: $0.date) == wd }
            let decided = inDay.filter { $0.pnl != 0 }
            let wr = decided.isEmpty ? 0 : Double(decided.filter { $0.pnl > 0 }.count) / Double(decided.count) * 100
            return DayBucket(weekday: wd, name: names[wd], trades: inDay.count, netPnL: inDay.reduce(0) { $0 + $1.pnl }, winRate: wr)
        }
    }

    // MARK: - Calendar P&L heatmap (per calendar day) — only days with trades.
    struct DayPnL: Identifiable { let day: Date; let netPnL: Double; let trades: Int; var id: TimeInterval { day.timeIntervalSince1970 } }
    static func dailyPnL(_ stats: [TradeStat], calendar: Calendar = .current) -> [DayPnL] {
        let groups = Dictionary(grouping: stats) { calendar.startOfDay(for: $0.date) }
        return groups.map { (day, ts) in DayPnL(day: day, netPnL: ts.reduce(0) { $0 + $1.pnl }, trades: ts.count) }
            .sorted { $0.day < $1.day }
    }

    // MARK: - By-tag performance (setups / mistakes / emotions)
    struct TagStat: Identifiable { let tag: String; let trades: Int; let netPnL: Double; let winRate: Double; let expectancyR: Double; var id: String { tag } }
    static func byTag(_ stats: [TradeStat]) -> [TagStat] {
        var tagged: [String: [TradeStat]] = [:]
        for s in stats { for t in s.tags { tagged[t, default: []].append(s) } }
        return tagged.map { (tag, ts) in
            let decided = ts.filter { $0.pnl != 0 }
            let wr = decided.isEmpty ? 0 : Double(decided.filter { $0.pnl > 0 }.count) / Double(decided.count) * 100
            let exp = ts.isEmpty ? 0 : ts.reduce(0) { $0 + $1.r } / Double(ts.count)
            return TagStat(tag: tag, trades: ts.count, netPnL: ts.reduce(0) { $0 + $1.pnl }, winRate: wr, expectancyR: exp)
        }.sorted { $0.netPnL > $1.netPnL }
    }

    // MARK: - By-symbol performance
    struct SymbolStat: Identifiable { let symbol: String; let trades: Int; let netPnL: Double; let winRate: Double; var id: String { symbol } }
    static func bySymbol(_ stats: [TradeStat]) -> [SymbolStat] {
        let groups = Dictionary(grouping: stats) { $0.symbol.uppercased() }
        return groups.map { (sym, ts) in
            let decided = ts.filter { $0.pnl != 0 }
            let wr = decided.isEmpty ? 0 : Double(decided.filter { $0.pnl > 0 }.count) / Double(decided.count) * 100
            return SymbolStat(symbol: sym.isEmpty ? "—" : sym, trades: ts.count, netPnL: ts.reduce(0) { $0 + $1.pnl }, winRate: wr)
        }.sorted { $0.netPnL > $1.netPnL }
    }
}
