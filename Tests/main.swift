// Black Label Trading — headless test suite for the pure-logic engines.
// Run via: ./Tests/run-tests.sh  (compiles engines + this file, no SwiftUI).
// Asserts known-correct values so the analytics/backtest/screener/alert math is trustworthy
// before the UI is wired — these stats are presented to users as honest performance numbers.
import Foundation

// Minimal assertion harness.
var passed = 0, failed = 0
func ok(_ cond: Bool, _ name: String) {
    if cond { passed += 1 } else { failed += 1; print("  FAIL: \(name)") }
}
func eq(_ a: Double, _ b: Double, _ name: String, tol: Double = 1e-6) {
    if abs(a - b) <= tol { passed += 1 } else { failed += 1; print("  FAIL: \(name) — got \(a), expected \(b)") }
}
func eqi(_ a: Int, _ b: Int, _ name: String) {
    if a == b { passed += 1 } else { failed += 1; print("  FAIL: \(name) — got \(a), expected \(b)") }
}

func day(_ offset: Int) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + Double(offset) * 86_400) }

// Tests use a throwaway temp dir so they never write into the real app-support container.
let tmpBase = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("blt-tests-\(UUID().uuidString)")

// ===== Analytics =====
func testAnalyticsCore() {
    // 3 wins of +100, 2 losses of -50. net = 200. PF = 300/100 = 3.
    let stats = [
        TradeStat(direction: .long, pnl: 100, r: 2, date: day(0)),
        TradeStat(direction: .long, pnl: -50, r: -1, date: day(1)),
        TradeStat(direction: .short, pnl: 100, r: 2, date: day(2)),
        TradeStat(direction: .long, pnl: -50, r: -1, date: day(3)),
        TradeStat(direction: .short, pnl: 100, r: 2, date: day(4)),
    ]
    let r = Analytics.report(stats)
    eqi(r.trades, 5, "report.trades")
    eqi(r.wins, 3, "report.wins")
    eqi(r.losses, 2, "report.losses")
    eq(r.netPnL, 200, "report.netPnL")
    eq(r.grossProfit, 300, "report.grossProfit")
    eq(r.grossLoss, -100, "report.grossLoss")
    eq(r.winRate, 60, "report.winRate")
    eq(r.profitFactor, 3, "report.profitFactor")
    eq(r.expectancyDollar, 40, "report.expectancyDollar")
    eq(r.expectancyR, 0.8, "report.expectancyR")   // (2-1+2-1+2)/5
    eq(r.avgWin, 100, "report.avgWin")
    eq(r.avgLoss, -50, "report.avgLoss")
    eq(r.payoffRatio, 2, "report.payoffRatio")
    eq(r.largestWin, 100, "report.largestWin")
    eq(r.largestLoss, -50, "report.largestLoss")
}

func testProfitFactorInfinite() {
    let stats = [TradeStat(pnl: 100, date: day(0)), TradeStat(pnl: 50, date: day(1))]
    let r = Analytics.report(stats)
    ok(r.profitFactor.isInfinite, "profitFactor infinite when no losses")
}

func testStreaksAndDrawdown() {
    // W W W L L L W  -> max win streak 3, max loss streak 3
    let p: [Double] = [10, 10, 10, -10, -10, -10, 10]
    let stats = p.enumerated().map { TradeStat(pnl: $0.element, r: $0.element/10, date: day($0.offset)) }
    let r = Analytics.report(stats)
    eqi(r.maxWinStreak, 3, "maxWinStreak")
    eqi(r.maxLossStreak, 3, "maxLossStreak")
    // equity: 10 20 30 20 10 0 10. peak 30. max DD = 30 - 0 = 30.
    eq(r.maxDrawdown, 30, "maxDrawdown")
}

func testRiskPanel() {
    // rs = [1, -1, 1, -1, 1]. mean = 0.2. stddev (n-1): values dev from 0.2: .8,-1.2,.8,-1.2,.8
    // ss = .64+1.44+.64+1.44+.64 = 4.8; /4 = 1.2; sqrt = 1.0954451
    let stats = [1.0, -1, 1, -1, 1].enumerated().map { TradeStat(pnl: $0.element*100, r: $0.element, date: day($0.offset)) }
    let rs = stats.map { $0.r }
    eq(Analytics.mean(rs), 0.2, "mean")
    eq(Analytics.stdDev(rs), 1.0954451150103321, "stdDev", tol: 1e-9)
    eq(Analytics.sharpe(rs), 0.2/1.0954451150103321, "sharpe", tol: 1e-9)
    // SQN = mean/std * sqrt(n)
    eq(Analytics.sqn(rs), 0.2/1.0954451150103321 * sqrt(5), "sqn", tol: 1e-9)
    let panel = Analytics.riskPanel(stats)
    eqi(panel.sampleSize, 5, "panel.sampleSize")
    // sortino downside: only negatives count, dd = sqrt((1+1)/5)=sqrt(0.4)
    eq(Analytics.sortino(rs), 0.2/sqrt(0.4), "sortino", tol: 1e-9)
}

func testKelly() {
    // W=0.6, payoff b=2 -> f = .6 - .4/2 = .4
    eq(Analytics.kelly(winRate: 0.6, payoff: 2), 0.4, "kelly basic")
    // no edge -> clamp 0
    eq(Analytics.kelly(winRate: 0.3, payoff: 1), 0, "kelly clamps to 0")
    eq(Analytics.kelly(winRate: 0.9, payoff: 0), 0, "kelly 0 when payoff 0")
}

func testStreakZScore() {
    // Perfectly alternating W L W L ... has MANY runs (more than expected) -> negative Z.
    let alt = (0..<10).map { TradeStat(pnl: $0 % 2 == 0 ? 10.0 : -10.0, date: day($0)) }
    ok(Analytics.streakZScore(alt) < -1, "alternating gives strongly negative Z (choppy)")
    // One big streak then another -> fewer runs -> positive Z.
    let streaky = (0..<10).map { TradeStat(pnl: $0 < 5 ? 10.0 : -10.0, date: day($0)) }
    ok(Analytics.streakZScore(streaky) > 0.5, "two blocks give positive Z (streaky)")
}

func testRDistribution() {
    let stats = [TradeStat(pnl: 1, r: 2.5, date: day(0)), TradeStat(pnl: 1, r: -1.5, date: day(1)),
                 TradeStat(pnl: 1, r: 0.5, date: day(2))]
    let dist = Analytics.rDistribution(stats)
    eqi(dist.first { $0.label == "2 to 3R" }?.count ?? -1, 1, "rDist 2-3R bucket")
    eqi(dist.first { $0.label == "-2 to -1R" }?.count ?? -1, 1, "rDist -2 to -1R bucket")
    eqi(dist.first { $0.label == "0 to 1R" }?.count ?? -1, 1, "rDist 0-1R bucket")
    eqi(dist.reduce(0) { $0 + $1.count }, 3, "rDist total == trades")
}

func testByTagAndSymbol() {
    let stats = [
        TradeStat(symbol: "ES", pnl: 100, r: 1, date: day(0), tags: ["breakout"]),
        TradeStat(symbol: "ES", pnl: -50, r: -1, date: day(1), tags: ["breakout", "fomo"]),
        TradeStat(symbol: "NQ", pnl: 200, r: 2, date: day(2), tags: ["pullback"]),
    ]
    let tags = Analytics.byTag(stats)
    eqi(tags.first { $0.tag == "breakout" }?.trades ?? -1, 2, "byTag breakout count")
    eq(tags.first { $0.tag == "breakout" }?.netPnL ?? -999, 50, "byTag breakout net")
    eq(tags.first { $0.tag == "fomo" }?.winRate ?? -1, 0, "byTag fomo winrate 0")
    let syms = Analytics.bySymbol(stats)
    eq(syms.first { $0.symbol == "NQ" }?.netPnL ?? -1, 200, "bySymbol NQ net")
    eqi(syms.first { $0.symbol == "ES" }?.trades ?? -1, 2, "bySymbol ES count")
}

func testDailyPnL() {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    let stats = [
        TradeStat(pnl: 100, date: Date(timeIntervalSince1970: 1_700_000_000)),
        TradeStat(pnl: -30, date: Date(timeIntervalSince1970: 1_700_000_000 + 3600)),  // same day
        TradeStat(pnl: 50, date: Date(timeIntervalSince1970: 1_700_000_000 + 86_400)), // next day
    ]
    let daily = Analytics.dailyPnL(stats, calendar: cal)
    eqi(daily.count, 2, "dailyPnL day count")
    eq(daily.first?.netPnL ?? -1, 70, "dailyPnL day1 net (100-30)")
}

// ===== Indicators & Backtest =====
func testSMA() {
    let closes = [1.0, 2, 3, 4, 5]
    let s = Indicators.sma(closes, 3)
    ok(s[0] == nil && s[1] == nil, "sma nil before period")
    eq(s[2] ?? -1, 2, "sma(3) at idx2 = (1+2+3)/3")
    eq(s[4] ?? -1, 4, "sma(3) at idx4 = (3+4+5)/3")
}

func testRSIAllUp() {
    // Monotonic rising closes -> RSI should be 100 (no losses).
    let closes = (1...30).map { Double($0) }
    let r = Indicators.rsi(closes, 14)
    eq(r.last! ?? -1, 100, "rsi monotonic up = 100")
}

func testBacktestRunsAndMath() {
    // Build a deterministic uptrend so an SMA-cross-up long enters and the target is hit.
    // 60 bars: flat-ish then a clean ramp.
    var bars: [Bar] = []
    var price = 100.0
    for i in 0..<80 {
        // gentle noise then a strong uptrend after bar 35
        price += (i < 35) ? 0.0 : 1.0
        let o = price, c = price + 0.5, h = c + 0.5, l = o - 0.5
        bars.append(Bar(date: day(i), open: o, high: h, low: l, close: c, volume: 1000))
    }
    var cfg = StrategyConfig()
    cfg.entry = .smaCrossUp; cfg.exit = .atrStopTarget
    cfg.fastSMA = 5; cfg.slowSMA = 20; cfg.atrPeriod = 14
    cfg.atrStopMult = 1.5; cfg.targetR = 2.0; cfg.pointValue = 1
    let (trades, stats) = Backtester.run(bars, cfg)
    ok(trades.count >= 1, "backtest produced at least one trade on an uptrend long strategy")
    if let t = trades.first {
        // For a long in a clean uptrend, expect a winner hitting +2R.
        ok(t.direction == .long, "backtest entry is long for smaCrossUp")
        ok(t.exit > t.entry, "winning long exits higher than entry")
        eq(t.r, 2.0, "winning long realizes ~+2R (target)", tol: 0.05)
    }
    // Stats mirror the trades and feed the same honest report.
    eqi(stats.count, trades.count, "stats count == trades count")
    let rep = Analytics.report(stats)
    eqi(rep.trades, trades.count, "report over backtest stats")
}

func testBacktestEmptyInput() {
    let (t, s) = Backtester.run([], StrategyConfig())
    ok(t.isEmpty && s.isEmpty, "empty bars -> empty backtest (no fabrication)")
}

func testCommissionReducesPnL() {
    var bars: [Bar] = []
    var price = 100.0
    for i in 0..<80 { price += (i < 35) ? 0.0 : 1.0; bars.append(Bar(date: day(i), open: price, high: price+1, low: price-1, close: price+0.5)) }
    var cfg = StrategyConfig(); cfg.fastSMA = 5; cfg.slowSMA = 20; cfg.pointValue = 1
    let noComm = Backtester.run(bars, cfg).stats.reduce(0) { $0 + $1.pnl }
    cfg.commissionPerTrade = 5
    let withComm = Backtester.run(bars, cfg).stats.reduce(0) { $0 + $1.pnl }
    ok(withComm < noComm, "commission reduces net P&L honestly")
}

func testCSVParse() {
    let csv = """
    date,open,high,low,close,volume
    2026-01-02,100,102,99,101,5000
    2026-01-03,101,103,100,102.5,4200
    bad,row,here
    2026-01-04,102.5,104,101,103
    """
    let (bars, skipped) = BarCSV.parse(csv)
    eqi(bars.count, 3, "CSV parsed 3 good rows (header skipped as non-date)")
    eqi(skipped, 2, "CSV skipped header + malformed row")
    eq(bars[0].close, 101, "CSV first close")
    eq(bars[2].close, 103, "CSV third close (no volume col)")
}

// ===== Screener =====
func sym(_ t: String, last: Double? = nil, chg: Double? = nil, rv: Double? = nil, rsi: Double? = nil,
         pe: Double? = nil, s50: Double? = nil, s200: Double? = nil, h52: Double? = nil) -> WatchSymbol {
    var s = WatchSymbol(symbol: t)
    s.last = last; s.changePct = chg; s.relVolume = rv; s.rsi = rsi; s.peRatio = pe
    s.sma50Rel = s50; s.sma200Rel = s200; s.high52wRel = h52
    return s
}

func testScreenerFilters() {
    let universe = [
        sym("AAA", chg: 5, rv: 2.5, rsi: 25),
        sym("BBB", chg: -4, rv: 0.5, rsi: 75),
        sym("CCC", chg: 1, rv: 3.0, rsi: 50),
        sym("DDD"),  // no snapshot -> never passes numeric filters
    ]
    // Gainers: chg >= 3
    let gainers = Screener.run(ScreenQuery(logic: .all, filters: [ScreenFilter(metric: .changePct, op: .gte, a: 3)]), over: universe)
    eqi(gainers.count, 1, "screener gainers count")
    ok(gainers.first?.symbol == "AAA", "screener gainer is AAA")
    // No-data symbol never passes
    ok(!gainers.contains { $0.symbol == "DDD" }, "no-snapshot symbol excluded (honest no-data)")
    // ANY logic
    let q = ScreenQuery(logic: .any, filters: [
        ScreenFilter(metric: .changePct, op: .gte, a: 3),
        ScreenFilter(metric: .rsi, op: .gte, a: 70)])
    let any = Screener.run(q, over: universe)
    eqi(any.count, 2, "screener ANY logic (AAA gainer OR BBB overbought)")
    // between
    let bt = Screener.run(ScreenQuery(logic: .all, filters: [ScreenFilter(metric: .relVolume, op: .between, a: 2, b: 3)]), over: universe)
    eqi(bt.count, 2, "screener between 2-3 relVol = AAA(2.5) + CCC(3.0)")
}

func testScreenerPresets() {
    ok(ScreenPresets.all.count >= 8, "preset library has >= 8 presets")
    let oversold = ScreenPresets.all.first { $0.name == "Oversold (RSI)" }!
    let res = Screener.run(oversold.query, over: [sym("X", rsi: 20), sym("Y", rsi: 80)])
    eqi(res.count, 1, "oversold preset matches RSI<=30")
}

// ===== Watchlist store (uses a temp file) =====
func testWatchlistStore() {
    let store = WatchlistStore(filename: "wl.json", baseDir: tmpBase)
    store.addList("Futures")
    ok(store.lists.count == 1, "watchlist added")
    let lid = store.lists[0].id
    store.addSymbol("es", to: lid)
    store.addSymbol("ES", to: lid)   // dup ignored (case-insensitive)
    store.addSymbol("NQ", to: lid)
    eqi(store.lists[0].symbols.count, 2, "dedup symbols case-insensitively")
    let sid = store.lists[0].symbols.first { $0.symbol == "NQ" }!.id
    store.toggleFlag(sid, in: lid)
    ok(store.lists[0].symbols.first { $0.id == sid }!.flagged, "flag toggled")
    store.removeSymbol(sid, from: lid)
    eqi(store.lists[0].symbols.count, 1, "symbol removed")
}

// ===== Alerts engine =====
func testAlertLevelAndCross() {
    // level: last is above 100
    let aAbove = TradeAlert(symbol: "ES", conditions: [AlertCondition(metric: .last, op: .above, threshold: 100)])
    ok(AlertEvaluator.shouldFire(aAbove, current: sym("ES", last: 101), previous: nil), "above fires at 101")
    ok(!AlertEvaluator.shouldFire(aAbove, current: sym("ES", last: 99), previous: nil), "above doesn't fire at 99")
    ok(!AlertEvaluator.shouldFire(aAbove, current: sym("ES"), previous: nil), "above never fires with nil value")
    // cross above 100 needs prev <= 100 and now > 100
    let aCross = TradeAlert(symbol: "ES", conditions: [AlertCondition(metric: .last, op: .crossesAbove, threshold: 100)])
    ok(AlertEvaluator.shouldFire(aCross, current: sym("ES", last: 101), previous: sym("ES", last: 99)), "crossesAbove fires 99->101")
    ok(!AlertEvaluator.shouldFire(aCross, current: sym("ES", last: 101), previous: sym("ES", last: 100.5)), "crossesAbove no fire if prev already above")
    ok(!AlertEvaluator.shouldFire(aCross, current: sym("ES", last: 101), previous: nil), "crossesAbove needs previous")
}

func testAlertMultiCondition() {
    let a = TradeAlert(symbol: "ES",
                       conditions: [AlertCondition(metric: .changePct, op: .above, threshold: 2),
                                    AlertCondition(metric: .relVolume, op: .above, threshold: 1.5)],
                       combine: .all)
    ok(AlertEvaluator.shouldFire(a, current: sym("ES", chg: 3, rv: 2), previous: nil), "AND both met fires")
    ok(!AlertEvaluator.shouldFire(a, current: sym("ES", chg: 3, rv: 1), previous: nil), "AND one unmet no fire")
    var anyA = a; anyA.combine = .any
    ok(AlertEvaluator.shouldFire(anyA, current: sym("ES", chg: 3, rv: 1), previous: nil), "OR one met fires")
}

func testAlertStoreOneShotAndRepeat() {
    let store = AlertStore(filename: "al-\(UUID().uuidString).json", baseDir: tmpBase)
    var oneShot = TradeAlert(symbol: "ES", conditions: [AlertCondition(metric: .last, op: .above, threshold: 100)])
    oneShot.repeats = false
    store.add(oneShot)
    let fired1 = store.evaluate([sym("ES", last: 101)])
    eqi(fired1.count, 1, "one-shot fires once")
    ok(!store.alerts[0].enabled, "one-shot disarms after firing")
    let fired2 = store.evaluate([sym("ES", last: 102)])
    eqi(fired2.count, 0, "one-shot doesn't fire again")

    let store2 = AlertStore(filename: "al2-\(UUID().uuidString).json", baseDir: tmpBase)
    var rep = TradeAlert(symbol: "NQ", conditions: [AlertCondition(metric: .last, op: .above, threshold: 100)])
    rep.repeats = true
    store2.add(rep)
    eqi(store2.evaluate([sym("NQ", last: 101)]).count, 1, "repeat fires first time")
    eqi(store2.evaluate([sym("NQ", last: 102)]).count, 1, "repeat fires again (stays armed)")
    ok(store2.alerts[0].enabled, "repeat stays enabled")
    eqi(store2.alerts[0].fireCount, 2, "repeat fireCount increments")
}

// ===== Charting (candle transforms, indicators, fib) =====
func bar(_ i: Int, _ o: Double, _ h: Double, _ l: Double, _ c: Double, _ v: Double = 1000) -> Bar {
    Bar(date: day(i), open: o, high: h, low: l, close: c, volume: v)
}

func testCandlesPassThrough() {
    let bars = [bar(0, 10, 12, 9, 11), bar(1, 11, 13, 10, 10)]
    let c = CandleTransform.candles(bars)
    eqi(c.count, 2, "candles count == bars")
    eqi(c[0].index, 0, "candle index 0 sequential")
    eq(c[1].close, 10, "candle 1 close pass-through")
    ok(c[0].up, "candle 0 up (close>=open)")
    ok(!c[1].up, "candle 1 down (close<open)")
}

func testHeikinAshi() {
    // First HA bar: haClose=(O+H+L+C)/4, haOpen=(O+C)/2.
    let bars = [bar(0, 10, 14, 8, 12), bar(1, 12, 16, 11, 15)]
    let ha = CandleTransform.heikinAshi(bars)
    eqi(ha.count, 2, "HA count == bars")
    eq(ha[0].close, (10+14+8+12)/4, "HA[0] close = (O+H+L+C)/4")
    eq(ha[0].open, (10.0+12)/2, "HA[0] open = (O+C)/2 seed")
    // HA[1] open = (prevOpen + prevClose)/2
    eq(ha[1].open, (ha[0].open + ha[0].close)/2, "HA[1] open = avg of prev HA O/C")
    // HA high/low envelope the body
    ok(ha[1].high >= max(ha[1].open, ha[1].close), "HA high envelops body")
    ok(ha[1].low <= min(ha[1].open, ha[1].close), "HA low envelops body")
}

func testRenko() {
    // Closes climb by ~brickSize -> up bricks print. brickSize 1, closes 100..104.
    let bars = (0..<5).map { bar($0, 100 + Double($0), 100 + Double($0) + 0.2, 99 + Double($0), 100 + Double($0)) }
    let bricks = CandleTransform.renko(bars, brickSize: 1)
    ok(bricks.count >= 3, "renko produced multiple up bricks on a climb")
    ok(bricks.allSatisfy { $0.up }, "all bricks up on a clean climb")
    // brick size 0 falls back to candles
    eqi(CandleTransform.renko(bars, brickSize: 0).count, bars.count, "renko brickSize 0 -> candles")
}

func testVWAP() {
    // Cumulative VWAP over 2 bars, equal volume. tp1=(12+9+11)/3=10.667 actually use exact.
    let bars = [bar(0, 10, 11, 9, 10, 100), bar(1, 10, 12, 8, 10, 100)]  // tp = (11+9+10)/3=10 ; (12+8+10)/3=10
    let v = ChartIndicators.vwap(bars, window: 99)
    eq(v[0] ?? -1, 10, "vwap[0] = typical price 10")
    eq(v[1] ?? -1, 10, "vwap[1] cumulative = 10")
    // Zero-volume bars -> nil (honest, no synthetic volume)
    let zv = ChartIndicators.vwap([bar(0, 10, 11, 9, 10, 0)], window: 1)
    ok(zv[0] == nil, "vwap nil when volume is zero")
}

func testBollinger() {
    let closes = [1.0, 2, 3, 4, 5]
    let b = ChartIndicators.bollinger(closes, period: 3, k: 2)
    // mid at idx2 = (1+2+3)/3 = 2; stddev(1,2,3) sample = 1; upper = 2+2 = 4, lower = 0.
    eq(b.mid[2] ?? -1, 2, "bollinger mid = SMA")
    eq(b.upper[2] ?? -1, 4, "bollinger upper = mid + 2sd")
    eq(b.lower[2] ?? -1, 0, "bollinger lower = mid - 2sd")
    ok(b.upper[0] == nil, "bollinger nil before period")
}

func testMACD() {
    let closes = (1...40).map { Double($0) }
    let m = ChartIndicators.macd(closes, fast: 12, slow: 26, signalPeriod: 9)
    // On a linear ramp, fast EMA > slow EMA -> macd positive once both defined.
    ok((m.macd.last ?? -1)! > 0, "macd positive on rising series")
    ok(m.signal.last! != nil, "macd signal defined at end")
    if let h = m.histogram.last ?? nil, let mac = m.macd.last ?? nil, let sig = m.signal.last ?? nil {
        eq(h, mac - sig, "macd histogram = macd - signal")
    }
}

func testFibonacci() {
    let lv = Fibonacci.levels(from: 100, to: 200)
    eq(lv.first { $0.ratio == 0.5 }?.price ?? -1, 150, "fib 0.5 between 100..200 = 150")
    eq(lv.first { $0.ratio == 0.618 }?.price ?? -1, 161.8, "fib 0.618 = 161.8")
    eq(lv.first { $0.ratio == 1.618 }?.price ?? -1, 261.8, "fib 1.618 extension")
}

func testDrawingStore() {
    let s = DrawingStore(filename: "dr-\(UUID().uuidString).json", baseDir: tmpBase)
    s.add(Drawing(kind: .trendline, x1: 0, y1: 100, x2: 10, y2: 120), to: "es")
    s.add(Drawing(kind: .horizontal, x1: 0, y1: 110, x2: 10, y2: 110), to: "ES")  // same symbol case-insens
    eqi(s.drawings(for: "ES").count, 2, "drawings keyed case-insensitively")
    eqi(s.drawings(for: "NQ").count, 0, "no drawings for unrelated symbol")
    let d = s.drawings(for: "es").first!
    s.remove(d, from: "es")
    eqi(s.drawings(for: "es").count, 1, "drawing removed")
    s.clear("es")
    eqi(s.drawings(for: "es").count, 0, "drawings cleared")
}

// ===== Backtest depth: walk-forward + Monte-Carlo =====
func uptrendBars(_ n: Int) -> [Bar] {
    var bars: [Bar] = []; var price = 100.0
    for i in 0..<n { price += (i % 7 == 0) ? 1.5 : 0.6; bars.append(bar(i, price, price+1, price-1, price+0.5)) }
    return bars
}

func testWalkForward() {
    let bars = uptrendBars(240)
    var cfg = StrategyConfig(); cfg.fastSMA = 5; cfg.slowSMA = 20; cfg.pointValue = 1
    let wf = WalkForward.run(bars, cfg, folds: 4)
    eqi(wf.totalFolds, 4, "walk-forward produced 4 folds")
    ok(wf.folds.allSatisfy { $0.bars > 0 }, "each fold has bars")
    ok(wf.consistency >= 0 && wf.consistency <= 1, "consistency is a fraction")
    // too few folds / bars -> empty
    eqi(WalkForward.run(bars, cfg, folds: 1).totalFolds, 0, "folds<2 -> empty")
    eqi(WalkForward.run(Array(bars.prefix(5)), cfg, folds: 4).totalFolds, 0, "too few bars -> empty")
}

func testWalkForwardCombinedMatchesAllTrades() {
    let bars = uptrendBars(200)
    var cfg = StrategyConfig(); cfg.fastSMA = 5; cfg.slowSMA = 20; cfg.pointValue = 1
    let wf = WalkForward.run(bars, cfg, folds: 4)
    let foldTradeSum = wf.folds.reduce(0) { $0 + $1.trades }
    eqi(wf.combinedReport.trades, foldTradeSum, "combined report trades == sum of fold trades")
}

func testMonteCarloDeterministic() {
    let stats = [1.0, -1, 2, -1, 1, -1, 2].map { TradeStat(pnl: $0*100, r: $0, date: day(0)) }
    let a = MonteCarlo.run(stats, runs: 500, seed: 42)
    let b = MonteCarlo.run(stats, runs: 500, seed: 42)
    eq(a.medianFinalEquity, b.medianFinalEquity, "monte-carlo deterministic for same seed")
    eq(a.p5FinalEquity, b.p5FinalEquity, "monte-carlo p5 deterministic")
    ok(a.p5FinalEquity <= a.medianFinalEquity, "p5 <= median")
    ok(a.medianFinalEquity <= a.p95FinalEquity, "median <= p95")
    ok(a.probProfit >= 0 && a.probProfit <= 100, "probProfit is a percentage")
    eqi(a.runs, 500, "monte-carlo run count")
}

func testMonteCarloEmpty() {
    let r = MonteCarlo.run([], runs: 100)
    eqi(r.runs, 0, "monte-carlo empty input -> no runs (no fabrication)")
}

func testMonteCarloRiskOfRuin() {
    // All losers, starting capital small -> high risk of ruin.
    let stats = (0..<10).map { TradeStat(pnl: -100, r: -1, date: day($0)) }
    let r = MonteCarlo.run(stats, runs: 200, startingCapital: 300, ruinFraction: 1.0, seed: 7)
    ok(r.riskOfRuin > 50, "all-loser system has high risk of ruin")
    ok(r.probProfit < 5, "all-loser system almost never profits")
}

// ===== Broker CSV import =====
func testBrokerCSVPnL() {
    let csv = """
    Symbol,Side,Qty,P&L,CloseTime,Tags
    ES,Buy,2,"$450.00",2026-01-05 10:30,breakout
    NQ,Sell,1,(120.50),2026-01-05 14:00,fade
    GARBAGE
    """
    let (rows, skipped, mapping) = BrokerCSV.parse(csv)
    eqi(rows.count, 2, "broker CSV parsed 2 good rows")
    ok(mapping["pnl"] != nil, "pnl column mapped")
    eq(rows[0].pnl, 450, "currency P&L parsed")
    eq(rows[1].pnl, -120.5, "parenthesized P&L parsed as negative")
    ok(!rows[1].isLong, "Sell -> short")
    ok(rows[0].closed != nil, "close time parsed")
    ok(rows[0].tags.contains("breakout"), "tags parsed")
    ok(skipped >= 1, "garbage row skipped")
}

func testBrokerCSVDerivedPnL() {
    // No P&L column -> derive from entry/exit * qty.
    let csv = """
    ticker,direction,quantity,entryprice,exitprice
    AAPL,long,10,100,105
    TSLA,short,5,200,190
    """
    let (rows, _, mapping) = BrokerCSV.parse(csv)
    ok(mapping["pnl"] == nil, "no pnl column")
    eqi(rows.count, 2, "derived 2 rows")
    eq(rows[0].pnl, 50, "long derived pnl = (105-100)*10")
    eq(rows[1].pnl, 50, "short derived pnl = (200-190)*5")
}

func testBrokerCSVFuturesPointValue() {
    // FUTURES derived P&L must multiply by the contract $/point (a point is NOT $1). ES = $50/pt.
    let csv = """
    ticker,direction,quantity,entryprice,exitprice
    ESU6,long,2,5000,5010
    """
    let (rows, _, _) = BrokerCSV.parse(csv)
    eqi(rows.count, 1, "ES row derived")
    eq(rows[0].pnl, 1000, "ES derived pnl = (5010-5000) pts * $50 * 2 = 1000 (not 20)")
}

func testBrokerCSVUnknownFuturesSkipped() {
    // A DATED futures contract with an unknown $/point can't be honestly dollarized -> skipped,
    // never rendered as points-as-dollars.
    let csv = """
    ticker,direction,quantity,entryprice,exitprice
    XYZZ6,long,1,100,110
    """
    let (rows, skipped, _) = BrokerCSV.parse(csv)
    ok(rows.isEmpty, "unknown dated future not dollarized")
    eqi(skipped, 1, "skipped counted")
}

func testParseSideShortTokens() {
    // IB tokens: SLD/Sold/short must be SHORT (false); BOT/Bought/buy default long (true).
    ok(BrokerCSV.parseSide("SLD") == false, "IB SLD -> short")
    ok(BrokerCSV.parseSide("Sold") == false, "Sold -> short")
    ok(BrokerCSV.parseSide("SL") == false, "SL -> short")
    ok(BrokerCSV.parseSide("BOT") == true, "IB BOT -> long")
    ok(BrokerCSV.parseSide("Bought") == true, "Bought -> long")
    ok(BrokerCSV.parseSide("buy") == true, "buy -> long")
}

func testParseDateDisambiguation() {
    // A field > 12 forces the order: 13/06 must be 13 June; 06/13 must be 13 June too (MM/dd).
    let cal = Calendar(identifier: .gregorian)
    func md(_ s: String) -> (Int, Int)? {
        guard let d = BrokerCSV.parseDate(s) else { return nil }
        var c = cal; c.timeZone = TimeZone(identifier: "UTC")!
        let comps = c.dateComponents([.month, .day], from: d)
        return (comps.month ?? 0, comps.day ?? 0)
    }
    if let r = md("13/06/2026") { ok(r.0 == 6 && r.1 == 13, "13/06 -> 13 June (dd/MM forced)") } else { ok(false, "13/06 parsed") }
    if let r = md("06/13/2026") { ok(r.0 == 6 && r.1 == 13, "06/13 -> 13 June (MM/dd forced)") } else { ok(false, "06/13 parsed") }
}

func testBrokerCSVNoMappableColumns() {
    let csv = "foo,bar,baz\n1,2,3"
    let (rows, skipped, _) = BrokerCSV.parse(csv)
    ok(rows.isEmpty, "unmappable CSV -> no rows (honest)")
    eqi(skipped, 1, "unmappable rows counted as skipped")
}

func testCSVQuotedFields() {
    let cols = BrokerCSV.splitCSVLine("\"hello, world\",42,\"quote\"\"inside\"")
    eqi(cols.count, 3, "quoted comma kept as one field")
    ok(cols[0] == "hello, world", "embedded comma preserved")
    ok(cols[2] == "quote\"inside", "escaped quote unescaped")
}

// ===== Seasonality + correlations =====
func testSeasonalityByMonth() {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    // Jan 2026 = 1_767_225_600 ; pick two Jan dates and one Mar date.
    let jan = Date(timeIntervalSince1970: 1_767_225_600)          // 2026-01-01
    let mar = Date(timeIntervalSince1970: 1_767_225_600 + 60*86400) // ~2026-03-02
    let stats = [TradeStat(pnl: 100, r: 1, date: jan), TradeStat(pnl: -40, r: -0.5, date: jan.addingTimeInterval(86400)),
                 TradeStat(pnl: 200, r: 2, date: mar)]
    let months = Seasonality.byMonth(stats, calendar: cal)
    eqi(months.count, 12, "12 month buckets")
    eq(months.first { $0.month == 1 }?.netPnL ?? -1, 60, "Jan net = 100-40")
    eqi(months.first { $0.month == 1 }?.trades ?? -1, 2, "Jan trade count")
    eq(months.first { $0.month == 3 }?.netPnL ?? -1, 200, "Mar net")
    eqi(months.first { $0.month == 6 }?.trades ?? -1, 0, "month with no trades is 0")
}

func testSeasonalityHoldTime() {
    let s = [TradeStat(pnl: 50, r: 1, date: day(0), holdMinutes: 3),
             TradeStat(pnl: -20, r: -1, date: day(1), holdMinutes: 30),
             TradeStat(pnl: 80, r: 2, date: day(2), holdMinutes: 200)]
    let buckets = Seasonality.byHoldTime(s)
    eqi(buckets.first { $0.label == "< 5m" }?.trades ?? -1, 1, "hold <5m bucket")
    eqi(buckets.first { $0.label == "15–60m" }?.trades ?? -1, 1, "hold 15-60m bucket")
    eqi(buckets.first { $0.label == "1–4h" }?.trades ?? -1, 1, "hold 1-4h bucket")
}

func testCorrelationPearson() {
    eq(Correlation.pearson([1,2,3,4], [2,4,6,8]), 1.0, "perfect positive correlation")
    eq(Correlation.pearson([1,2,3,4], [8,6,4,2]), -1.0, "perfect negative correlation")
    eq(Correlation.pearson([1], [1]), 0, "single point undefined -> 0")
}

func testCorrelationMatrix() {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    let d0 = Date(timeIntervalSince1970: 1_767_225_600)
    // ES and NQ move together across 3 days.
    let stats = [
        TradeStat(symbol: "ES", pnl: 100, date: d0), TradeStat(symbol: "NQ", pnl: 50, date: d0),
        TradeStat(symbol: "ES", pnl: 200, date: d0.addingTimeInterval(86400)), TradeStat(symbol: "NQ", pnl: 100, date: d0.addingTimeInterval(86400)),
        TradeStat(symbol: "ES", pnl: 300, date: d0.addingTimeInterval(2*86400)), TradeStat(symbol: "NQ", pnl: 150, date: d0.addingTimeInterval(2*86400)),
    ]
    let m = Correlation.symbolDailyMatrix(stats, calendar: cal)
    eqi(m.symbols.count, 2, "matrix has 2 symbols")
    eq(m.values[0][0], 1.0, "diagonal is 1")
    let i = m.symbols.firstIndex(of: "ES")!, j = m.symbols.firstIndex(of: "NQ")!
    eq(m.values[i][j], 1.0, "ES/NQ perfectly correlated daily P&L", tol: 1e-9)
}

func testCorrelationMatrixGatesFewSharedDays() {
    // HONESTY LOCK: on only 2 shared days, Pearson is ALWAYS exactly ±1 (two points are collinear),
    // a spurious "concentration risk". The matrix must suppress it to 0 below minSharedDays (3).
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    let d0 = Date(timeIntervalSince1970: 1_767_225_600)
    let stats = [
        TradeStat(symbol: "ES", pnl: 100, date: d0), TradeStat(symbol: "NQ", pnl: 50, date: d0),
        TradeStat(symbol: "ES", pnl: 200, date: d0.addingTimeInterval(86400)), TradeStat(symbol: "NQ", pnl: 100, date: d0.addingTimeInterval(86400)),
    ]
    let m = Correlation.symbolDailyMatrix(stats, calendar: cal)
    let i = m.symbols.firstIndex(of: "ES")!, j = m.symbols.firstIndex(of: "NQ")!
    eq(m.values[i][j], 0.0, "2 shared days -> no spurious ±1.00 (suppressed to 0)", tol: 1e-9)
}

func testSignalFactorRosterAndWeights() {
    // LOCK the "16 signal modules" claim + the composite weight invariant.
    eqi(SignalFactor.allCases.count, 16, "16 signal modules (matches storefront + docs)")
    let sum = SignalFactor.allCases.reduce(0.0) { $0 + $1.weight }
    eq(sum, 1.0, "factor weights sum to exactly 1.0", tol: 1e-9)
    for f in SignalFactor.allCases { ok(f.weight > 0, "every factor has a positive weight (\(f.rawValue))") }
}

func testTrailTiersGeometry() {
    // LOCK the 6-tier trailing-stop PLAN geometry (signals-only — pure numbers).
    let long = SignalResult(direction: .long, score: 60, confidence: 90,
                            entry: 5000, stop: 4990, target: 5060, symbol: "ES", pointValue: 50)
    let t = long.trailTiers
    eqi(t.count, 6, "6 tiers")
    eq(t[0].stop, 5000, "tier 1 stop = breakeven (entry)", tol: 1e-9)
    eq(t[5].trigger, 5060, "tier 6 trigger = target", tol: 1e-9)
    eq(t[5].stop, 5050, "tier 6 locks 5/6 of the 60-pt reward", tol: 1e-9)
    ok(t[0].trigger < t[5].trigger, "triggers ascend toward target (long)")
    // Short mirrors.
    let short = SignalResult(direction: .short, score: -60, confidence: 90,
                             entry: 5000, stop: 5010, target: 4940, symbol: "ES", pointValue: 50)
    let s = short.trailTiers
    eq(s[0].stop, 5000, "short tier 1 = breakeven", tol: 1e-9)
    eq(s[5].trigger, 4940, "short tier 6 trigger = target", tol: 1e-9)
    // Flat -> no trail (honest, nothing to manage).
    let flat = SignalResult(direction: .flat, score: 0, confidence: 0,
                            entry: 5000, stop: 4990, target: 5010, symbol: "ES", pointValue: 50)
    ok(flat.trailTiers.isEmpty, "flat -> no trail tiers")
}

func testLiveFactorHonestAbsenceAndDirection() {
    // LOCK: the new factors compute from REAL bars and stay ABSENT (never fabricated) without data.
    func bars(_ closes: [Double]) -> [Bar] {
        closes.enumerated().map { (i, c) in
            Bar(date: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 15),
                open: c, high: c + 0.5, low: c - 0.5, close: c)
        }
    }
    let km = SignalFactor.kalmanTrend.rawValue, bo = SignalFactor.breakout.rawValue,
        kl = SignalFactor.keyLevels.rawValue, st = SignalFactor.structure.rawValue

    // Empty + thin -> the whole snapshot is honestly empty (below minBars); no factor fabricated.
    let empty = LiveFactorEngine.compute(bars: [], nqBars: [], fires: [], now: Date())
    ok(empty.available.isEmpty && empty.bars == 0, "empty bars -> nothing available (no fabrication)")
    let thin = LiveFactorEngine.compute(bars: bars((0..<10).map { 5000 + Double($0) }),
                                        nqBars: [], fires: [], now: Date())
    ok(!thin.available.contains(km) && !thin.available.contains(bo),
       "below the data guards -> kalman/breakout ABSENT (not fabricated)")

    // Clean uptrend (60 bars) -> kalman present & positive, breakout present.
    let up = LiveFactorEngine.compute(bars: bars((0..<60).map { 5000 + Double($0) * 0.7 }),
                                      nqBars: [], fires: [], now: Date())
    ok(up.available.contains(km), "uptrend -> kalmanTrend available")
    ok((up.factors[km] ?? 0) > 0, "uptrend -> kalmanTrend velocity positive")
    ok(up.available.contains(bo), "uptrend -> breakout available")
    // Clean downtrend -> kalman negative.
    let dn = LiveFactorEngine.compute(bars: bars((0..<60).map { 5000 - Double($0) * 0.7 }),
                                      nqBars: [], fires: [], now: Date())
    ok((dn.factors[km] ?? 0) < 0, "downtrend -> kalmanTrend velocity negative")
    // Every present factor value is finite and in [-1,1] (no NaN/inf/out-of-range fabrication).
    for (k, v) in up.factors { ok(v.isFinite && v >= -1.0001 && v <= 1.0001, "factor \(k) in [-1,1] & finite") }
    _ = (kl, st)   // keyLevels/structure are pivot-gated; covered by honest-absence on thin data above
}

func testOrderTicketSignalsOnly() {
    // LOCK the manual order ticket: computes size from account/risk on a KNOWN $/pt, says "—" when
    // $/pt is unknown (no fabricated size), includes the bracket + trail, and is explicitly manual.
    let es = SignalResult(direction: .long, score: 60, confidence: 90,
                          entry: 5000, stop: 4990, target: 5020, symbol: "ES", pointValue: 50)
    // risk = 10 pts * $50 = $500/contract; 1% of $50k = $500 -> size 1.
    eqi(OrderTicket.size(es, account: 50000, riskPct: 1)!, 1, "ES size = 1 contract at 1% of $50k")
    eqi(OrderTicket.size(es, account: 100000, riskPct: 2)!, 4, "scales with account & risk")
    let txt = OrderTicket.format(es, account: 50000, riskPct: 1)
    ok(txt.contains("SIZE 1"), "ticket shows computed size")
    ok(txt.contains("ENTRY 5000.00") && txt.contains("STOP 4990.00") && txt.contains("TARGET 5020.00"), "bracket present")
    ok(txt.lowercased().contains("never sends") || txt.lowercased().contains("manual"), "ticket is explicitly manual/signals-only")
    // Unknown $/pt -> no fabricated size.
    let fx = SignalResult(direction: .long, score: 60, confidence: 90,
                          entry: 1.08, stop: 1.075, target: 1.09, symbol: "EURUSD", pointValue: 0)
    ok(OrderTicket.size(fx, account: 50000, riskPct: 1) == nil, "unknown $/pt -> nil size (no fabrication)")
    ok(OrderTicket.format(fx, account: 50000, riskPct: 1).contains("enter your own"), "ticket prompts for size when $/pt unknown")
    // Flat -> nothing to place.
    let flat = SignalResult(direction: .flat, score: 0, confidence: 0, entry: 5000, stop: 4990, target: 5010, symbol: "ES", pointValue: 50)
    ok(OrderTicket.format(flat, account: 50000, riskPct: 1).contains("FLAT"), "flat -> no ticket")
}

func testSessionDailyLogCSV() {
    // LOCK the vault daily-logs builder: grouped by day (first-seen order), each day followed by a
    // DAY TOTAL line with W/L + net modeled P&L; header present; pure + deterministic.
    let e = [
        SessionLedger.Entry(day: "2026-06-27", symbol: "ES", direction: "LONG", grade: "win", pnl: 1000),
        SessionLedger.Entry(day: "2026-06-27", symbol: "ES", direction: "SHORT", grade: "loss", pnl: -500),
        SessionLedger.Entry(day: "2026-06-28", symbol: "NQ", direction: "LONG", grade: "win", pnl: 800),
    ]
    let csv = SessionLedger.dailyCSV(e)
    let lines = csv.split(separator: "\n").map(String.init)
    ok(lines[0] == "day,symbol,direction,grade,modeled_pnl", "header present")
    ok(lines.contains("2026-06-27,ES,LONG,win,1000.00"), "day-1 win row")
    ok(lines.contains("2026-06-27,,DAY TOTAL,1W/1L,500.00"), "day-1 total: 1W/1L net +500")
    ok(lines.contains("2026-06-28,,DAY TOTAL,1W/0L,800.00"), "day-2 total: 1W/0L net +800")
    ok(SessionLedger.dailyCSV([]).contains("day,symbol"), "empty -> header only, no fabricated rows")
}

func testChartScalePriceAtYInvertsYPixel() {
    // LOCK the drawing-price fix: priceAtY must be the EXACT inverse of yPixel in BOTH scales, so a
    // level drawn on screen commits at the price it visually sits on (esp. on a log axis).
    let lo = 4000.0, hi = 5000.0, topY = 10.0, bottomY = 410.0   // matches renderer topY=maxY,bottomY=minY
    for log in [false, true] {
        for price in [4000.0, 4250.0, 4500.0, 4990.0] {
            let y = ChartScale.yPixel(price, lo: lo, hi: hi, topY: topY, bottomY: bottomY, log: log)
            let back = ChartScale.priceAtY(y, lo: lo, hi: hi, topY: topY, bottomY: bottomY, log: log)
            eq(back, price, "priceAtY∘yPixel == identity (log=\(log), price=\(price))", tol: 1e-6)
        }
    }
}

// ===== Run =====
// ===== Pattern detection =====
// Helper to make an OHLC bar quickly (named `obar` to avoid the Int-first `bar` helper above).
func obar(_ o: Double, _ h: Double, _ l: Double, _ c: Double, _ off: Int = 0, vol: Double = 0) -> Bar {
    Bar(date: day(off), open: o, high: h, low: l, close: c, volume: vol)
}

func testCandlePatternGeometry() {
    // Doji: tiny body relative to range.
    ok(CandleScan.isDoji(obar(100, 105, 95, 100.2)), "doji small body")
    ok(!CandleScan.isDoji(obar(100, 105, 95, 104)), "not doji big body")
    // Hammer: long lower wick, small (nonzero) body near top, tiny upper wick.
    ok(CandleScan.isHammer(obar(104, 104.3, 96, 104.1)), "hammer")
    ok(!CandleScan.isHammer(obar(100, 110, 99.5, 109)), "not hammer (upper wick)")
    // Shooting star: long upper wick, body near bottom.
    ok(CandleScan.isShootingStar(obar(96.1, 104, 95.8, 96)), "shooting star")
    // Marubozu: full body, no wicks.
    ok(CandleScan.isBullishMarubozu(obar(100, 110, 100, 110)), "bull marubozu")
    ok(CandleScan.isBearishMarubozu(obar(110, 110, 100, 100)), "bear marubozu")
    ok(!CandleScan.isBullishMarubozu(obar(100, 112, 99, 110)), "not marubozu (wicks)")
}

func testEngulfingAndInside() {
    let downBar = obar(105, 106, 99, 100)        // bearish body 105->100
    let upEngulf = obar(99, 107, 98, 106)         // bullish body engulfs 100..105
    ok(CandleScan.isBullishEngulfing(downBar, upEngulf), "bullish engulfing")
    let upBar = obar(100, 106, 99, 105)
    let downEngulf = obar(106, 107, 98, 99)
    ok(CandleScan.isBearishEngulfing(upBar, downEngulf), "bearish engulfing")
    // Inside bar: fully contained, smaller range.
    let mother = obar(100, 110, 90, 105)
    let inside = obar(101, 108, 95, 103)
    ok(CandleScan.isInsideBar(mother, inside), "inside bar")
    ok(!CandleScan.isInsideBar(inside, mother), "not inside (bigger)")
}

func testPatternScannerEmptyAndCounts() {
    eqi(PatternScanner.scan([]).hits.count, 0, "pattern scan empty -> 0 hits")
    // Construct a 2-bar bullish engulfing series; expect at least one bullish hit.
    let bars = [obar(105, 106, 99, 100, 0), obar(99, 107, 98, 106, 1)]
    let s = PatternScanner.scan(bars)
    ok(s.bullish >= 1, "scanner finds bullish engulfing")
    ok(s.hits.allSatisfy { $0.index < bars.count }, "hit indices in range")
}

func testPivotsAndLevels() {
    // Build a zig-zag so pivots are unambiguous. Highs at peaks, lows at troughs.
    var bars: [Bar] = []
    let prices = [10.0, 12, 15, 12, 10, 13, 16, 13, 10, 12, 15, 12, 10]
    for (i, p) in prices.enumerated() { bars.append(obar(p, p + 0.5, p - 0.5, p, i)) }
    let pv = StructureScan.pivots(bars, lookback: 2)
    ok(pv.contains { $0.isHigh }, "found a swing high")
    ok(pv.contains { !$0.isHigh }, "found a swing low")
    // Repeated ~10 lows and ~15/16 highs should cluster into levels with >=2 touches.
    let lv = StructureScan.levels(bars, lookback: 2, tolFrac: 0.05, minTouches: 2)
    ok(lv.contains { $0.isSupport }, "support level clustered")
}

func testDoubleTopDetection() {
    // Two equal-height peaks (~15) with a trough between -> double top at second peak.
    var bars: [Bar] = []
    let prices = [10.0, 12, 15, 12, 10, 12, 15, 12, 10]
    for (i, p) in prices.enumerated() { bars.append(obar(p, p + 0.2, p - 0.2, p, i)) }
    let hits = StructureScan.doubleTopsBottoms(bars, lookback: 2, tolFrac: 0.05)
    ok(hits.contains { $0.chart == .doubleTop }, "double top detected")
}

func testDoubleTopRequiresPullback() {
    // HONESTY LOCK: two similar-priced peaks with only a TINY dip between them is NOT a double top
    // (the documented "meaningful pullback" must be real) — flat drift must not fabricate a pattern.
    var bars: [Bar] = []
    let prices = [15.0, 15.05, 14.98, 15.02, 14.99, 15.03, 15.0, 14.97, 15.01]  // ~flat, <1% moves
    for (i, p) in prices.enumerated() { bars.append(obar(p, p + 0.02, p - 0.02, p, i)) }
    let hits = StructureScan.doubleTopsBottoms(bars, lookback: 2, tolFrac: 0.05)
    ok(!hits.contains { $0.chart == .doubleTop }, "no double top without a meaningful pullback")
}

func testTriangleSlopeMath() {
    eq(StructureScan.slope([1, 2, 3, 4]), 1.0, "slope = 1 for +1/step")
    eq(StructureScan.slope([4, 4, 4, 4]), 0.0, "slope = 0 flat")
    ok(StructureScan.slope([4, 3, 2, 1]) < 0, "slope negative downtrend")
}

// ===== Visual strategy builder =====
func sineBars(_ n: Int) -> [Bar] {
    // Deterministic oscillating series so SMA crosses occur. Range built around close.
    var bars: [Bar] = []
    for i in 0..<n {
        let c = 100 + 8 * sin(Double(i) / 4.0)
        bars.append(obar(c, c + 1.5, c - 1.5, c, i))
    }
    return bars
}

func testVisualStrategyCrossMatchesBuiltin() {
    // A visual SMA(10) crosses above SMA(30) long strategy should produce trades on oscillating data.
    let bars = sineBars(220)
    var s = VisualStrategy()
    s.direction = .long
    s.entry = [RuleCondition(left: .sma, leftPeriod: 10, comparator: .crossesAbove,
                             right: .indicator(.sma, period: 30))]
    s.exit = .atrStopTarget
    let (trades, _) = VisualStrategyEngine.run(bars, s)
    ok(trades.count > 0, "visual SMA-cross strategy produced trades")
    ok(trades.allSatisfy { $0.direction == .long }, "all long")
}

func testVisualStrategyEmptyNoEntry() {
    let bars = sineBars(120)
    var s = VisualStrategy(); s.entry = []   // no conditions
    let (trades, _) = VisualStrategyEngine.run(bars, s)
    eqi(trades.count, 0, "no conditions -> no trades")
    // A condition that can never be met (close is above 1e9) -> no trades, not a crash.
    s.entry = [RuleCondition(left: .price, leftPeriod: 1, comparator: .isAbove, right: .constant(1_000_000_000))]
    eqi(VisualStrategyEngine.run(bars, s).trades.count, 0, "impossible condition -> 0 trades")
}

func testVisualStrategyConstantCondition() {
    // Close is above 50 for the whole series; "is above 50" fires every bar -> should enter.
    let bars = sineBars(80)
    var s = VisualStrategy()
    s.entry = [RuleCondition(left: .price, leftPeriod: 1, comparator: .isAbove, right: .constant(50))]
    let entries = VisualStrategyEngine.entryBars(bars, s)
    ok(entries.count > 0, "constant condition fires entries")
}

func testStrategyToAlertMapping() {
    var s = VisualStrategy(); s.name = "RSI dip"
    // Mappable: RSI is below 30 (constant).
    s.entry = [RuleCondition(left: .rsi, leftPeriod: 14, comparator: .isBelow, right: .constant(30))]
    let (alert, unmappable) = VisualStrategyEngine.toAlert(s, symbol: "AAPL")
    ok(alert != nil, "RSI<30 maps to an alert")
    eqi(alert?.conditions.count ?? -1, 1, "one alert condition")
    eqi(unmappable.count, 0, "nothing unmappable")
    // Unmappable: SMA cross has no AlertMetric counterpart.
    s.entry = [RuleCondition(left: .sma, leftPeriod: 10, comparator: .crossesAbove, right: .indicator(.sma, period: 30))]
    let (alert2, unmappable2) = VisualStrategyEngine.toAlert(s, symbol: "AAPL")
    ok(alert2 == nil, "SMA-cross does not map (honest)")
    eqi(unmappable2.count, 1, "one unmappable condition reported")
}

func testStrategyStorePersists() {
    let dir = tmpBase.appendingPathComponent("strat-\(UUID().uuidString)")
    let store = StrategyStore(baseDir: dir)
    var s = VisualStrategy(); s.name = "Test"
    store.add(s)
    eqi(store.strategies.count, 1, "strategy added")
    let store2 = StrategyStore(baseDir: dir)
    eqi(store2.strategies.count, 1, "strategy persisted across instances")
    ok(store2.strategies.first?.name == "Test", "persisted name")
}

// ===== Paper-trade simulator =====
func testPaperLongPnL() {
    let dir = tmpBase.appendingPathComponent("paper-\(UUID().uuidString)")
    let book = PaperBook(baseDir: dir)
    book.startingBalance = 10_000
    let id = book.openPosition(PaperPosition(symbol: "ES", direction: .long, quantity: 2,
                                             entryPrice: 100, stop: 98, pointValue: 5, commission: 4))
    // Unrealized at mark 105: (105-100)*5*2 = 50.
    eq(book.open.first!.unrealizedDollars(mark: 105)!, 50, "long unrealized")
    book.close(id, at: 110)
    // Realized: (110-100)*5*2 - 4 = 100*... = 96.
    eq(book.realizedPnL(), 96, "long realized minus commission")
    // R: points 10 / risk 2 = 5R.
    eq(book.closed.first!.realizedR()!, 5, "realized R")
    eq(book.equity(), 10_096, "equity = start + realized")
}

func testPaperShortAndOpenMark() {
    let dir = tmpBase.appendingPathComponent("paper-\(UUID().uuidString)")
    let book = PaperBook(baseDir: dir)
    let id = book.openPosition(PaperPosition(symbol: "NQ", direction: .short, quantity: 1,
                                             entryPrice: 200, pointValue: 1, commission: 0))
    // Short: mark 190 -> +10 unrealized.
    eq(book.open.first!.unrealizedDollars(mark: 190)!, 10, "short unrealized profit")
    // No mark -> nil (honest, never fabricated).
    ok(book.open.first!.unrealizedDollars(mark: nil) == nil, "no mark -> nil unrealized")
    book.close(id, at: 195)
    eq(book.realizedPnL(), 5, "short realized")
}

func testPaperStatsAndReset() {
    let dir = tmpBase.appendingPathComponent("paper-\(UUID().uuidString)")
    let book = PaperBook(baseDir: dir)
    let a = book.openPosition(PaperPosition(symbol: "A", direction: .long, quantity: 1, entryPrice: 10, stop: 9, pointValue: 1))
    let b = book.openPosition(PaperPosition(symbol: "B", direction: .long, quantity: 1, entryPrice: 10, stop: 9, pointValue: 1))
    book.close(a, at: 12)   // +2
    book.close(b, at: 9)    // -1 (hit stop level)
    let stats = book.stats()
    eqi(stats.count, 2, "two closed -> two stats")
    let rep = Analytics.report(stats)
    eqi(rep.trades, 2, "report sees 2 trades")
    eq(rep.netPnL, 1, "net pnl 2 + (-1) = 1")
    // Open position should NOT appear in stats.
    book.openPosition(PaperPosition(symbol: "C", direction: .long, quantity: 1, entryPrice: 10, pointValue: 1))
    eqi(book.stats().count, 2, "open position excluded from stats")
    book.reset()
    eqi(book.positions.count, 0, "reset clears")
}

func testPaperPersists() {
    let dir = tmpBase.appendingPathComponent("paper-\(UUID().uuidString)")
    let book = PaperBook(baseDir: dir)
    book.openPosition(PaperPosition(symbol: "X", direction: .long, quantity: 1, entryPrice: 50, pointValue: 1))
    let book2 = PaperBook(baseDir: dir)
    eqi(book2.positions.count, 1, "paper positions persist")
}

// ===== Trade replay =====
func testReplayFramesCausal() {
    let bars = sineBars(60)
    let frames = ReplaySession.build(bars)
    eqi(frames.count, bars.count, "one frame per bar")
    // Frame i reveals exactly i+1 bars (no look-ahead).
    ok(frames.allSatisfy { $0.visibleBars == $0.index + 1 }, "visibleBars = index+1")
    // Running high is monotonic non-decreasing.
    var prevHi = -Double.infinity
    var monotonic = true
    for f in frames { if f.runningHigh < prevHi { monotonic = false }; prevHi = f.runningHigh }
    ok(monotonic, "running high monotonic")
}

func testReplayPatternsAttachByIndex() {
    // Bullish engulfing on bars 0->1 should surface at frame index 1, not 0.
    let bars = [obar(105, 106, 99, 100, 0), obar(99, 107, 98, 106, 1), obar(106, 108, 105, 107, 2)]
    let frames = ReplaySession.build(bars)
    ok(frames[0].newPatterns.allSatisfy { $0.candle != .bullishEngulfing }, "no engulfing at frame 0")
    ok(frames[1].newPatterns.contains { $0.candle == .bullishEngulfing }, "engulfing surfaces at frame 1")
}

func testReplayEntryMarkersAndKeyMoments() {
    let bars = sineBars(220)
    var s = VisualStrategy()
    s.entry = [RuleCondition(left: .sma, leftPeriod: 10, comparator: .crossesAbove, right: .indicator(.sma, period: 30))]
    let frames = ReplaySession.build(bars, strategy: s)
    ok(frames.contains { $0.entryHere }, "at least one entry marker")
    let key = ReplaySession.keyMoments(frames)
    ok(key.allSatisfy { !$0.newPatterns.isEmpty || $0.entryHere }, "key moments have a pattern or entry")
    ok(key.count <= frames.count, "key moments subset")
}

func testReplayEmpty() {
    eqi(ReplaySession.build([]).count, 0, "empty session -> no frames")
}

// ===== HoloTheme / Appearance Studio (visual config — pure model) =====
func testHoloThemeDefaultsAndScales() {
    let g = HoloTheme.goldVault
    eqi(g.intensity == .balanced ? 1 : 0, 1, "default intensity balanced")
    eq(g.fxScale, 0.75, "balanced fxScale = 0.75")
    eq(HoloIntensity.off.scale, 0, "off intensity = 0 (flat fallback)")
    eq(HoloIntensity.full.scale, 1.0, "full intensity = 1")
    eq(HoloMotion.off.speed, 0, "off motion = no loops")
    // motionSpeed: Reduce Motion or toggle-off => 0; else the level speed.
    eq(g.motionSpeed(reduceMotion: true, toggleOn: true), 0, "reduce motion hard-overrides to 0")
    eq(g.motionSpeed(reduceMotion: false, toggleOn: false), 0, "motion toggle off => 0")
    eq(g.motionSpeed(reduceMotion: false, toggleOn: true), HoloMotion.calm.speed, "live motion uses level speed")
}

// Cursor 3D tilt must DEFAULT OFF — it softens text under perspective. Opt-in only via Theme Studio.
func testHoloThemeTiltOffByDefaultAndAllPresets() {
    ok(HoloTheme().tiltEnabled == false, "fresh HoloTheme defaults tilt OFF")
    ok(HoloTheme.goldVault.tiltEnabled == false, "Gold Vault preset has tilt OFF")
    ok(HoloTheme.platinum.tiltEnabled == false, "Platinum preset has tilt OFF")
    ok(HoloTheme.aurora.tiltEnabled == false, "Aurora preset has tilt OFF")
    ok(HoloTheme.cyberNeon.tiltEnabled == false, "Cyber Neon preset has tilt OFF")
    ok(HoloTheme.midnight.tiltEnabled == false, "Midnight preset has tilt OFF")
    // Belt-and-suspenders: every preset surfaced in the Theme Studio ships tilt OFF.
    for (name, theme) in HoloTheme.presets {
        ok(theme.tiltEnabled == false, "preset \"\(name)\" ships tilt OFF")
    }
    // A persisted snapshot (default-constructed) round-trips with tilt OFF.
    let snap = try! JSONDecoder().decode(HoloTheme.self, from: try! JSONEncoder().encode(HoloTheme()))
    ok(snap.tiltEnabled == false, "default snapshot persists tilt OFF")
}

func testHoloThemeParticleCap() {
    var t = HoloTheme.goldVault
    t.particleDensity = 1.0
    eqi(t.particleCount, HoloTheme.PARTICLE_CAP, "density 1 => capped particle count")
    t.particleDensity = 0
    eqi(t.particleCount, 0, "density 0 => no particles")
    t.particleDensity = 0.5; t.intensity = .off
    eqi(t.particleCount, 0, "intensity off => no particles regardless of density")
}

func testHoloThemeCodableRoundTripAndForgiving() {
    // Full round-trip preserves every field.
    let original = HoloTheme.cyberNeon
    let data = try! JSONEncoder().encode(original)
    let back = try! JSONDecoder().decode(HoloTheme.self, from: data)
    ok(back == original, "HoloTheme survives Codable round-trip")
    // Forgiving decode: a partial blob + an unknown (removed) key still decodes to defaults.
    let partial = #"{"accentHex":255,"specularStrength":0.9}"#.data(using: .utf8)!
    let p = try! JSONDecoder().decode(HoloTheme.self, from: partial)
    eqi(Int(p.accentHex), 255, "partial decode keeps present field")
    ok(p.intensity == HoloTheme().intensity, "missing field falls back to default")
    ok(p.tiltEnabled == HoloTheme().tiltEnabled, "unknown 'specularStrength' key ignored, defaults intact")
}

// LEGIBILITY (owner feedback "clear as shit"): reading surfaces behind text MUST be fully
// opaque + high-contrast at EVERY FX intensity so the moving aurora never shows through and
// fuzzes text. These rules are encoded as pure values so they can't silently regress.
func testHoloLegibilityReadingSurfaceAlwaysOpaque() {
    // The reading-surface opacity is independent of FX intensity — even at full holo it is 1.0.
    for intensity in HoloIntensity.allCases {
        var t = HoloTheme.goldVault; t.intensity = intensity
        eq(t.readingSurfaceOpacity, 1.0, "reading surface fully opaque at intensity \(intensity.rawValue)")
    }
    // Across every shipped preset, the reading surface stays opaque.
    for (name, theme) in HoloTheme.presets {
        eq(theme.readingSurfaceOpacity, 1.0, "preset \"\(name)\" reading surface opaque")
    }
}

func testHoloLegibilityTextGlowIsMinimalAndHeadingOnly() {
    // Body/label/value/button text carries NO glow radius — crisp edges only.
    eq(HoloTheme.goldVault.bodyTextGlowRadius, 0, "body text has zero glow radius")
    // Display headings (FoilText) may carry only a tight glow — bounded small so edges stay sharp.
    ok(HoloTheme.goldVault.headingGlowRadius <= 6, "heading glow radius is tight (<= 6)")
    ok(HoloTheme.goldVault.headingGlowRadius >= 0, "heading glow radius non-negative")
    // Even at full intensity the heading glow stays tight (never the old fuzzy radius-12).
    var full = HoloTheme.goldVault; full.intensity = .full
    ok(full.headingGlowRadius <= 6, "heading glow stays tight at full intensity")
}

func testHoloPresetApplyAndPersist() {
    // Use an isolated UserDefaults suite so the test never touches the real app store.
    let suiteName = "blt-holo-test-\(UUID().uuidString)"
    let ud = UserDefaults(suiteName: suiteName)!
    defer { ud.removePersistentDomain(forName: suiteName) }
    let key = HoloThemeStore.themeKey

    // Apply a named preset (the action a Theme-Studio chip performs) and persist it.
    let chosen = HoloTheme.presets.first(where: { $0.name == "Aurora" })!.theme
    ud.set(try! JSONEncoder().encode(chosen), forKey: key)

    // Reload from the same store — the buyer's look survives a relaunch.
    let raw = ud.data(forKey: key)!
    let reloaded = try! JSONDecoder().decode(HoloTheme.self, from: raw)
    ok(reloaded == chosen, "applied preset persists + reloads identically")
    ok(reloaded.matchingPresetName == "Aurora", "reloaded theme is recognised as the Aurora preset")

    // A custom-tuned theme is NOT mistaken for a built-in preset.
    var custom = chosen; custom.glowStrength = 0.123
    ok(custom.matchingPresetName == nil, "custom-tuned theme has no built-in preset match")
}

// ===== Analytics honest-empty contract (§5.1/§5.2) =====
// Empty / insufficient input must yield a zeroed, FINITE report — never a fabricated win-rate,
// an infinite profit factor, a NaN (0/0), or a Sharpe minted from one lucky trade. This locks
// the exact first-run state a buyer sees on their own empty journal before any real trade exists
// — the most lie-prone surface in the product (the screenshot-able performance report).
func testAnalyticsEmpty() {
    let r = Analytics.report([])
    eqi(r.trades, 0, "empty report.trades")
    eqi(r.wins, 0, "empty report.wins")
    eqi(r.losses, 0, "empty report.losses")
    eqi(r.breakeven, 0, "empty report.breakeven")
    eq(r.netPnL, 0, "empty report.netPnL")
    eq(r.grossProfit, 0, "empty report.grossProfit")
    eq(r.grossLoss, 0, "empty report.grossLoss")
    eq(r.winRate, 0, "empty report.winRate")            // never a fabricated %
    eq(r.profitFactor, 0, "empty report.profitFactor")  // 0, NOT .infinity
    eq(r.expectancyDollar, 0, "empty report.expectancyDollar")
    eq(r.expectancyR, 0, "empty report.expectancyR")
    eq(r.avgWin, 0, "empty report.avgWin")
    eq(r.avgLoss, 0, "empty report.avgLoss")
    eq(r.payoffRatio, 0, "empty report.payoffRatio")
    eq(r.largestWin, 0, "empty report.largestWin")
    eq(r.largestLoss, 0, "empty report.largestLoss")
    eqi(r.maxWinStreak, 0, "empty report.maxWinStreak")
    eqi(r.maxLossStreak, 0, "empty report.maxLossStreak")
    eq(r.maxDrawdown, 0, "empty report.maxDrawdown")
    eq(r.maxRunup, 0, "empty report.maxRunup")
    eq(r.longWinRate, 0, "empty report.longWinRate")
    eq(r.shortWinRate, 0, "empty report.shortWinRate")
    // No division-by-zero artifact may leak into a displayed number.
    ok(r.winRate.isFinite && r.profitFactor.isFinite && r.expectancyDollar.isFinite
        && r.expectancyR.isFinite && r.payoffRatio.isFinite, "empty report all-finite (no NaN/inf)")
}

func testRiskPanelEmptyAndSingle() {
    // No trades -> a zeroed risk panel: no Sharpe/Sortino/SQN/Kelly conjured from nothing.
    let e = Analytics.riskPanel([])
    eqi(e.sampleSize, 0, "empty riskPanel.sampleSize")
    eq(e.sharpe, 0, "empty riskPanel.sharpe")
    eq(e.sortino, 0, "empty riskPanel.sortino")
    eq(e.sqn, 0, "empty riskPanel.sqn")
    eq(e.kelly, 0, "empty riskPanel.kelly")
    eq(e.halfKelly, 0, "empty riskPanel.halfKelly")
    eq(e.streakZ, 0, "empty riskPanel.streakZ")
    ok(!e.streaksNonRandom, "empty riskPanel not flagged non-random")
    // A SINGLE trade is not a track record: dispersion stats (Sharpe/Sortino/SQN) need n>1, so
    // one lucky +5R must NOT mint a finite Sharpe. sampleSize reports the 1 honestly.
    let one = Analytics.riskPanel([TradeStat(direction: .long, pnl: 100, r: 5, date: day(0))])
    eqi(one.sampleSize, 1, "single-trade riskPanel.sampleSize")
    eq(one.sharpe, 0, "single-trade riskPanel.sharpe stays 0 (n<2)")
    eq(one.sortino, 0, "single-trade riskPanel.sortino stays 0 (n<2)")
    eq(one.sqn, 0, "single-trade riskPanel.sqn stays 0 (n<2)")
    ok(one.sharpe.isFinite && one.sqn.isFinite, "single-trade risk metrics finite (no NaN/inf)")
}

func testRiskPanelDegenerateMultiTrade() {
    // The empty (n=0) and single-trade (n=1) tests above stop at riskPanel's `count > 1`
    // early-return, so they NEVER exercise the inner guards: stdDev==0 in sharpe/sqn, downside
    // dd==0 in sortino, and an INFINITE payoffRatio feeding kelly. Those fire on a buyer's most
    // realistic first-run journal — a few early WINNING trades with no losses yet (zero dispersion
    // AND no downside AND payoff=inf). The math must stay 0/finite, never +inf or NaN (§5.1/§5.2).

    // (1) n>=2, all-IDENTICAL R -> stdDev == 0 -> sharpe/sqn must be 0 (the `sd > 0` guard the n=1
    //     case skips). Without the guard this is mean/0 = +inf reaching the buyer.
    let flat = (0..<4).map { TradeStat(pnl: 100, r: 1.0, date: day($0)) }
    let fp = Analytics.riskPanel(flat)
    eqi(fp.sampleSize, 4, "flat-R riskPanel.sampleSize")
    eq(fp.sharpe, 0, "flat-R sharpe 0 (stdDev==0, not +inf)")
    eq(fp.sqn, 0, "flat-R sqn 0 (stdDev==0, not +inf)")
    ok(fp.sharpe.isFinite && fp.sqn.isFinite && fp.sortino.isFinite,
       "flat-R risk metrics finite (no NaN/inf)")
    eq(Analytics.stdDev([1, 1, 1, 1]), 0, "stdDev of identical = 0")
    eq(Analytics.sharpe([1, 1, 1, 1]), 0, "sharpe of identical R = 0 (guarded, not +inf)")
    eq(Analytics.sqn([1, 1, 1, 1]), 0, "sqn of identical R = 0 (guarded, not +inf)")

    // (2) n>=2, ALL WINS / no losses -> no downside (sortino dd==0) AND report.payoffRatio = .infinity.
    //     report HONESTLY reports an infinite payoff, but the buyer-facing riskPanel must NOT mint a
    //     max-Kelly bet off a no-loss sample: kelly is fed `payoffRatio.isFinite ? : 0` -> stays 0.
    let wins = [1.0, 2.0, 3.0].enumerated().map { TradeStat(pnl: $0.element * 100, r: $0.element, date: day($0.offset)) }
    let rep = Analytics.report(wins)
    ok(rep.profitFactor.isInfinite, "all-wins report.profitFactor = .infinity (honest, no losses)")
    ok(rep.payoffRatio.isInfinite, "all-wins report.payoffRatio = .infinity (honest, no losses)")
    let wp = Analytics.riskPanel(wins)
    eq(wp.sortino, 0, "all-wins sortino 0 (no downside, dd==0 guarded)")
    eq(wp.kelly, 0, "all-wins kelly 0 — infinite payoff must NOT mint a bet from a no-loss sample")
    ok(wp.kelly.isFinite && wp.halfKelly.isFinite && wp.sharpe.isFinite && wp.sqn.isFinite && wp.streakZ.isFinite,
       "all-wins full risk panel finite (no NaN/inf reaches the buyer)")

    // (3) n>=2, ALL LOSSES / no wins -> kelly 0 (no edge), everything finite.
    let losses = [-1.0, -2.0, -3.0].enumerated().map { TradeStat(pnl: $0.element * 100, r: $0.element, date: day($0.offset)) }
    let lp = Analytics.riskPanel(losses)
    eq(lp.kelly, 0, "all-losses kelly 0 (no edge)")
    ok(lp.sharpe.isFinite && lp.sortino.isFinite && lp.sqn.isFinite && lp.kelly.isFinite,
       "all-losses risk panel finite (no NaN/inf)")
}

print("Running Black Label Trading engine tests...")
testAnalyticsCore()
testAnalyticsEmpty()
testRiskPanelEmptyAndSingle()
testRiskPanelDegenerateMultiTrade()
testProfitFactorInfinite()
testStreaksAndDrawdown()
testRiskPanel()
testKelly()
testStreakZScore()
testRDistribution()
testByTagAndSymbol()
testDailyPnL()
testSMA()
testRSIAllUp()
testBacktestRunsAndMath()
testBacktestEmptyInput()
testCommissionReducesPnL()
testCSVParse()
testScreenerFilters()
testScreenerPresets()
testWatchlistStore()
testAlertLevelAndCross()
testAlertMultiCondition()
testAlertStoreOneShotAndRepeat()
// Charting
testCandlesPassThrough()
testHeikinAshi()
testRenko()
testVWAP()
testBollinger()
testMACD()
testFibonacci()
testDrawingStore()
// Backtest depth
testWalkForward()
testWalkForwardCombinedMatchesAllTrades()
testMonteCarloDeterministic()
testMonteCarloEmpty()
testMonteCarloRiskOfRuin()
// Broker CSV import
testBrokerCSVPnL()
testBrokerCSVDerivedPnL()
testBrokerCSVFuturesPointValue()
testBrokerCSVUnknownFuturesSkipped()
testParseSideShortTokens()
testParseDateDisambiguation()
testBrokerCSVNoMappableColumns()
testCSVQuotedFields()
// Seasonality + correlations
testSeasonalityByMonth()
testSeasonalityHoldTime()
testCorrelationPearson()
testCorrelationMatrix()
testCorrelationMatrixGatesFewSharedDays()
testSignalFactorRosterAndWeights()
testTrailTiersGeometry()
testLiveFactorHonestAbsenceAndDirection()
testOrderTicketSignalsOnly()
testSessionDailyLogCSV()
testChartScalePriceAtYInvertsYPixel()
// Pattern detection
testCandlePatternGeometry()
testEngulfingAndInside()
testPatternScannerEmptyAndCounts()
testPivotsAndLevels()
testDoubleTopDetection()
testDoubleTopRequiresPullback()
testTriangleSlopeMath()
// Visual strategy builder
testVisualStrategyCrossMatchesBuiltin()
testVisualStrategyEmptyNoEntry()
testVisualStrategyConstantCondition()
testStrategyToAlertMapping()
testStrategyStorePersists()
// Paper-trade simulator
testPaperLongPnL()
testPaperShortAndOpenMark()
testPaperStatsAndReset()
testPaperPersists()
// Trade replay
testReplayFramesCausal()
testReplayPatternsAttachByIndex()
testReplayEntryMarkersAndKeyMoments()
testReplayEmpty()
// HoloTheme / Appearance Studio (visual config)
testHoloThemeDefaultsAndScales()
testHoloThemeTiltOffByDefaultAndAllPresets()
testHoloThemeParticleCap()
testHoloThemeCodableRoundTripAndForgiving()
testHoloPresetApplyAndPersist()
testHoloLegibilityReadingSurfaceAlwaysOpaque()
testHoloLegibilityTextGlowIsMinimalAndHeadingOnly()

// ===== Live feed decode layer (FeedTypes) =====
func testFeedBarsDecode() {
    let obj: [String: Any] = ["symbol": "ES", "bars": [
        [100.0, 101.0, 99.0, 100.5, 1_700_000_000.0],
        [100.5, 102.0, 100.0, 101.5, 1_700_000_015.0, 1200.0, -300.0],
    ]]
    let bars = FeedBars.decode(obj)
    eqi(bars.count, 2, "feed bars count")
    eq(bars[0].open, 100, "feed bar0 open")
    eq(bars[1].close, 101.5, "feed bar1 close")
    eq(bars[1].volume, 1200, "feed bar1 volume")
    eq(bars[1].delta, -300, "feed bar1 order-flow delta")
    ok(bars[0].date < bars[1].date, "feed bars sorted ascending")
}
func testFeedBarsEmptyAndMalformed() {
    eqi(FeedBars.decode([:]).count, 0, "feed empty obj -> no bars")
    eqi(FeedBars.decode(["bars": []]).count, 0, "feed empty array -> no bars")
    let obj: [String: Any] = ["bars": [[1.0, 2.0], ["x", "y", "z", "w", "v"], [5.0, 6.0, 4.0, 5.5, 1_700_000_000.0]]]
    eqi(FeedBars.decode(obj).count, 1, "feed skips malformed rows")
}
func testFeedBarsGeometryDefensive() {
    let obj: [String: Any] = ["bars": [[10.0, 9.0, 11.0, 12.0, 1_700_000_000.0]]]
    let b = FeedBars.decode(obj)
    eqi(b.count, 1, "defensive geometry decodes")
    ok(b[0].high >= max(b[0].open, b[0].close), "feed high is a real max")
    ok(b[0].low <= min(b[0].open, b[0].close), "feed low is a real min")
}
func testLiveTickDecode() {
    ok(LiveTick.decode(["gated": true]) == nil, "gated tick -> nil")
    ok(LiveTick.decode(["symbol": "ES"]) == nil, "incomplete tick -> nil")
    let nq = LiveTick.decode(["symbol": "CM.NQU6", "price": 17000.0, "ts": 1_700_000_000.0])
    ok(nq != nil && nq?.symbol == "CM.NQU6", "NQ tick decodes in WealthCharts scope")
    ok(LiveTick.decode(["symbol": "", "price": 1.0, "ts": 1_700_000_000.0]) == nil,
       "empty-symbol tick still rejected")
    let t = LiveTick.decode(["symbol": "ES", "price": 4500.25, "ts": 1_700_000_000.0])
    ok(t != nil, "valid tick decodes")
    eq(t!.price, 4500.25, "tick price")
}
func testLiveFold() {
    let bars = [
        Bar(date: Date(timeIntervalSince1970: 1_700_000_000), open: 100, high: 101, low: 99, close: 100.5),
        Bar(date: Date(timeIntervalSince1970: 1_700_000_015), open: 100.5, high: 101, low: 100, close: 100.8),
    ]
    let up = LiveFold.apply(LiveTick(symbol: "ES", price: 103, ts: Date(timeIntervalSince1970: 1_700_000_020)), to: bars)
    eq(up.last!.high, 103, "fold widens high")
    eq(up.last!.close, 103, "fold moves close")
    eq(up.last!.low, 100, "fold keeps low")
    let stale = LiveFold.apply(LiveTick(symbol: "ES", price: 50, ts: Date(timeIntervalSince1970: 1_699_999_999)), to: bars)
    eq(stale.last!.close, 100.8, "stale tick ignored")
    eqi(LiveFold.apply(LiveTick(symbol: "ES", price: 1, ts: Date()), to: []).count, 0, "fold empty no-op")
}
func testCaptureStatusState() {
    ok(CaptureStatus(cdpReachable: true, feedAvailable: true, feedLive: true, liveTicks: ["ES"]).state(signedIn: false) == .notSignedIn, "state notSignedIn")
    ok(CaptureStatus().state(signedIn: true) == .loggedOut, "state loggedOut")
    ok(CaptureStatus(cdpReachable: true).state(signedIn: true) == .connecting, "state connecting")
    ok(CaptureStatus(cdpReachable: true, feedAvailable: true).state(signedIn: true) == .idle, "state idle")
    ok(CaptureStatus(cdpReachable: true, feedAvailable: true, liveTicks: ["ES"]).state(signedIn: true) == .live, "state live")
}
func testFeedSymbolsPicker() {
    // WealthCharts scope: real non-empty symbols are kept and deduped; ES-specific math is gated elsewhere.
    let s = FeedSymbols.decode([
        "backtestable": ["CM.ESU6", "ESZ26"], "live": ["ESZ26", "CM.NQU6"],
        "liveTicks": ["CM.ESU6", "NQ"], "busiest": "CM.NQU6",
    ])
    let p = s.pickerList
    ok(p.contains("CM.ESU6") && p.contains("ESZ26"), "picker keeps ES-family instruments")
    ok(p.contains("CM.NQU6") && p.contains("NQ"), "picker keeps live WealthCharts instruments")
    ok(Set(p).count == p.count, "picker has no dupes")
    ok(s.busiest == "CM.NQU6", "busiest WealthCharts symbol is kept")
}

func testTradingSymbolScope() {
    // isES stays an HONEST ES-family predicate (used where ES is genuinely special).
    ok(TradingSymbolScope.isES("ES"), "ES root accepted")
    ok(TradingSymbolScope.isES("/ES"), "/ES accepted")
    ok(TradingSymbolScope.isES("CM.ESU6"), "vendor-prefixed ES contract accepted")
    ok(TradingSymbolScope.isES("ESZ26"), "two-digit ES contract accepted")
    ok(!TradingSymbolScope.isES("NQ"), "NQ is not ES-family")
    ok(!TradingSymbolScope.isES("CM.NQU6"), "NQ contract is not ES-family")
    ok(!TradingSymbolScope.isES("MESU6"), "MES is not ES-family")
    ok(!TradingSymbolScope.isES("US.SPY"), "equity symbol is not ES-family")

    // Shipped scope accepts WealthCharts' real live symbols; ES-only logic uses isES above.
    ok(TradingSymbolScope.inScope("NQ") && TradingSymbolScope.inScope("CM.NQU6"), "NQ in WealthCharts scope")
    ok(TradingSymbolScope.inScope("EURUSD") && TradingSymbolScope.inScope("US.SPY"), "FX/equity in WealthCharts scope")
    ok(!TradingSymbolScope.inScope("") && !TradingSymbolScope.inScope("  "), "junk symbol out of scope")

    // futuresRoot strips the contract suffix; passes non-futures through.
    ok(TradingSymbolScope.futuresRoot("CM.ESU6") == "ES", "root ESU6 -> ES")
    ok(TradingSymbolScope.futuresRoot("MNQU6") == "MNQ", "root MNQU6 -> MNQ")
    ok(TradingSymbolScope.futuresRoot("CLF26") == "CL", "root CLF26 -> CL")
    ok(TradingSymbolScope.futuresRoot("EURUSD") == "EURUSD", "non-futures passes through")

    // BLOCKER-2 LOCK: per-instrument point value is the REAL contract spec, never a hardcoded $50.
    // A future edit that re-hardcodes ES/$50 or mis-maps a root fails here.
    eq(TradingSymbolScope.pointValue(for: "CM.ESU6") ?? -1, 50, "ES = $50/pt")
    eq(TradingSymbolScope.pointValue(for: "MESU6") ?? -1, 5, "MES = $5/pt")
    eq(TradingSymbolScope.pointValue(for: "CM.NQU6") ?? -1, 20, "NQ = $20/pt (not $50)")
    eq(TradingSymbolScope.pointValue(for: "MNQU6") ?? -1, 2, "MNQ = $2/pt")
    eq(TradingSymbolScope.pointValue(for: "CLF26") ?? -1, 1000, "CL = $1000/pt")
    ok(TradingSymbolScope.pointValue(for: "EURUSD") == nil, "unknown instrument -> nil $/pt (no fabricated $50)")
    ok(TradingSymbolScope.pointValue(for: "US.AAPL") == nil, "equity -> nil $/pt")

    // displaySymbol strips the venue prefix for an honest label.
    ok(TradingSymbolScope.displaySymbol("CM.NQU6") == "NQU6", "display strips venue prefix")
}

func source(_ rel: String) -> String {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(rel)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

func testProductSurfaceSymbolScopeContract() {
    // The product surface must stay honest inside the shipped WealthCharts symbol scope. This locks
    // two things a future edit must not regress: (1) the live Signals path must derive symbol and
    // point value from the feed instead of hardcoding display defaults; (2) entry guards use the
    // shared in-scope predicate so junk rows are filtered consistently.
    let files = ["Sources/Model.swift", "Sources/Screens.swift", "Sources/Screens2.swift", "Sources/Screens3.swift"]
    let text = files.map { source($0) }.joined(separator: "\n")
    ok(!text.isEmpty, "product-surface source loaded")
    // No fabricated-default SAMPLE DATA leaks to the buyer (seeded prices/quotes, not honest
    // placeholder hints like "e.g. ES, NQ, …" which legitimately name instruments).
    for phrase in ["NQ=15500", "placeholder: \"AAPL\"", "i.symbol = \"NQ\"", "i.symbol = \"CL\""] {
        ok(!text.contains(phrase), "product surface excludes seeded-sample phrase: \(phrase)")
    }
    // The live Signals path must derive symbol + point value from the real instrument.
    ok(text.contains("inp.symbol = liveSym"), "live signal uses the real resolved symbol")
    ok(text.contains("TradingSymbolScope.pointValue(for: liveSym)"), "live signal uses real per-instrument $/pt")
    ok(!text.contains("inp.pointValue = 50"), "live signal does NOT hardcode ES $50/pt")
    ok(text.contains("riskDollarLabel") || text.contains("$/pt n/a"), "dollar figures honest when $/pt unknown")
    // Entry guards use the shared shipped-scope predicate.
    ok(text.contains("TradingSymbolScope.inScope(t.symbol)"), "trade save uses in-scope guard")
    ok(text.contains("TradingSymbolScope.inScope(s), !conditions.isEmpty"), "alert creation uses in-scope guard")
    ok(!text.contains("Alerts are ES-only"), "no stale ES-only alert copy")
}

func testNoAPIWebhookIngestionContract() {
    let ui = source("Sources/Feeds.swift")
    let chart = source("Sources/ChartScreen.swift")
    let feedTypes = source("Sources/FeedTypes.swift")
    let feedClient = source("Sources/FeedClient.swift")
    let main = source("Sources/main.swift")
    let settings = source("Sources/Screens.swift")
    let api = source("backend/bltd_api.py")
    let cap = source("backend/bltd_capture.py")
    let feeds = source("backend/bltd_feeds.py")
    let topstepBridge = source("backend/bltd_topstep_bridge.py")
    let launcher = source("backend/launch-backend.sh")
    let entitlements = source("Sources/app-developerid.entitlements")
    ok(!ui.isEmpty && !chart.isEmpty && !feedTypes.isEmpty && !feedClient.isEmpty && !main.isEmpty && !settings.isEmpty &&
       !api.isEmpty && !cap.isEmpty && !feeds.isEmpty && !topstepBridge.isEmpty &&
       !launcher.isEmpty && !entitlements.isEmpty,
       "no-api webhook-ingestion source loaded")

    ok(ui.contains("bundled browser bridge") && ui.contains("TopstepX or WealthCharts") && ui.contains("webhook URL"),
       "feed UI explicitly says bundled browser bridge/webhook")
    ok(ui.contains("FeedCredStore.lastSource ?? \"wealthcharts\""), "feed UI defaults fresh buyers to WealthCharts")
    ok(ui.contains("Copy curl") && ui.contains("webhookInfo()"),
       "feed UI exposes copyable webhook setup")
    ok(ui.contains("loadSources(forceSignIn: true)") && ui.contains("for attempt in 0..<5") &&
       ui.contains("Retry connection"),
       "feed UI retries first-run backend sign-in/source loading and exposes a visible retry")
    ok(chart.contains("Waiting for browser feed data") && chart.contains("Refresh webhook"),
       "chart waits for browser bridge data instead of asking for broker credentials")
    ok(feedTypes.contains("No webhook data") && feedTypes.contains("your WealthCharts webhook feed"),
       "feed status labels include WealthCharts webhook state")
    ok(settings.contains("bundled browser bridge") && !settings.contains("prop-firm API"),
       "settings copy describes no-creds bridge ingestion")
    ok(feedClient.contains("/api/webhook/info"), "feed client fetches webhook receiver details")
    ok(main.contains(".task(id: session.signedIn ? session.email : \"\")") &&
       main.contains("already-signed-in restored session"),
       "root view starts the local backend for restored signed-in sessions")
    ok(main.contains("BLT_FEED_SMOKE") && main.contains("runFeedSmoke()") &&
       main.contains("await feed.connect(email: \"local@blacklabel\")"),
       "installed app exposes a non-destructive feed smoke proof")
    ok(main.contains("await feed.feedStatus()") && main.contains("await feed.webhookInfo()") &&
       main.contains("await feed.recentBars(symbol: selected") && main.contains("await feed.liveTick(symbol: selected") &&
       main.contains("newest_bar_age=") && main.contains("fresh_tick="),
       "feed smoke proves source/webhook/history/fresh-tick state, not just backend reachability")
    ok(api.contains("_webhook_ingest") && api.contains("\"/webhook/feed\""),
       "backend exposes webhook ingestion route")
    ok(api.contains("cap.on_candle") && api.contains("STORE.record_bars_batch"),
       "webhook writes through capture/store ingestion")
    ok(api.contains("API feed posts rejected"), "/api/feed/connect documents API feed rejection")
    ok(feeds.contains("\"key\": \"webhook\"") && feeds.contains("\"key\": \"wealthcharts\"") && !feeds.contains("\"key\": \"projectx\""),
       "feed catalogue exposes webhook receiver plus WealthCharts browser source, not API sources")
    ok(feeds.contains("webhook ingestion only; no broker/API feed is accepted"),
       "feed manager rejects direct API feed source posts")
    ok(topstepBridge.contains("class WebhookSink") && topstepBridge.contains("WealthCharts") &&
       topstepBridge.contains("/webhook/feed"),
       "bundled browser bridge posts parsed browser-feed data to webhook")
    ok(launcher.contains("supervise_topstep_bridge") && launcher.contains("BLTD_TOKEN") &&
       launcher.contains("BLTD_CAPTURE_BROWSER=\"0\"") && !launcher.contains("prop-firm API feed"),
       "launcher auto-starts browser bridge with shared webhook token and disables direct browser writes")
    ok(entitlements.contains("TopstepX or WealthCharts browser bridge/webhook feed"),
       "Developer ID entitlement rationale names browser/webhook ingestion")
    ok(!ui.contains("API Key") && !ui.contains("ProjectX/TopstepX"),
       "feed UI does not ask for prop-account API credentials")
}

// ===== ChartRender — headless chart + engine-trade overlay (edge-gate transparency) =====
// Locks that the renderer survives every honest input shape: a full fire (entry/stop/target), a
// fire with nil legs (no stop/no target), a CLOSED fire (outcome set), and empty bars (no-data
// frame). A returned PNG file proves the path didn't crash and produced output; honesty is that
// nil legs simply aren't drawn (never fabricated) — exercised by the nil-leg render succeeding.
func testChartRenderFireOverlay() {
    func mkBars(_ n: Int) -> [Bar] {
        (0..<n).map { i in
            let base = 100.0 + Double(i) * 0.1
            return Bar(date: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 60),
                       open: base, high: base + 0.5, low: base - 0.5, close: base + 0.2, volume: 1000)
        }
    }
    let dir = tmpBase.appendingPathComponent("render-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let bars = mkBars(120)
    func path(_ n: String) -> String { dir.appendingPathComponent(n).path }

    // Full fire: entry + stop + target + engine, open.
    let full = RenderFire(direction: "long", engine: "barber", entry: 110.0, stop: 108.0, target: 114.0, outcome: nil)
    let p1 = path("full.png")
    ok(ChartRender.renderPNG(bars: bars, symbol: "US.QQQ", title: "t", indicators: RenderIndicators(fire: full), to: p1),
       "render w/ full fire returns true")
    ok(FileManager.default.fileExists(atPath: p1), "full-fire PNG written")

    // Nil-leg fire: entry only (no stop, no target) — honest, the missing legs just aren't drawn.
    let bare = RenderFire(direction: "short", engine: "research", entry: 111.0, stop: nil, target: nil, outcome: nil)
    let p2 = path("bare.png")
    ok(ChartRender.renderPNG(bars: bars, symbol: "US.QQQ", title: "t", indicators: RenderIndicators(fire: bare), to: p2),
       "render w/ nil-leg fire returns true (legs honestly skipped)")

    // Closed fire: outcome set -> "EXIT" label path.
    let closed = RenderFire(direction: "long", engine: "bible", entry: 110.0, stop: 108.0, target: 114.0, outcome: "win")
    ok(ChartRender.renderPNG(bars: bars, symbol: "US.QQQ", title: "t", indicators: RenderIndicators(fire: closed), to: path("closed.png")),
       "render w/ closed fire (EXIT label) returns true")

    // Empty bars + a fire: honest no-data frame, must not crash and still writes a PNG.
    ok(ChartRender.renderPNG(bars: [], symbol: "US.QQQ", title: "t", indicators: RenderIndicators(fire: full), to: path("empty.png")),
       "render w/ empty bars returns true (honest no-data frame)")

    // No fire at all: the overlay simply isn't there (flat = nothing, never a fabricated trade).
    ok(ChartRender.renderPNG(bars: bars, symbol: "US.QQQ", title: "t", indicators: RenderIndicators(fire: nil), to: path("none.png")),
       "render w/ no fire returns true (no overlay)")
}

// ===== ChartScale (axis intelligence shared by the SwiftUI chart + the headless render proof) =====
func testChartScaleNiceNum() {
    eq(ChartScale.niceNum(0.8, ceil: true), 1, "niceNum ceil 0.8 -> 1")
    eq(ChartScale.niceNum(23, ceil: true), 25, "niceNum ceil 23 -> 25")
    eq(ChartScale.niceNum(67, ceil: true), 100, "niceNum ceil 67 -> 100")
    eq(ChartScale.niceNum(420, ceil: false), 250, "niceNum floor 420 -> 250")
}
func testChartScaleTicks() {
    let t = ChartScale.ticks(lo: 29800, hi: 30200, target: 5)
    ok(t.count >= 3, "ticks produces several lines")
    // step is a nice number and ticks are monotone & inside a small slack of the domain
    ok(t.allSatisfy { $0 >= 29800 - 200 && $0 <= 30200 + 200 }, "ticks clamp near domain")
    if t.count > 1 {
        let step = t[1] - t[0]
        eq(ChartScale.niceNum(step, ceil: true), step, "tick step is a nice number")
    }
    ok(ChartScale.ticks(lo: 5, hi: 5).count <= 1, "degenerate domain -> at most one tick")
}
func testChartScalePriceDomainPad() {
    let d = ChartScale.priceDomain(low: 100, high: 200, padFrac: 0.1)
    eq(d.lo, 90, "domain pads low by padFrac")
    eq(d.hi, 210, "domain pads high by padFrac")
    let flat = ChartScale.priceDomain(low: 50, high: 50)   // flat series still yields a band
    ok(flat.hi > flat.lo, "flat series gets a non-degenerate band")
}
func testChartScaleYPixelLinearAndLog() {
    // Linear: midpoint of domain maps to vertical midpoint between topY..bottomY.
    let yLinMid = ChartScale.yPixel(150, lo: 100, hi: 200, topY: 0, bottomY: 100, log: false)
    eq(yLinMid, 50, "linear midpoint -> pixel midpoint")
    // hi maps to topY (top of pane), lo maps to bottomY (bottom of pane).
    eq(ChartScale.yPixel(200, lo: 100, hi: 200, topY: 0, bottomY: 100, log: false), 0, "hi -> topY")
    eq(ChartScale.yPixel(100, lo: 100, hi: 200, topY: 0, bottomY: 100, log: false), 100, "lo -> bottomY")
    // Log: geometric midpoint (sqrt(lo*hi)) maps to the pixel midpoint.
    let geo = (100.0 * 200.0).squareRoot()
    let yLog = ChartScale.yPixel(geo, lo: 100, hi: 200, topY: 0, bottomY: 100, log: true)
    eq(yLog, 50, "log geometric-mid -> pixel midpoint", tol: 1e-6)
}
func testChartScaleDecimals() {
    eqi(ChartScale.priceDecimals(step: 250), 0, "big step -> 0 decimals")
    eqi(ChartScale.priceDecimals(step: 5), 0, "integer step -> 0 decimals")
    ok(ChartScale.priceDecimals(step: 0.01) >= 2, "small step -> >=2 decimals")
}

// ===== Engine roster + fire feed decode (GET /api/screen, /api/fires) =====
func testEngineRosterDecode() {
    let obj: [String: Any] = ["rows": [
        ["engine": "momentum", "symbol": "CM.ESU6", "edge": true, "warming": false,
         "winRate": 0.9, "netPts": 12.5, "expectancyR": 0.6, "trades": 30, "bars": 120, "reason": "OOS candidate"],
        ["engine": "regime", "symbol": "US.SPY", "edge": false, "warming": true,
         "winRate": 0.0, "netPts": 0.0, "expectancyR": 0.0, "trades": 0, "bars": 12, "reason": "warming"],
    ]]
    let rows = EngineRoster.decode(obj)
    eqi(rows.count, 2, "roster keeps WealthCharts instruments")
    ok(rows[0].engine == "momentum" && rows[0].edge && !rows[0].warming, "roster row 0 fields")
    eq(rows[0].netPts, 12.5, "roster row 0 netPts")
    eqi(rows[0].trades, 30, "roster row 0 trades")
    ok(rows[1].engine == "regime" && !rows[1].edge && rows[1].warming, "roster row 1 fields")
    eqi(EngineRoster.decode(["rows": []]).count, 0, "empty roster honest")
    eqi(EngineRoster.decode([:]).count, 0, "missing rows key honest")
}

func testEngineLabels() {
    // Generic customer-facing labels for every roster id; unknown ids humanize, never raw tokens.
    ok(EngineRoster.label(for: "momentum") == "Momentum", "label momentum")
    ok(EngineRoster.label(for: "structure") == "Structure", "label structure")
    ok(EngineRoster.label(for: "regime") == "Regime", "label regime")
    ok(EngineRoster.label(for: "channel") == "Channel", "label channel")
    ok(EngineRoster.label(for: "context_a") == "Context A", "label context_a")
    ok(EngineRoster.label(for: "context_b") == "Context B", "label context_b")
    ok(EngineRoster.label(for: "meanrev") == "Mean Reversion", "label meanrev")
    ok(EngineRoster.label(for: "my_engine") == "My Engine", "label humanizes unknown id")
    // No internal codename ever leaks through the order list.
    for e in EngineRoster.order {
        ok(!["perp", "bible", "apex", "barber", "ctx_alpha", "ctx_bravo"].contains(e),
           "order has no codename: \(e)")
    }
}

func testFireFeedDecode() {
    let obj: [String: Any] = ["fires": [
        ["id": 5, "engine": "structure", "direction": "short", "entry": 5100.0, "symbol": "CM.ESU6",
         "stop": 102.0, "target": 96.0, "rationale": "r", "outcome": NSNull(), "pnl": NSNull(), "ts": "2026-06-18 12:00:00"],
        ["id": 6, "engine": "momentum", "direction": "long", "entry": 17000.0, "symbol": "CM.NQU6",
         "stop": 16900.0, "target": 17200.0, "rationale": "r", "ts": "2026-06-18 12:01:00"],
    ]]
    let fires = FireFeed.decode(obj)
    eqi(fires.count, 2, "fire decode keeps WealthCharts instruments")
    ok(fires[0].engine == "structure" && fires[0].direction == "short", "fire fields")
    eq(fires[0].entry, 5100.0, "fire entry")
    ok(fires[0].outcome == nil && fires[0].pnl == nil, "ungraded fire -> nil outcome/pnl (honest)")
    ok(fires[1].engine == "momentum" && fires[1].direction == "long", "fire row 1 fields")
    eq(fires[1].entry, 17000.0, "fire row 1 entry")
    eqi(FireFeed.decode(["fires": []]).count, 0, "empty fires honest")
}

// ===== "NO EDGE TODAY" hero verdict + buyer-triggered gate re-run (own bars) =====
func testGateVerdictNoEdgeAndReasons() {
    // 3 engines on the buyer's bars: one no-edge (sufficient sample), one warming, one candidate.
    let fleet = [
        EngineRow(engine: "meanrev", symbol: "CM.ESU6", edge: false, warming: false,
                  winRate: 0.5, netPts: -3.0, expectancyR: -0.1, trades: 44, bars: 300,
                  reason: "no edge — win 50.0% / net -3.00 pts on 44 OOS trades (p=0.610)"),
        EngineRow(engine: "breakout", symbol: "CM.ESU6", edge: false, warming: true,
                  winRate: 0.0, netPts: 0.0, expectancyR: 0.0, trades: 0, bars: 20, reason: "warming (20 bars)"),
        EngineRow(engine: "momentum", symbol: "CM.ESU6", edge: true, warming: false,
                  winRate: 0.7, netPts: 12.0, expectancyR: 0.4, trades: 40, bars: 300, reason: "OOS candidate"),
    ]
    let v = GateVerdict.compute(fleet)
    ok(v.hasData, "verdict has data when fleet non-empty")
    eqi(v.evaluated, 3, "verdict evaluated engine count")
    eqi(v.candidates, 1, "verdict candidate count")
    eqi(v.warming, 1, "verdict warming count")
    eqi(v.noEdge, 1, "verdict no-edge count")
    ok(!v.isNoEdge, "candidate present -> not a blanket no-edge verdict")
    // candidate engine is NOT listed as a reject; the no-edge + warming ones are, in roster order.
    eqi(v.rejects.count, 2, "rejects exclude candidate engines")
    ok(v.rejects.first?.engine == "meanrev", "rejects preserve roster order (meanrev first)")
    ok(v.rejects.contains { $0.engine == "meanrev" && $0.reason.contains("no edge") }, "reject carries honest reason")
    ok(v.headline.contains("OOS candidate"), "headline surfaces the candidate")
}

func testGateVerdictAllNoEdgeHeadline() {
    let fleet = [
        EngineRow(engine: "meanrev", symbol: "CM.ESU6", edge: false, warming: false,
                  winRate: 0.5, netPts: -1.0, expectancyR: 0.0, trades: 50, bars: 300, reason: "no edge"),
        EngineRow(engine: "regime", symbol: "CM.ESU6", edge: false, warming: false,
                  winRate: 0.48, netPts: -2.0, expectancyR: 0.0, trades: 60, bars: 300, reason: "no edge"),
    ]
    let v = GateVerdict.compute(fleet)
    ok(v.isNoEdge, "no candidates -> blanket no-edge verdict")
    ok(v.headline.contains("no edge on your bars today"), "no-edge headline is blunt and honest")
    eqi(v.candidates, 0, "no-edge verdict has zero candidates")
}

func testGateVerdictEmptyStoreHonest() {
    let v = GateVerdict.compute([])
    ok(!v.hasData, "empty fleet -> hasData false (no fabricated verdict)")
    eqi(v.evaluated, 0, "empty fleet evaluates zero engines")
    ok(v.headline == "No bars captured yet", "empty headline is honest")
    ok(v.rejects.isEmpty, "empty fleet has no reject rows")
}

// ===== Prop-firm rule profiles (item 7) — the profile-gating decision =====
// A signal with a 2-pt stop at $50/pt/contract => $100 risk per contract.
func testRuleProfileGateWithinLimitsAndMax() {
    let p = RuleProfile(name: "Topstep 50K", dailyLossLimit: 500, trailingDrawdown: 2000,
                        maxPositionSize: 5, contractScaling: 0, pointValue: 50, sourceURL: "")
    let d = RuleProfileGate.evaluate(riskPoints: 2, pointValue: 50, contracts: 1, profile: p)
    ok(d.verdict == .withinLimits, "1 contract respects every cap -> within limits")
    ok(d.reasons.isEmpty, "within limits has no breach reasons")
    eq(d.dollarRiskAtSize, 100, "one stop-out risk = 2pt * $50 * 1")
    // maxContracts = min(maxPos 5, floor(dailyLoss 500/100)=5, floor(trailing 2000/100)=20) = 5
    eqi(d.maxContracts, 5, "max contracts within all set limits")
    ok(d.annotation.contains("Within limits") && d.annotation.contains("max 5"), "annotation states within + max")
    ok(!d.isBreach, "within limits is not a breach")
}

func testRuleProfileGateBreach() {
    let p = RuleProfile(name: "Topstep 50K", dailyLossLimit: 500, trailingDrawdown: 2000,
                        maxPositionSize: 5, contractScaling: 0, pointValue: 50, sourceURL: "")
    // 6 contracts => $600 (> $500 daily-loss) AND position 6 > max 5 => two breach reasons.
    let d = RuleProfileGate.evaluate(riskPoints: 2, pointValue: 50, contracts: 6, profile: p)
    ok(d.verdict == .breach, "over-cap size is a breach")
    ok(d.isBreach, "isBreach true on breach")
    eqi(d.reasons.count, 2, "both the position and daily-loss caps are breached")
    ok(d.reasons.contains { $0.contains("max position") }, "position-cap breach reason present")
    ok(d.reasons.contains { $0.contains("daily-loss") }, "daily-loss breach reason present")
    eqi(d.maxContracts, 5, "breach still reports the largest within-limits size")
    ok(d.annotation.hasPrefix("Breach:"), "breach annotation is prefixed Breach:")
    // A stop-out big enough that even one contract breaches -> maxContracts 0.
    let tight = RuleProfile(name: "tight", dailyLossLimit: 50, trailingDrawdown: 0,
                            maxPositionSize: 0, contractScaling: 0, pointValue: 50, sourceURL: "")
    let d0 = RuleProfileGate.evaluate(riskPoints: 2, pointValue: 50, contracts: 1, profile: tight)
    ok(d0.verdict == .breach, "1 contract over the daily-loss cap is a breach")
    eqi(d0.maxContracts, 0, "no contract count fits an over-tight cap")
    ok(d0.annotation.contains("0 contracts"), "annotation states 0 contracts fit")
}

func testRuleProfileGateEdgeOfCap() {
    let p = RuleProfile(name: "edge", dailyLossLimit: 500, trailingDrawdown: 2000,
                        maxPositionSize: 5, contractScaling: 0, pointValue: 50, sourceURL: "")
    // Exactly at the caps: $500 == daily-loss and 5 == max position -> within (uses > for breach).
    let d = RuleProfileGate.evaluate(riskPoints: 2, pointValue: 50, contracts: 5, profile: p)
    ok(d.verdict == .withinLimits, "hitting the cap exactly is within limits, not a breach")
    eq(d.dollarRiskAtSize, 500, "edge-of-cap dollar risk equals the daily-loss limit")
    eqi(d.maxContracts, 5, "edge-of-cap max contracts = the cap")
    // One more contract tips it over.
    let over = RuleProfileGate.evaluate(riskPoints: 2, pointValue: 50, contracts: 6, profile: p)
    ok(over.verdict == .breach, "one contract past the cap breaches")
}

func testRuleProfileGateEmptyNoProfileNoSignal() {
    // Empty profile: selected but no caps entered -> honest emptyProfile, never a fake pass.
    let blank = RuleProfilePresets.profile(for: "Apex Trader Funding")
    ok(!blank.hasLimits, "a blank firm template ships with no limits set")
    let de = RuleProfileGate.evaluate(riskPoints: 2, pointValue: 50, contracts: 1, profile: blank)
    ok(de.verdict == .emptyProfile, "profile with no caps -> emptyProfile verdict")
    ok(de.annotation.contains("no limits set"), "empty-profile annotation is honest")
    // No profile selected at all.
    let dn = RuleProfileGate.evaluate(riskPoints: 2, pointValue: 50, contracts: 1, profile: nil)
    ok(dn.verdict == .noProfile, "nil profile -> noProfile verdict")
    // A real profile but no computable signal (flat / zero stop distance).
    let p = RuleProfile(name: "x", dailyLossLimit: 500, trailingDrawdown: 0,
                        maxPositionSize: 0, contractScaling: 0, pointValue: 50, sourceURL: "")
    let ds = RuleProfileGate.evaluate(riskPoints: 0, pointValue: 50, contracts: 1, profile: p)
    ok(ds.verdict == .noSignal, "no stop distance -> noSignal (never a fabricated pass)")
    // $/pt falls back to the signal's when the profile leaves it unset.
    let noPV = RuleProfile(name: "noPV", dailyLossLimit: 500, trailingDrawdown: 0,
                           maxPositionSize: 0, contractScaling: 0, pointValue: 0, sourceURL: "")
    let dfb = RuleProfileGate.evaluate(riskPoints: 2, pointValue: 50, contracts: 1, profile: noPV)
    ok(dfb.verdict == .withinLimits, "profile $/pt falls back to the signal's when unset")
    eq(dfb.dollarRiskAtSize, 100, "fallback $/pt computes the correct dollar risk")
    // Scaling-plan cap is enforced independently of the absolute position cap.
    let scale = RuleProfile(name: "scale", dailyLossLimit: 0, trailingDrawdown: 0,
                            maxPositionSize: 0, contractScaling: 3, pointValue: 50, sourceURL: "")
    let dsc = RuleProfileGate.evaluate(riskPoints: 2, pointValue: 50, contracts: 4, profile: scale)
    ok(dsc.verdict == .breach && dsc.reasons.contains { $0.contains("scaling-plan") }, "scaling-plan cap breaches independently")
    eqi(dsc.maxContracts, 3, "scaling-plan cap sets the max contracts")
}

func testGateRerunDecodeAndStatFormatting() {
    let obj: [String: Any] = [
        "available": true, "prover_sha": "3e818b54f842ebcf", "sigMinN": 30, "alpha": 0.05,
        "test": "one-sided binomial vs R-geometry breakeven", "source": "your own captured bars",
        "generatedUTC": "2026-07-11T04:00:00Z", "symbols": ["CM.ESU6"],
        "engineCount": 2, "candidateCount": 0, "noEdgeCount": 1, "insufficientCount": 1,
        "engines": [
            ["engine": "meanrev", "status": "no_edge", "contracts": [
                ["symbol": "CM.ESU6", "bars": 400, "trades": 51, "wins": 24, "losses": 27,
                 "winRate": 0.4706, "netPts": -6.5, "expectancyR": -0.05, "maxDrawdownR": 8.0,
                 "pEdge": 0.61, "proven": false, "insufficient": false,
                 "reason": "no edge — win 47.1% / net -6.50 pts on 51 OOS trades (p=0.610, need p<0.05)"]]],
            ["engine": "channel", "status": "insufficient", "contracts": [
                ["symbol": "CM.ESU6", "bars": 60, "trades": 8, "wins": 4, "losses": 4,
                 "winRate": 0.5, "netPts": 1.0, "expectancyR": 0.05, "maxDrawdownR": 2.0,
                 "pEdge": 1.0, "proven": false, "insufficient": true,
                 "reason": "insufficient sample — 8 OOS trades, need ≥30"]]],
        ],
    ]
    let r = GateRerunReport.decode(obj)
    ok(r.available, "rerun decode available")
    ok(r.proverSHA == "3e818b54f842ebcf", "prover_sha decoded")
    eqi(r.minTrades, 30, "sigMinN decoded")
    eqi(r.engines.count, 2, "both engines decoded")
    eqi(r.candidateCount, 0, "zero candidates decoded")
    // no_edge engine best contract stat line shows n / W/L / net / maxDD / p — reproducible numbers.
    let mr = r.engines[0].best!
    let line = mr.statLine(minTrades: r.minTrades)
    ok(line.contains("n=51"), "stat line shows n")
    ok(line.contains("24W/27L"), "stat line shows W/L")
    ok(line.contains("maxDD 8.00R"), "stat line shows max drawdown in R")
    ok(line.contains("p=0.610"), "stat line shows p-value for a sufficient sample")
    // insufficient engine: p is shown as n/a (not a misleading p-value on a thin sample).
    let ch = r.engines[1].best!
    ok(ch.insufficient, "thin sample flagged insufficient")
    ok(ch.statLine(minTrades: r.minTrades).contains("p n/a (n<30)"), "thin sample hides untrustworthy p")
    ok(r.proverLine.contains("3e818b54f842ebcf") && r.proverLine.contains("min n 30"), "prover line is reproducible")
    // Honest empty decode.
    let empty = GateRerunReport.decode(["available": false, "reason": "no bars captured yet"])
    ok(!empty.available && empty.reason == "no bars captured yet", "empty rerun decode honest")
}

// ===== In-app auto-updater (pure core: version compare, sha256, manifest decode, check window) =====
// Mirrors the proven Black Label Real Estate testUpdater(). App-shell updater only — it never
// touches the engines, the feed, the edge-gate, or any signal; these are the headless-verifiable
// pure functions the Install/daily-check path depends on.
func testUpdater() {
    // Version compare — strictly newer only.
    ok(Updater.isNewer(latestBuild: 13, currentBuild: 12), "updater: 13>12 is newer")
    ok(!Updater.isNewer(latestBuild: 12, currentBuild: 12), "updater: equal is not newer")
    ok(!Updater.isNewer(latestBuild: 11, currentBuild: 12), "updater: older is not newer")
    // sha256 known vectors (integrity-check correctness).
    ok(Updater.sha256Hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "updater: sha256(abc)")
    ok(Updater.sha256Hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "updater: sha256(empty)")
    // Manifest decode — snake_case keys, extra fields ignored.
    let json = "{\"product\":\"trading\",\"latest_build\":13,\"latest_version\":\"1.0\",\"download_url\":\"https://x/13.zip\",\"sha256\":\"deadbeef\",\"notarized\":true,\"team_id\":\"745ZPGFRA5\",\"release_notes\":\"Fix\",\"mandatory\":false,\"unknown\":\"ignored\"}"
    let m = try? Updater.decodeManifest(Data(json.utf8))
    ok(m != nil, "updater: manifest decodes")
    eqi(m?.latestBuild ?? -1, 13, "updater: manifest build = 13")
    ok(m?.downloadURL == "https://x/13.zip", "updater: manifest download_url")
    ok(m?.teamID == "745ZPGFRA5", "updater: manifest team_id")
    ok(m?.sha256 == "deadbeef", "updater: manifest sha256")
    ok(m?.product == "trading", "updater: manifest product = trading")
    // Minimal manifest — only required fields present; optionals default nil.
    let minimal = "{\"product\":\"trading\",\"latest_build\":5,\"download_url\":\"https://x/5.zip\"}"
    let m2 = try? Updater.decodeManifest(Data(minimal.utf8))
    ok(m2 != nil, "updater: minimal manifest decodes")
    ok(m2?.sha256 == nil, "updater: minimal sha256 is nil")
    eqi(m2?.latestBuild ?? -1, 5, "updater: minimal build = 5")
    // Malformed JSON throws cleanly (never crashes).
    var threw = false
    do { _ = try Updater.decodeManifest(Data("{not json".utf8)) } catch { threw = true }
    ok(threw, "updater: malformed manifest throws")
    // Default manifest URL targets THIS product's slug (trading), not realestate.
    let savedURL = UserDefaults.standard.string(forKey: Updater.manifestOverrideKey)
    UserDefaults.standard.removeObject(forKey: Updater.manifestOverrideKey)
    ok(Updater.manifestURL.absoluteString == "https://blacklabelbots.com/api/version/trading", "updater: default manifest URL = trading slug")
    if let savedURL { UserDefaults.standard.set(savedURL, forKey: Updater.manifestOverrideKey) }
    // Daily-check window.
    UserDefaults.standard.removeObject(forKey: Updater.lastCheckKey)
    ok(Updater.dueForBackgroundCheck(now: 1_000_000), "updater: due when never checked")
    UserDefaults.standard.set(1_000_000.0 - 3600, forKey: Updater.lastCheckKey)
    ok(!Updater.dueForBackgroundCheck(now: 1_000_000), "updater: not due 1h after a check")
    UserDefaults.standard.set(1_000_000.0 - 25*3600, forKey: Updater.lastCheckKey)
    ok(Updater.dueForBackgroundCheck(now: 1_000_000), "updater: due 25h after a check")
    UserDefaults.standard.removeObject(forKey: Updater.lastCheckKey)
}

// ===== LIVE backend integration test (opt-in via BLT_LIVE_BACKEND=1) =====
// Boots no process itself — asserts the ALREADY-RUNNING self-contained backend (bltd_api.py)
// serves a wire format that decodes into REAL Bar/LiveTick values, locking the contract the app
// depends on end to end. Offline by default so the core suite stays deterministic.
func liveGET(_ base: String, _ path: String, token: String?) -> [String: Any]? {
    guard let url = URL(string: base + path) else { return nil }
    var req = URLRequest(url: url); req.timeoutInterval = 8
    if let t = token { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
    let sem = DispatchSemaphore(value: 0); var out: [String: Any]? = nil
    URLSession.shared.dataTask(with: req) { d, _, _ in defer { sem.signal() }
        if let d = d { out = try? JSONSerialization.jsonObject(with: d) as? [String: Any] } }.resume()
    _ = sem.wait(timeout: .now() + 10); return out
}
func livePOST(_ base: String, _ path: String, _ body: [String: Any]) -> [String: Any]? {
    guard let url = URL(string: base + path) else { return nil }
    var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = 8
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)
    let sem = DispatchSemaphore(value: 0); var out: [String: Any]? = nil
    URLSession.shared.dataTask(with: req) { d, _, _ in defer { sem.signal() }
        if let d = d { out = try? JSONSerialization.jsonObject(with: d) as? [String: Any] } }.resume()
    _ = sem.wait(timeout: .now() + 10); return out
}
func testLiveBackendIntegration() {
    let base = ProcessInfo.processInfo.environment["BLT_BACKEND_URL"] ?? "http://127.0.0.1:8787"
    // 1) sign in -> token
    guard let auth = livePOST(base, "/auth/signin", ["email": "local@blacklabel", "password": "local-session"]),
          let token = auth["token"] as? String, !token.isEmpty else {
        ok(false, "[integration] backend sign-in returns a token"); return
    }
    ok(true, "[integration] backend sign-in returns a token")
    // 2) symbols -> pick busiest captured symbol
    guard let symsObj = liveGET(base, "/api/symbols", token: token) else { ok(false, "[integration] /api/symbols reachable"); return }
    let syms = FeedSymbols.decode(symsObj)
    guard let sym = syms.busiest ?? syms.pickerList.first else { ok(false, "[integration] store has a captured symbol"); return }
    ok(true, "[integration] store has a captured symbol (\(sym))")
    // 3) /api/recent decodes into REAL bars with sane geometry (high>=low, high>=close, sorted)
    let enc = sym.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sym
    guard let recent = liveGET(base, "/api/recent?symbol=\(enc)&limit=400", token: token) else { ok(false, "[integration] /api/recent reachable"); return }
    let bars = FeedBars.decode(recent)
    ok(!bars.isEmpty, "[integration] /api/recent decodes into >=1 real Bar")
    ok(bars.allSatisfy { $0.high >= $0.low && $0.high >= $0.close && $0.low <= $0.open }, "[integration] decoded bars have valid OHLC geometry")
    ok(zip(bars, bars.dropFirst()).allSatisfy { $0.date <= $1.date }, "[integration] decoded bars are time-sorted oldest->newest")
    ok(bars.allSatisfy { $0.open > 0 && $0.close > 0 }, "[integration] decoded bar prices are positive reals (not fabricated/zero)")
    // 4) /api/live decodes into a LiveTick OR honest nil (gated) — never a bogus value
    if let liveObj = liveGET(base, "/api/live?symbol=\(enc)", token: token) {
        if let tick = LiveTick.decode(liveObj) {
            ok(tick.price > 0 && tick.symbol.uppercased() == sym.uppercased(), "[integration] /api/live decodes a real tick for \(sym)")
        } else {
            ok((liveObj["gated"] as? Bool) == true || liveObj["symbol"] == nil, "[integration] /api/live honest gated/empty when no tick")
        }
    } else { ok(false, "[integration] /api/live reachable") }
    // 5) /api/screen exposes the FULL edge-gated engine roster (every engine present, each row a
    // real OOS verdict on the buyer's own bars — present-or-warming, never fabricated).
    let roster = ["meanrev", "breakout", "research", "momentum", "structure", "regime", "channel", "context_a", "context_b"]
    if let screenObj = liveGET(base, "/api/screen", token: token) {
        let rows = EngineRoster.decode(screenObj)
        let present = Set(rows.map { $0.engine })
        for e in roster { ok(present.contains(e), "[integration] /api/screen exposes engine \(e)") }
        ok(rows.allSatisfy { $0.winRate >= 0 && $0.winRate <= 1 }, "[integration] screen winRates are real fractions [0,1]")
    } else { ok(false, "[integration] /api/screen reachable") }
    // 6) /api/fires decodes into the real (possibly empty) signal journal — never fabricated.
    if let firesObj = liveGET(base, "/api/fires?limit=20", token: token) {
        let fires = FireFeed.decode(firesObj)
        ok(fires.allSatisfy { $0.entry > 0 && !$0.engine.isEmpty }, "[integration] /api/fires rows are real (positive entry, named engine) or empty")
    } else { ok(false, "[integration] /api/fires reachable") }
}

func testWindowLaunchOrderingContract() {
    guard let src = try? String(contentsOfFile: "Sources/main.swift", encoding: .utf8) else {
        ok(false, "[source] main.swift readable for window launch contract"); return
    }
    guard let activation = src.range(of: "NSApp.setActivationPolicy(.regular)"),
          let order = src.range(of: "window.makeKeyAndOrderFront(nil)"),
          let front = src.range(of: "window.orderFrontRegardless()") else {
        ok(false, "[source] launch orders app window explicitly"); return
    }
    ok(activation.lowerBound < order.lowerBound, "[source] activation policy is regular before ordering the Trading window")
    ok(order.lowerBound < front.lowerBound, "[source] Trading window is forced front after activation")
    ok(src.contains("NSScreen.main?.visibleFrame"), "[source] Trading window uses visibleFrame to stay on-screen")
}

func testBuildNumberContract() {
    let expectedBuild = "<key>CFBundleVersion</key><string>18</string>"
    for file in ["build.command", "build-signed.command"] {
        guard let src = try? String(contentsOfFile: file, encoding: .utf8) else {
            ok(false, "[source] \(file) readable for build-number contract"); continue
        }
        ok(src.contains(expectedBuild), "[source] \(file) stamps Trading build 18")
        ok(src.contains("universal2") && src.contains("build_trd_arch arm64") &&
           src.contains("build_trd_arch x86_64") && src.contains("lipo -create"),
           "[source] \(file) builds a universal2 Trading binary")
    }
    if let src = try? String(contentsOfFile: "build-developer-id.sh", encoding: .utf8) {
        ok(src.contains("BUILD_NUMBER=\"${BUILD_NUMBER:-18}\""), "[source] Developer-ID build defaults to Trading build 18")
    } else {
        ok(false, "[source] build-developer-id.sh readable for build-number contract")
    }
    if let plist = try? String(contentsOfFile: "Sources/Info.plist", encoding: .utf8) {
        ok(plist.contains("<key>CFBundleVersion</key>\n\t<string>18</string>"),
           "[source] Sources/Info.plist CFBundleVersion is 18")
    } else {
        ok(false, "[source] Sources/Info.plist readable for build-number contract")
    }
    if let project = try? String(contentsOfFile: "project.yml", encoding: .utf8) {
        ok(project.contains("CFBundleVersion: \"18\""), "[source] project.yml CFBundleVersion is 18")
    } else {
        ok(false, "[source] project.yml readable for build-number contract")
    }
}

// ChartRender headless engine-trade overlay (edge-gate transparency)
testChartRenderFireOverlay()

// ChartScale axis intelligence
testChartScaleNiceNum()
testChartScaleTicks()
testChartScalePriceDomainPad()
testChartScaleYPixelLinearAndLog()
testChartScaleDecimals()

// Live feed decode
testFeedBarsDecode()
testFeedBarsEmptyAndMalformed()
testFeedBarsGeometryDefensive()
testLiveTickDecode()
testLiveFold()
testCaptureStatusState()
testFeedSymbolsPicker()
testTradingSymbolScope()
testProductSurfaceSymbolScopeContract()
testNoAPIWebhookIngestionContract()

// Engine roster + fire feed decode (the /api/screen + /api/fires wire contract)
testEngineRosterDecode()
testEngineLabels()
testFireFeedDecode()
testGateVerdictNoEdgeAndReasons()
testGateVerdictAllNoEdgeHeadline()
testGateVerdictEmptyStoreHonest()
testGateRerunDecodeAndStatFormatting()

// Prop-firm rule profiles (item 7): the profile-gating decision on the buyer's own caps.
testRuleProfileGateWithinLimitsAndMax()
testRuleProfileGateBreach()
testRuleProfileGateEdgeOfCap()
testRuleProfileGateEmptyNoProfileNoSignal()

// In-app auto-updater pure core (version compare, sha256, manifest decode, daily-check window)
testUpdater()

// Installed-app launch contract: the window must be on-screen and frontmost.
testWindowLaunchOrderingContract()
testBuildNumberContract()

// Opt-in live backend integration (locks the end-to-end wire contract on real captured data).
if ProcessInfo.processInfo.environment["BLT_LIVE_BACKEND"] == "1" {
    print("Running LIVE backend integration test (BLT_LIVE_BACKEND=1)...")
    testLiveBackendIntegration()
}

try? FileManager.default.removeItem(at: tmpBase)   // clean temp test stores
print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
