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
testBrokerCSVNoMappableColumns()
testCSVQuotedFields()
// Seasonality + correlations
testSeasonalityByMonth()
testSeasonalityHoldTime()
testCorrelationPearson()
testCorrelationMatrix()
// Pattern detection
testCandlePatternGeometry()
testEngulfingAndInside()
testPatternScannerEmptyAndCounts()
testPivotsAndLevels()
testDoubleTopDetection()
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
        [100.5, 102.0, 100.0, 101.5, 1_700_000_015.0],
    ]]
    let bars = FeedBars.decode(obj)
    eqi(bars.count, 2, "feed bars count")
    eq(bars[0].open, 100, "feed bar0 open")
    eq(bars[1].close, 101.5, "feed bar1 close")
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
    let s = FeedSymbols.decode([
        "backtestable": ["AAA", "BBB"], "live": ["BBB", "CCC"],
        "liveTicks": ["CCC", "DDD"], "busiest": "AAA",
    ])
    let p = s.pickerList
    eqi(p.count, 4, "picker de-duplicates union")
    ok(p.first == "CCC", "picker leads with live tick")
    ok(Set(p).count == p.count, "picker has no dupes")
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
        ["engine": "momentum", "symbol": "CM.MNQM6", "edge": true, "warming": false,
         "winRate": 0.9, "netPts": 12.5, "expectancyR": 0.6, "trades": 30, "bars": 120, "reason": "edge proven"],
        ["engine": "regime", "symbol": "US.SPY", "edge": false, "warming": true,
         "winRate": 0.0, "netPts": 0.0, "expectancyR": 0.0, "trades": 0, "bars": 12, "reason": "warming"],
    ]]
    let rows = EngineRoster.decode(obj)
    eqi(rows.count, 2, "roster row count")
    ok(rows[0].engine == "momentum" && rows[0].edge && !rows[0].warming, "roster row 0 fields")
    eq(rows[0].netPts, 12.5, "roster row 0 netPts")
    eqi(rows[0].trades, 30, "roster row 0 trades")
    ok(rows[1].warming && !rows[1].edge, "roster row 1 warming")
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
        ["id": 5, "engine": "structure", "direction": "short", "entry": 100.0, "symbol": "US.QQQ",
         "stop": 102.0, "target": 96.0, "rationale": "r", "outcome": NSNull(), "pnl": NSNull(), "ts": "2026-06-18 12:00:00"],
    ]]
    let fires = FireFeed.decode(obj)
    eqi(fires.count, 1, "fire count")
    ok(fires[0].engine == "structure" && fires[0].direction == "short", "fire fields")
    eq(fires[0].entry, 100.0, "fire entry")
    ok(fires[0].outcome == nil && fires[0].pnl == nil, "ungraded fire -> nil outcome/pnl (honest)")
    eqi(FireFeed.decode(["fires": []]).count, 0, "empty fires honest")
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

// Engine roster + fire feed decode (the /api/screen + /api/fires wire contract)
testEngineRosterDecode()
testEngineLabels()
testFireFeedDecode()

// Opt-in live backend integration (locks the end-to-end wire contract on real captured data).
if ProcessInfo.processInfo.environment["BLT_LIVE_BACKEND"] == "1" {
    print("Running LIVE backend integration test (BLT_LIVE_BACKEND=1)...")
    testLiveBackendIntegration()
}

try? FileManager.default.removeItem(at: tmpBase)   // clean temp test stores
print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
