// Black Label Trading — the candlestick chart screen (the headline daily-driver surface).
// Renders the USER'S imported OHLC bars (same source as the backtester) as candles /
// Heikin-Ashi / Renko / line, with indicator overlays (MA/EMA/RSI/MACD/VWAP/Bollinger/ATR)
// and persisted drawing tools (trendline / level / zone / fib). Honest framing: the chart is
// empty until the user loads their own bars — nothing is downloaded, sampled, or invented.
import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers

// Which indicators are currently shown. Persists in UserDefaults so the layout sticks.
struct ChartIndicatorSet: Codable, Equatable {
    var sma = false
    var ema = true
    var bollinger = false
    var vwap = false
    var rsi = false
    var macd = false
    var atr = false
    var smaPeriod = 20
    var emaPeriod = 9
    var ema2Period = 21      // second EMA (demo shows EMA9 gold + EMA21 blue)
    var bbPeriod = 20
    var bbK = 2.0
    var vwapWindow = 20
    var rsiPeriod = 14
    var atrPeriod = 14
    var logScale = false        // logarithmic price axis (for multiplicative instruments)
}

// Timeframe resampling: aggregate the user's base bars up to a coarser interval. This is an
// honest down-sampling of the user's OWN data — no new bars are invented.
enum ChartTimeframe: String, CaseIterable, Identifiable, Codable {
    case base = "Base", x5 = "×5", x15 = "×15", x60 = "×60", daily = "Daily"
    var id: String { rawValue }
    var factor: Int { switch self { case .base: return 1; case .x5: return 5; case .x15: return 15; case .x60: return 60; case .daily: return 0 } }
}

enum Resampler {
    // Group `n` consecutive bars into one aggregate bar (open=first, close=last, high=max, low=min, vol=sum).
    static func resample(_ bars: [Bar], factor: Int) -> [Bar] {
        guard factor > 1, bars.count > factor else { return bars }
        var out: [Bar] = []
        var i = 0
        while i < bars.count {
            let chunk = Array(bars[i..<min(i + factor, bars.count)])
            if let f = chunk.first, let l = chunk.last {
                out.append(Bar(date: f.date, open: f.open,
                               high: chunk.map(\.high).max() ?? f.high,
                               low: chunk.map(\.low).min() ?? f.low,
                               close: l.close, volume: chunk.reduce(0) { $0 + $1.volume }))
            }
            i += factor
        }
        return out
    }
    // Daily aggregation by calendar day.
    static func daily(_ bars: [Bar], calendar: Calendar = .current) -> [Bar] {
        let groups = Dictionary(grouping: bars) { calendar.startOfDay(for: $0.date) }
        return groups.keys.sorted().compactMap { day in
            let chunk = (groups[day] ?? []).sorted { $0.date < $1.date }
            guard let f = chunk.first, let l = chunk.last else { return nil }
            return Bar(date: day, open: f.open, high: chunk.map(\.high).max() ?? f.high,
                       low: chunk.map(\.low).min() ?? f.low, close: l.close, volume: chunk.reduce(0) { $0 + $1.volume })
        }
    }
}

// Where the chart's bars come from. Live = the buyer's own WealthCharts capture (via the
// product's own backend); Import = a CSV the user pastes. Both are the user's OWN data — Live
// is never fabricated, it shows an honest "feed offline" state when capture isn't flowing.
enum ChartSource: String, CaseIterable, Identifiable {
    case live = "Live feed", importCSV = "Import"
    var id: String { rawValue }
    var icon: String { self == .live ? "dot.radiowaves.left.and.right" : "square.and.arrow.down" }
}

struct ChartScreen: View {
    @EnvironmentObject var drawings: DrawingStore
    @EnvironmentObject var feed: FeedClient
    @State private var source: ChartSource = .live
    @State private var symbol = ""
    @State private var baseBars: [Bar] = []
    @State private var csvText = ""
    @State private var importNote = ""
    @State private var style: CandleStyle = .candles
    @State private var timeframe: ChartTimeframe = .base
    @State private var ind = ChartScreen.loadIndicators()
    @State private var renkoBrick: Double = 0
    @State private var showImporter = false

    // Live feed state
    @State private var liveTick: LiveTick? = nil
    @State private var activeFire: FireRow? = nil      // engine's entry/stop/target/exit, shown on chart
    @State private var feedNote = ""
    @State private var loadingFeed = false
    @State private var livePollTask: Task<Void, Never>? = nil
    @State private var lastLiveClose: Double? = nil

    // Drawing state
    @State private var activeTool: DrawingKind? = nil
    @State private var dragStart: CGPoint? = nil
    @State private var dragCurrent: CGPoint? = nil
    @State private var showFib = false

    // Zoom/pan: a visible window [winStart, winStart+winCount) over the candle index space.
    @State private var winStart = 0
    @State private var winCount = 80    // right-anchored default window — full, premium look (not stretched)
    @State private var crosshair: Int? = nil

    private static let indKey = "com.blacklabel.trading.chartIndicators"
    static func loadIndicators() -> ChartIndicatorSet {
        guard let d = UserDefaults.standard.data(forKey: indKey),
              let s = try? JSONDecoder().decode(ChartIndicatorSet.self, from: d) else { return ChartIndicatorSet() }
        return s
    }
    private func saveIndicators() {
        if let d = try? JSONEncoder().encode(ind) { UserDefaults.standard.set(d, forKey: Self.indKey) }
    }

    // Bars after timeframe resampling.
    private var bars: [Bar] {
        switch timeframe {
        case .base: return baseBars
        case .daily: return Resampler.daily(baseBars)
        default: return Resampler.resample(baseBars, factor: timeframe.factor)
        }
    }
    // Candles for the current style.
    private var candles: [Candle] {
        switch style {
        case .candles, .line: return CandleTransform.candles(bars)
        case .heikinAshi:     return CandleTransform.heikinAshi(bars)
        case .renko:          return CandleTransform.renko(bars, brickSize: renkoBrick > 0 ? renkoBrick : CandleTransform.suggestedBrickSize(bars))
        }
    }
    // Visible window of candles.
    private var visible: [Candle] {
        let all = candles
        guard winCount > 0, winCount < all.count else { return all }
        let start = max(0, min(winStart, all.count - winCount))
        return Array(all[start..<min(start + winCount, all.count)])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(BLTheme.stroke)
            if source == .live { feedBanner }
            if baseBars.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        toolbar
                        priceChartCard
                        volumePane
                        if ind.rsi { rsiPane }
                        if ind.macd { macdPane }
                        if ind.atr { atrPane }
                        drawingsList
                    }.padding(20)
                }
            }
        }
        .onAppear {
            if source == .live { Task { await refreshFeed() } }
        }
        .onChange(of: source) { newSource in
            stopLivePoll()
            if newSource == .live { Task { await refreshFeed() } }
        }
        .onChange(of: feed.state) { _ in
            // When the feed transitions to flowing while we're live, (re)start tick polling.
            if source == .live && feed.state.isFlowing { startLivePoll() } else { stopLivePoll() }
        }
        .onDisappear { stopLivePoll() }
    }

    // MARK: Honest live-feed banner — every word reflects a REAL backend response. No "connected"
    // unless the buyer's own WC session is genuinely reachable and flowing.
    @ViewBuilder private var feedBanner: some View {
        let st = feed.state
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(bannerColor(st).opacity(0.25)).frame(width: 18, height: 18)
                Circle().fill(bannerColor(st)).frame(width: 8, height: 8)
                    .modifier(LivePulse(active: st.isFlowing))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(st.label).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Text(bannerHint(st)).font(.system(size: 10, design: .rounded)).foregroundColor(BLTheme.sub)
            }
            Spacer()
            if loadingFeed || feed.connecting {
                ProgressView().controlSize(.small).tint(BLTheme.gold)
            }
            if st == .loggedOut || st == .notSignedIn || st == .connecting {
                GhostButton(label: "Connect WealthCharts", icon: "bolt.horizontal") {
                    Task { loadingFeed = true; await feed.launchCapture(); await refreshFeed(); loadingFeed = false }
                }
            }
            if st == .offline {
                GhostButton(label: "Retry", icon: "arrow.clockwise") { Task { await reconnectFeed() } }
            }
            GhostButton(label: "Refresh", icon: "arrow.clockwise") { Task { await refreshFeed() } }
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .background(bannerColor(st).opacity(0.07))
        .overlay(Rectangle().fill(bannerColor(st).opacity(0.35)).frame(height: 1), alignment: .bottom)
    }
    private func bannerColor(_ s: FeedState) -> Color {
        switch s {
        case .live: return BLTheme.green
        case .idle, .connecting: return BLTheme.gold
        case .loggedOut, .notSignedIn: return BLTheme.red
        case .offline: return BLTheme.sub
        }
    }
    private func bannerHint(_ s: FeedState) -> String {
        switch s {
        case .live: return "Ticks flowing from your WealthCharts session into your local store."
        case .idle: return "Feed reachable, no fresh ticks right now (market quiet / closed)."
        case .connecting: return "Capture window open — waiting for your WealthCharts feed to come up."
        case .loggedOut: return "Sign in to WealthCharts in the capture window to start your own feed."
        case .notSignedIn: return "Backend reachable — connecting your session…"
        case .offline: return "The product backend isn't reachable. It serves your own captured data."
        }
    }

    // MARK: Header (title + source toggle + symbol + load)
    private var header: some View {
        HStack(alignment: .top) {
            ScreenTitle(title: "Chart", subtitle: "Candlestick / Heikin-Ashi / Renko on YOUR live or imported bars — indicators, drawing tools, multi-timeframe. Nothing downloaded from us or invented.", icon: "chart.xyaxis.line")
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                // Source toggle: Live feed (own capture) vs Import (CSV).
                Picker("", selection: $source) {
                    ForEach(ChartSource.allCases) { s in
                        Label(s.rawValue, systemImage: s.icon).tag(s)
                    }
                }.labelsHidden().pickerStyle(.segmented).fixedSize()
                HStack(spacing: 8) {
                    if source == .live {
                        liveSymbolField
                        GoldButton(label: loadingFeed ? "Loading…" : "Load", icon: "arrow.down.circle") {
                            Task { await loadLiveBars() }
                        }
                    } else {
                        TextField("Symbol", text: $symbol)
                            .textFieldStyle(.plain).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                            .frame(width: 90).padding(.vertical, 8).padding(.horizontal, 11)
                            .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.stroke, lineWidth: 1))
                            .onChange(of: symbol) { _ in winStart = 0 }
                        GoldButton(label: "Load bars", icon: "square.and.arrow.down") { showImporter = true }
                    }
                }
                let note = source == .live ? feedNote : importNote
                if !note.isEmpty {
                    Text(note).font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(baseBars.isEmpty ? BLTheme.red : BLTheme.green)
                }
            }
        }
        .padding(20)
        .sheet(isPresented: $showImporter) { importSheet.sheetCloseBar() }
    }

    // Live symbol picker: a menu of the buyer's own captured symbols + free-text entry.
    private var liveSymbolField: some View {
        HStack(spacing: 6) {
            TextField("Symbol", text: $symbol)
                .textFieldStyle(.plain).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                .frame(width: 110).padding(.vertical, 8).padding(.horizontal, 11)
                .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.stroke, lineWidth: 1))
                .onSubmit { Task { await loadLiveBars() } }
                .onChange(of: symbol) { _ in winStart = 0 }
            if !feed.symbols.pickerList.isEmpty {
                Menu {
                    ForEach(feed.symbols.pickerList, id: \.self) { s in
                        Button(s) { symbol = s; Task { await loadLiveBars() } }
                    }
                } label: {
                    Image(systemName: "chevron.down.circle").font(.system(size: 14)).foregroundColor(BLTheme.gold)
                }.menuStyle(.borderlessButton).frame(width: 22)
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if source == .live {
            liveEmptyState
        } else {
            VStack {
                Spacer()
                EmptyState(icon: "chart.xyaxis.line", title: "Load your own price data",
                           hint: "Import an OHLC CSV (date,open,high,low,close[,volume]) for a symbol. The chart, indicators and drawings all run on your data — nothing is fetched or faked.")
                GoldButton(label: "Import OHLC CSV", icon: "square.and.arrow.down") { showImporter = true }
                Spacer()
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // Live empty state is HONEST about why the chart is empty (feed off vs no symbol chosen vs
    // store cold) — and never shows a fake candle to fill the space.
    @ViewBuilder private var liveEmptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            switch feed.state {
            case .offline:
                EmptyState(icon: "wifi.slash", title: "Your data backend isn't running",
                           hint: "Black Label Trading ships its OWN data backend inside the app. It captures YOUR WealthCharts feed into a local store on this Mac (nothing leaves your machine) and serves it here. Start it, then refresh — or switch to Import to chart a CSV.")
                HStack(spacing: 8) {
                    GoldButton(label: "Start my backend", icon: "bolt.fill") {
                        Task { loadingFeed = true; await feed.ensureBackendRunning(); await reconnectFeed(); loadingFeed = false }
                    }
                    GhostButton(label: "Retry connection", icon: "arrow.clockwise") { Task { await reconnectFeed() } }
                }
            case .loggedOut, .notSignedIn, .connecting:
                EmptyState(icon: "dot.radiowaves.left.and.right", title: "Connect your WealthCharts feed",
                           hint: "Open the capture window and sign into YOUR WealthCharts account. Bars start landing in your local store within ~30s — then they appear here. Nothing is ever fabricated.")
                GoldButton(label: "Connect WealthCharts", icon: "bolt.horizontal") {
                    Task { loadingFeed = true; await feed.launchCapture(); await refreshFeed(); loadingFeed = false }
                }
            default:
                if feed.symbols.pickerList.isEmpty {
                    EmptyState(icon: "hourglass", title: "Feed connected — store is still filling",
                               hint: "Your WealthCharts session is reachable but your local store has no bars yet. Leave a chart open in WealthCharts; bars accumulate here. Honest empty until real bars arrive.")
                } else {
                    EmptyState(icon: "chart.xyaxis.line", title: "Pick a symbol to chart",
                               hint: "Your captured symbols are in the dropdown next to the symbol field. Choose one to load its real bars.")
                    if let busiest = feed.symbols.busiest {
                        GoldButton(label: "Chart \(busiest)", icon: "chart.bar") { symbol = busiest; Task { await loadLiveBars() } }
                    }
                }
            }
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }

    // MARK: - Live feed loading (never fabricates — empty store yields an empty chart).
    private func refreshFeed() async {
        await feed.refreshStatus()
        // Auto-pick the busiest captured symbol on first entry if none chosen.
        if symbol.trimmingCharacters(in: .whitespaces).isEmpty, let b = feed.symbols.busiest {
            symbol = b
        }
        if !symbol.trimmingCharacters(in: .whitespaces).isEmpty { await loadLiveBars() }
        if feed.state.isFlowing { startLivePoll() }
    }
    private func reconnectFeed() async {
        loadingFeed = true; defer { loadingFeed = false }
        await feed.connect(email: "local@blacklabel")
        await refreshFeed()
    }
    private func loadLiveBars() async {
        let s = symbol.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { feedNote = "Enter or pick a symbol."; return }
        loadingFeed = true; defer { loadingFeed = false }
        let bars = await feed.recentBars(symbol: s, limit: 400)
        baseBars = bars; crosshair = nil; liveTick = nil; lastLiveClose = nil
        // Right-anchor the last ~80 bars so a freshly-loaded live chart reads full & premium (like
        // the website demo) instead of stretching sparse bars across the whole pane. "Fit" resets to all.
        winCount = bars.count > 0 ? min(80, bars.count) : 0; winStart = max(0, bars.count - winCount)
        renkoBrick = CandleTransform.suggestedBrickSize(baseBars)
        if bars.isEmpty {
            feedNote = feed.state.hasData ? "No bars captured for \(s) yet." : "Feed offline — no bars to show."
        } else {
            feedNote = "Loaded \(bars.count) live bars for \(s)."
        }
        if feed.state.isFlowing { startLivePoll() }
    }

    // Poll the live last-price tick and fold it into the most-recent bar (moves the close,
    // widens high/low). A new candle is NEVER invented client-side — only the backend's real
    // aggregation prints new bars; we re-pull periodically to pick those up.
    private func startLivePoll() {
        guard source == .live, livePollTask == nil else { return }
        livePollTask = Task {
            var sinceRepull = 0
            var sinceFires = 0
            while !Task.isCancelled {
                let s = symbol.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty {
                    if let t = await feed.liveTick(symbol: s) {
                        liveTick = t
                        lastLiveClose = t.price
                        baseBars = LiveFold.apply(t, to: baseBars)
                    }
                    sinceRepull += 1
                    sinceFires += 1
                    // Pull the engine's active trade ~every 2s so entry/stop/target + exit show live.
                    if sinceFires >= 5 {
                        sinceFires = 0
                        let fires = await feed.recentFires(limit: 40)
                        activeFire = fires.first { ($0.symbol == s || $0.symbol == nil) }
                    }
                    // Every ~30s re-pull recent bars so newly-printed candles appear, and refresh
                    // the honest feed status banner.
                    if sinceRepull >= 75 {
                        sinceRepull = 0
                        await feed.refreshStatus()
                        let fresh = await feed.recentBars(symbol: s, limit: 400)
                        if !fresh.isEmpty {
                            var merged = fresh
                            if let t = liveTick { merged = LiveFold.apply(t, to: merged) }
                            baseBars = merged
                            if winCount > 0 { winStart = max(0, merged.count - winCount) }  // stay glued to the live edge
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 400_000_000)  // 0.4s tick poll — near-real-time movement
            }
        }
    }
    private func stopLivePoll() { livePollTask?.cancel(); livePollTask = nil }

    // MARK: Toolbar (style / timeframe / indicators / drawing tools / zoom)
    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                segmented("STYLE", CandleStyle.allCases, $style) { $0.rawValue }
                segmented("TIMEFRAME", ChartTimeframe.allCases, $timeframe) { $0.rawValue }
                Spacer()
                // Zoom controls
                HStack(spacing: 6) {
                    iconBtn("minus.magnifyingglass") { zoom(out: true) }
                    iconBtn("plus.magnifyingglass") { zoom(out: false) }
                    iconBtn("arrow.left") { pan(-1) }
                    iconBtn("arrow.right") { pan(1) }
                    iconBtn("arrow.up.left.and.arrow.down.right") { winCount = 0; winStart = 0 }   // fit
                }
            }
            // Indicator toggles
            HStack(spacing: 8) {
                indToggle("SMA \(ind.smaPeriod)", $ind.sma, BLTheme.gold)
                indToggle("EMA \(ind.emaPeriod)", $ind.ema, BLTheme.goldHi)
                indToggle("Bollinger", $ind.bollinger, BLTheme.blue)
                indToggle("VWAP", $ind.vwap, BLTheme.green)
                indToggle("RSI", $ind.rsi, BLTheme.blue)
                indToggle("MACD", $ind.macd, BLTheme.goldDim)
                indToggle("ATR", $ind.atr, BLTheme.red)
                indToggle("Log", $ind.logScale, BLTheme.goldDim)
                Spacer()
                GhostButton(label: "Indicator settings", icon: "slider.horizontal.3") { showIndSettings.toggle() }
            }
            if showIndSettings { indicatorSettings }
            // Drawing tools
            HStack(spacing: 8) {
                Text("DRAW").font(.system(size: 9.5, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.8)
                ForEach(DrawingKind.allCases) { k in
                    drawToolBtn(k)
                }
                if !drawings.drawings(for: effectiveSymbol).isEmpty {
                    GhostButton(label: "Clear drawings", icon: "trash", tint: BLTheme.red) { drawings.clear(effectiveSymbol) }
                }
                Toggle(isOn: $showFib) { Text("Auto-Fib").font(.system(size: 11, weight: .semibold, design: .rounded)) }
                    .toggleStyle(.checkbox).tint(BLTheme.gold)
                Spacer()
                if style == .renko {
                    HStack(spacing: 5) {
                        Text("BRICK").font(.system(size: 9.5, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.sub)
                        TextField("", value: $renkoBrick, format: .number).textFieldStyle(.plain).frame(width: 60)
                            .font(.system(size: 12, design: .rounded)).foregroundColor(BLTheme.text)
                            .padding(6).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                }
            }
        }
        .onChange(of: ind) { _ in saveIndicators() }
    }
    @State private var showIndSettings = false

    private var indicatorSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                stepField("SMA period", $ind.smaPeriod, 1...400)
                stepField("EMA period", $ind.emaPeriod, 1...400)
                stepField("BB period", $ind.bbPeriod, 2...400)
                dblStep("BB ×", $ind.bbK, 0.5...4, step: 0.5)
            }
            HStack(spacing: 10) {
                stepField("VWAP window", $ind.vwapWindow, 1...1000)
                stepField("RSI period", $ind.rsiPeriod, 2...100)
                stepField("ATR period", $ind.atrPeriod, 2...100)
                Spacer()
            }
        }
        .padding(12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
    }

    // MARK: Price chart card (candles + overlays + drawing layer + crosshair)
    private var priceChartCard: some View {
        let vis = visible
        // Robust auto-fit — identical math to the headless render proof; one session-gap candle
        // can't squash the rest of the chart.
        let dom = ChartScale.robustDomain(vis)
        let yDomain = dom.lo...dom.hi
        // Round-clock x-axis ticks + session breaks (shared with the headless renderer). timeTicks
        // returns positions within `vis`; map them to the candle index the chart plots on.
        let xTicks = ChartScale.timeTicks(vis.map(\.date), maxLabels: 7).compactMap { t -> (idx: Int, label: String, brk: Bool)? in
            guard t.index >= 0, t.index < vis.count else { return nil }
            return (vis[t.index].index, t.label, t.isSessionBreak)
        }
        let xTickLabels = Dictionary(xTicks.map { ($0.idx, $0.label) }, uniquingKeysWith: { a, _ in a })
        let sessionBreaks = xTicks.filter(\.brk).map(\.idx)
        // Nice-tick gridline values for the y-axis (1/2/2.5/5 × 10ⁿ steps).
        let yTicks = ChartScale.ticks(lo: dom.lo, hi: dom.hi, target: 7)
        let xLo = vis.first?.index ?? 0
        let xHi = (vis.last?.index ?? 1) + 1
        // Indicator series aligned to the (full) candle index space, then filtered to visible.
        let closes = candles.map(\.close)
        let smaS = ind.sma ? Indicators.sma(closes, ind.smaPeriod) : []
        let emaS = ind.ema ? Indicators.ema(closes, ind.emaPeriod) : []
        let ema2S = ind.ema ? Indicators.ema(closes, ind.ema2Period) : []
        let bb = ind.bollinger ? ChartIndicators.bollinger(closes, period: ind.bbPeriod, k: ind.bbK) : nil
        let vwapBars = candleBars()
        let vwapS = ind.vwap ? ChartIndicators.vwap(vwapBars, window: ind.vwapWindow) : []
        let fibs = showFib ? Fibonacci.levels(bars) : []

        return Panel(title: chartTitle, icon: style.icon, accent: (vis.last?.up ?? true) ? BLTheme.green : BLTheme.red) {
            crosshairReadout(vis)
            Chart {
                ForEach(vis) { c in
                    if style == .line {
                        LineMark(x: .value("i", c.index), y: .value("close", c.close))
                            .interpolationMethod(.monotone).foregroundStyle(BLTheme.gold).lineStyle(StrokeStyle(lineWidth: 2))
                    } else {
                        // Wick
                        // Wick — bold and always visible (high↔low), even on small-range bars.
                        RuleMark(x: .value("i", c.index), yStart: .value("low", c.low), yEnd: .value("high", c.high))
                            .foregroundStyle(c.up ? BLTheme.gold.opacity(0.95) : BLTheme.red.opacity(0.95)).lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                        // Body — thick gold bull / red bear, matching the website demo.
                        RectangleMark(x: .value("i", c.index),
                                      yStart: .value("o", c.up ? c.open : c.close),
                                      yEnd: .value("c", c.up ? c.close : c.open),
                                      width: .ratio(0.88))
                            .foregroundStyle(c.up ? BLTheme.gold : BLTheme.red).cornerRadius(1)
                    }
                }
                // Dotted gold session separators (overnight/weekend gaps) — explains the holes.
                ForEach(sessionBreaks, id: \.self) { bi in
                    RuleMark(x: .value("sep", bi))
                        .foregroundStyle(BLTheme.gold.opacity(0.18))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2,4]))
                }
                overlayMarks(smaS, color: BLTheme.gold, name: "SMA")
                overlayMarks(emaS, color: BLTheme.goldHi, name: "EMA9")        // gold EMA9 (demo)
                overlayMarks(ema2S, color: BLTheme.blue, name: "EMA21")        // blue EMA21 (demo)
                if let bb = bb {
                    overlayMarks(bb.upper, color: BLTheme.blue.opacity(0.7), name: "BB↑", dashed: true)
                    overlayMarks(bb.mid, color: BLTheme.blue.opacity(0.4), name: "BB", dashed: true)
                    overlayMarks(bb.lower, color: BLTheme.blue.opacity(0.7), name: "BB↓", dashed: true)
                }
                overlayMarks(vwapS, color: BLTheme.green, name: "VWAP")
                ForEach(fibs) { f in
                    RuleMark(y: .value("fib", f.price))
                        .foregroundStyle(BLTheme.gold.opacity(0.35)).lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3,3]))
                        .annotation(position: .trailing, alignment: .leading) {
                            Text(String(format: "%.3f", f.ratio)).font(.system(size: 8, design: .rounded)).foregroundColor(BLTheme.gold.opacity(0.7))
                        }
                }
                // Live last-price marker — only when a genuine fresh tick exists (never faked).
                if let lp = livePriceLine {
                    RuleMark(y: .value("live", lp))
                        .foregroundStyle((vis.last?.up ?? true) ? BLTheme.green : BLTheme.red)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2,3]))
                        .annotation(position: .trailing, alignment: .leading, spacing: 0) {
                            Text(TradeMath.num(lp))
                                .font(.system(size: 10, weight: .heavy, design: .rounded)).monospacedDigit()
                                .foregroundColor(Color(hex: 0x0E0E0E))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background((vis.last?.up ?? true) ? BLTheme.green : BLTheme.red)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                }
                // Engine trade overlay — entry / stop / target (and exit) for the active signal.
                // Drawn ONLY from a real recorded fire; nil when flat -> nothing (never fabricated).
                if let f = activeFire {
                    RuleMark(y: .value("entry", f.entry))
                        .foregroundStyle(BLTheme.gold).lineStyle(StrokeStyle(lineWidth: 1.4, dash: [6,3]))
                        .annotation(position: .leading, alignment: .trailing, spacing: 2) {
                            Text("\(f.direction.uppercased()) \(f.outcome == nil ? "ENTRY" : "EXIT " + (f.outcome ?? "").uppercased()) \(TradeMath.num(f.entry))")
                                .font(.system(size: 8.5, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.gold)
                        }
                    if let st = f.stop {
                        RuleMark(y: .value("stop", st))
                            .foregroundStyle(BLTheme.red).lineStyle(StrokeStyle(lineWidth: 1, dash: [4,3]))
                            .annotation(position: .trailing, alignment: .leading) {
                                Text("STOP \(TradeMath.num(st))").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundColor(BLTheme.red)
                            }
                    }
                    if let tg = f.target {
                        RuleMark(y: .value("tgt", tg))
                            .foregroundStyle(BLTheme.green).lineStyle(StrokeStyle(lineWidth: 1, dash: [4,3]))
                            .annotation(position: .trailing, alignment: .leading) {
                                Text("TGT \(TradeMath.num(tg))").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundColor(BLTheme.green)
                            }
                    }
                }
            }
            .chartXScale(domain: Double(xLo)...Double(xHi))
            .chartYScale(domain: yDomain, type: (ind.logScale && dom.lo > 0) ? .log : .linear)
            .chartYAxis { AxisMarks(position: .leading, values: yTicks) { v in AxisGridLine().foregroundStyle(BLTheme.stroke.opacity(0.4))
                AxisValueLabel { if let d = v.as(Double.self) { Text(TradeMath.num(d)).font(.system(size: 9)).foregroundStyle(BLTheme.sub) } } } }
            .chartXAxis { AxisMarks(values: xTicks.map(\.idx)) { v in AxisGridLine().foregroundStyle(BLTheme.stroke.opacity(0.3))
                AxisValueLabel { if let i = v.as(Int.self), let lbl = xTickLabels[i] {
                    Text(lbl).font(.system(size: 8)).monospacedDigit().foregroundStyle(BLTheme.sub) } } } }
            .frame(height: 360)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    drawingLayer(proxy: proxy, geo: geo, yDomain: yDomain, xLo: xLo, xHi: xHi)
                }
            }
            legend(bb: bb != nil)
        }
    }

    private var chartTitle: String {
        let s = effectiveSymbol.isEmpty ? "—" : effectiveSymbol
        let live = (source == .live && feed.state.isFlowing) ? " · LIVE" : ""
        return "\(s) · \(style.rawValue) · \(timeframe.rawValue) · \(bars.count) bars\(live)"
    }

    // The live last-price line: shown only on a flowing live feed with a real tick. nil otherwise
    // (import mode, offline feed, or no tick) — so the chart never draws a fabricated price.
    private var livePriceLine: Double? {
        guard source == .live, feed.state.isFlowing, style != .renko else { return nil }
        if let t = liveTick { return t.price }
        return lastLiveClose
    }

    // OHLC bars matching the current candle index space (for VWAP, which needs real volume).
    private func candleBars() -> [Bar] {
        switch style {
        case .renko: return candles.map { Bar(date: $0.date, open: $0.open, high: $0.high, low: $0.low, close: $0.close, volume: $0.volume) }
        default:     return bars
        }
    }

    @ChartContentBuilder
    private func overlayMarks(_ series: [Double?], color: Color, name: String, dashed: Bool = false) -> some ChartContent {
        ForEach(Array(series.enumerated()).filter { winCount == 0 || ($0.offset >= winStart && $0.offset < winStart + winCount) }, id: \.offset) { item in
            if let y = item.element {
                LineMark(x: .value("i", item.offset), y: .value(name, y), series: .value("s", name))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, dash: dashed ? [4,3] : []))
            }
        }
    }

    // MARK: Crosshair OHLC readout
    @ViewBuilder private func crosshairReadout(_ vis: [Candle]) -> some View {
        let c = crosshair.flatMap { idx in candles.first { $0.index == idx } } ?? vis.last
        if let c = c {
            HStack(spacing: 14) {
                Text(c.date.formatted(date: .abbreviated, time: timeframe == .daily ? .omitted : .shortened))
                    .font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(BLTheme.gold)
                ohlc("O", c.open); ohlc("H", c.high); ohlc("L", c.low); ohlc("C", c.close)
                if c.volume > 0 { ohlc("V", c.volume) }
                Spacer()
            }.padding(.bottom, 2)
        }
    }
    @ViewBuilder private func ohlc(_ l: String, _ v: Double) -> some View {
        HStack(spacing: 3) {
            Text(l).font(.system(size: 9.5, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.sub)
            Text(TradeMath.num(v)).font(.system(size: 11.5, weight: .semibold, design: .rounded)).monospacedDigit().foregroundColor(BLTheme.text)
        }
    }

    // MARK: Drawing layer (maps screen <-> data coords, persists on drag end)
    // Swift Charts' ChartProxy works in the PLOT AREA's coordinate space, while gestures and
    // the Canvas work in the overlay (chart-frame) space. We translate by the plot origin so
    // drawings land exactly under the cursor regardless of axis insets.
    @ViewBuilder
    private func drawingLayer(proxy: ChartProxy, geo: GeometryProxy, yDomain: ClosedRange<Double>, xLo: Int, xHi: Int) -> some View {
        let plot = geo[proxy.plotAreaFrame]   // plot rect in overlay (chart-frame) coords
        ZStack(alignment: .topLeading) {
            // Persisted drawings (drawn in overlay space; plot origin added back).
            Canvas { ctx, _ in
                for d in drawings.drawings(for: effectiveSymbol) {
                    drawShape(d, ctx: &ctx, proxy: proxy, plot: plot)
                }
                // Live preview while dragging (drag points are already in overlay space).
                if let s = dragStart, let cur = dragCurrent, let tool = activeTool {
                    var p = Path()
                    switch tool {
                    case .horizontal: p.move(to: CGPoint(x: plot.minX, y: cur.y)); p.addLine(to: CGPoint(x: plot.maxX, y: cur.y))
                    case .rect: p.addRect(CGRect(x: min(s.x,cur.x), y: min(s.y,cur.y), width: abs(cur.x-s.x), height: abs(cur.y-s.y)))
                    case .fib:
                        for r in [0.0,0.236,0.382,0.5,0.618,0.786,1.0] {
                            let y = s.y + (cur.y - s.y) * r
                            p.move(to: CGPoint(x: plot.minX, y: y)); p.addLine(to: CGPoint(x: plot.maxX, y: y))
                        }
                    default: p.move(to: s); p.addLine(to: cur)
                    }
                    ctx.stroke(p, with: .color(BLTheme.gold.opacity(0.6)), style: StrokeStyle(lineWidth: 1.5, dash: [4,3]))
                }
            }
            // Crosshair vertical line (proxy.position is plot-space → add plot origin).
            if let xi = crosshair, let px = proxy.position(forX: Double(xi)) {
                Path { p in p.move(to: CGPoint(x: px + plot.minX, y: plot.minY)); p.addLine(to: CGPoint(x: px + plot.minX, y: plot.maxY)) }
                    .stroke(BLTheme.gold.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [2,2]))
            }
            Rectangle().fill(Color.clear).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { val in
                        if activeTool != nil {
                            if dragStart == nil { dragStart = val.startLocation }
                            dragCurrent = val.location
                        }
                        // Update crosshair to nearest candle (translate to plot space first).
                        if let xv: Double = proxy.value(atX: val.location.x - plot.minX) { crosshair = Int(xv.rounded()) }
                    }
                    .onEnded { val in
                        defer { dragStart = nil; dragCurrent = nil }
                        guard let tool = activeTool, let s = dragStart else { return }
                        // Translate overlay coords → plot-space before reading data values.
                        guard let x1: Double = proxy.value(atX: s.x - plot.minX), let x2: Double = proxy.value(atX: val.location.x - plot.minX),
                              let y1: Double = proxy.value(atY: s.y - plot.minY), let y2: Double = proxy.value(atY: val.location.y - plot.minY) else { return }
                        let d = Drawing(kind: tool, x1: x1, y1: y1, x2: x2, y2: y2)
                        drawings.add(d, to: effectiveSymbol)
                        activeTool = nil
                    })
        }
    }

    private func drawShape(_ d: Drawing, ctx: inout GraphicsContext, proxy: ChartProxy, plot: CGRect) {
        // proxy.position(...) returns plot-space coords; add plot origin to get overlay coords.
        func pt(_ x: Double, _ y: Double) -> CGPoint? {
            guard let px = proxy.position(forX: x), let py = proxy.position(forY: y) else { return nil }
            return CGPoint(x: px + plot.minX, y: py + plot.minY)
        }
        func yPos(_ y: Double) -> CGFloat? { proxy.position(forY: y).map { $0 + plot.minY } }
        let color = BLTheme.gold.opacity(0.85)
        switch d.kind {
        case .trendline:
            if let a = pt(d.x1, d.y1), let b = pt(d.x2, d.y2) {
                var p = Path(); p.move(to: a); p.addLine(to: b)
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.8))
            }
        case .horizontal:
            if let y = yPos(d.y1) {
                var p = Path(); p.move(to: CGPoint(x: plot.minX, y: y)); p.addLine(to: CGPoint(x: plot.maxX, y: y))
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.4, dash: [6,3]))
            }
        case .rect:
            if let a = pt(d.x1, d.y1), let b = pt(d.x2, d.y2) {
                let r = CGRect(x: min(a.x,b.x), y: min(a.y,b.y), width: abs(b.x-a.x), height: abs(b.y-a.y))
                ctx.fill(Path(r), with: .color(BLTheme.gold.opacity(0.10)))
                ctx.stroke(Path(r), with: .color(color), style: StrokeStyle(lineWidth: 1.2))
            }
        case .fib:
            for f in Fibonacci.levels(from: d.y1, to: d.y2) {
                if let y = yPos(f.price) {
                    var p = Path(); p.move(to: CGPoint(x: plot.minX, y: y)); p.addLine(to: CGPoint(x: plot.maxX, y: y))
                    ctx.stroke(p, with: .color(BLTheme.gold.opacity(0.5)), style: StrokeStyle(lineWidth: 0.9, dash: [3,3]))
                }
            }
        }
    }

    // MARK: Indicator panes (RSI / MACD / ATR below the price chart)
    private var rsiPane: some View {
        let r = Indicators.rsi(candles.map(\.close), ind.rsiPeriod)
        return Panel(title: "RSI (\(ind.rsiPeriod))", icon: "waveform.path.ecg", accent: BLTheme.blue) {
            Chart {
                RuleMark(y: .value("70", 70)).foregroundStyle(BLTheme.red.opacity(0.4)).lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3,3]))
                RuleMark(y: .value("30", 30)).foregroundStyle(BLTheme.green.opacity(0.4)).lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3,3]))
                paneLine(r, color: BLTheme.blue)
            }
            .chartYScale(domain: 0...100).frame(height: 120)
            .chartXScale(domain: paneXDomain)
            .chartYAxis { AxisMarks(position: .trailing, values: [30,50,70]) { _ in AxisValueLabel().foregroundStyle(BLTheme.sub) } }
            .chartXAxis(.hidden)
        }
    }
    private var macdPane: some View {
        let m = ChartIndicators.macd(candles.map(\.close))
        return Panel(title: "MACD (12,26,9)", icon: "chart.bar.xaxis", accent: BLTheme.goldDim) {
            Chart {
                ForEach(idxFilter(m.histogram), id: \.0) { (i, v) in
                    BarMark(x: .value("i", i), y: .value("hist", v)).foregroundStyle(v >= 0 ? BLTheme.green.opacity(0.7) : BLTheme.red.opacity(0.7))
                }
                paneLine(m.macd, color: BLTheme.gold)
                paneLine(m.signal, color: BLTheme.blue)
                RuleMark(y: .value("0", 0)).foregroundStyle(BLTheme.sub.opacity(0.3))
            }
            .frame(height: 120).chartXScale(domain: paneXDomain)
            .chartYAxis { AxisMarks(position: .trailing) { _ in AxisValueLabel().foregroundStyle(BLTheme.sub) } }.chartXAxis(.hidden)
        }
    }
    private var atrPane: some View {
        let a = Indicators.atr(candleBars(), ind.atrPeriod)
        return Panel(title: "ATR (\(ind.atrPeriod))", icon: "waveform.path", accent: BLTheme.red) {
            Chart { paneArea(a, color: BLTheme.red) }
                .frame(height: 110).chartXScale(domain: paneXDomain)
                .chartYAxis { AxisMarks(position: .trailing) { _ in AxisValueLabel().foregroundStyle(BLTheme.sub) } }.chartXAxis(.hidden)
        }
    }

    // Volume sub-pane — only rendered when the user's bars actually carry volume (honest: a feed
    // capture with no volume column shows no fake bars). Coloured by candle direction.
    @ViewBuilder private var volumePane: some View {
        let vis = visible
        let hasVol = vis.contains { $0.volume > 0 }
        if hasVol {
            Panel(title: "Volume", icon: "chart.bar.fill", accent: BLTheme.gold) {
                Chart {
                    ForEach(vis) { c in
                        BarMark(x: .value("i", c.index), y: .value("vol", c.volume), width: .ratio(0.72))
                            .foregroundStyle((c.up ? BLTheme.green : BLTheme.red).opacity(0.30))
                    }
                }
                .frame(height: 90).chartXScale(domain: paneXDomain)
                .chartYAxis { AxisMarks(position: .trailing) { v in AxisValueLabel {
                    if let d = v.as(Double.self) { Text(TradeMath.compact(d)).font(.system(size: 8)).foregroundStyle(BLTheme.sub) } } } }
                .chartXAxis(.hidden)
            }
        }
    }
    private var paneXDomain: ClosedRange<Double> {
        let vis = visible
        return Double(vis.first?.index ?? 0)...Double((vis.last?.index ?? 1) + 1)
    }
    private func idxFilter(_ s: [Double?]) -> [(Int, Double)] {
        s.enumerated().compactMap { (i, v) -> (Int, Double)? in
            guard let v = v, winCount == 0 || (i >= winStart && i < winStart + winCount) else { return nil }
            return (i, v)
        }
    }
    @ChartContentBuilder private func paneLine(_ s: [Double?], color: Color) -> some ChartContent {
        ForEach(idxFilter(s), id: \.0) { (i, v) in
            LineMark(x: .value("i", i), y: .value("v", v), series: .value("s", "\(color)"))
                .interpolationMethod(.monotone).foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.6))
        }
    }
    @ChartContentBuilder private func paneArea(_ s: [Double?], color: Color) -> some ChartContent {
        ForEach(idxFilter(s), id: \.0) { (i, v) in
            AreaMark(x: .value("i", i), y: .value("v", v))
                .interpolationMethod(.monotone)
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.3), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
        }
    }

    // MARK: Legend + drawings list
    @ViewBuilder private func legend(bb: Bool) -> some View {
        HStack(spacing: 12) {
            if ind.sma { legendDot(BLTheme.gold, "SMA \(ind.smaPeriod)") }
            if ind.ema { legendDot(BLTheme.goldHi, "EMA \(ind.emaPeriod)") }
            if bb { legendDot(BLTheme.blue, "Bollinger \(ind.bbPeriod)/\(TradeMath.num(ind.bbK))") }
            if ind.vwap { legendDot(BLTheme.green, "VWAP \(ind.vwapWindow)") }
            Spacer()
            Text("Drag a drawing tool on the chart; drawings persist per symbol.")
                .font(.system(size: 9.5, design: .rounded)).foregroundColor(BLTheme.sub)
        }.padding(.top, 2)
    }
    private func legendDot(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { Circle().fill(c).frame(width: 7, height: 7); Text(t).font(.system(size: 9.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub) }
    }
    @ViewBuilder private var drawingsList: some View {
        let ds = drawings.drawings(for: effectiveSymbol)
        if !ds.isEmpty {
            Panel(title: "Drawings · \(effectiveSymbol)", icon: "pencil.and.ruler", accent: BLTheme.gold) {
                ForEach(ds) { d in
                    HStack(spacing: 10) {
                        Image(systemName: d.kind.icon).font(.system(size: 11, weight: .bold)).foregroundColor(Color(hex: 0x1A1305))
                            .frame(width: 24, height: 24).background(BLTheme.goldGrad).clipShape(RoundedRectangle(cornerRadius: 7))
                        Text(d.kind.label).font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                        Text("price \(TradeMath.num(d.y1))\(d.kind == .horizontal ? "" : " → \(TradeMath.num(d.y2))")")
                            .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub)
                        Spacer()
                        Button { drawings.remove(d, from: effectiveSymbol) } label: {
                            Image(systemName: "trash").font(.system(size: 11)).foregroundColor(BLTheme.red)
                        }.buttonStyle(.plain)
                    }.padding(.vertical, 7).padding(.horizontal, 11).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                }
            }
        }
    }

    // MARK: Small controls
    private var effectiveSymbol: String { symbol.trimmingCharacters(in: .whitespaces).isEmpty ? "UNTITLED" : symbol.uppercased() }

    private func drawToolBtn(_ k: DrawingKind) -> some View {
        Button { activeTool = (activeTool == k) ? nil : k } label: {
            HStack(spacing: 5) { Image(systemName: k.icon); Text(k.label) }
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundColor(activeTool == k ? Color(hex: 0x1A1305) : BLTheme.text)
                .padding(.vertical, 7).padding(.horizontal, 11)
                .background(activeTool == k ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2))
                .clipShape(Capsule()).overlay(Capsule().stroke(BLTheme.stroke, lineWidth: 1))
        }.buttonStyle(.plain)
    }
    private func indToggle(_ label: String, _ on: Binding<Bool>, _ tint: Color) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            HStack(spacing: 5) {
                Circle().fill(on.wrappedValue ? tint : BLTheme.sub.opacity(0.3)).frame(width: 7, height: 7)
                Text(label).font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(on.wrappedValue ? BLTheme.text : BLTheme.sub)
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .background(on.wrappedValue ? tint.opacity(0.14) : BLTheme.bg2).clipShape(Capsule())
            .overlay(Capsule().stroke(on.wrappedValue ? tint.opacity(0.5) : BLTheme.stroke, lineWidth: 1))
        }.buttonStyle(.plain)
    }
    private func iconBtn(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundColor(BLTheme.gold)
                .frame(width: 30, height: 28).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(BLTheme.stroke, lineWidth: 1))
        }.buttonStyle(.plain)
    }
    private func segmented<T: Hashable & Identifiable>(_ title: String, _ opts: [T], _ sel: Binding<T>, _ label: @escaping (T) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 9, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.8)
            Picker("", selection: sel) { ForEach(opts) { Text(label($0)).tag($0) } }.labelsHidden().pickerStyle(.segmented).fixedSize()
        }
    }
    private func stepField(_ title: String, _ v: Binding<Int>, _ range: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.system(size: 9, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.4)
            Stepper(value: v, in: range) { Text("\(v.wrappedValue)").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text).monospacedDigit() }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func dblStep(_ title: String, _ v: Binding<Double>, _ range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.system(size: 9, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.4)
            Stepper(value: v, in: range, step: step) { Text(TradeMath.num(v.wrappedValue)).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text).monospacedDigit() }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Zoom / pan
    private func zoom(out: Bool) {
        let total = candles.count
        guard total > 0 else { return }
        if winCount == 0 { winCount = total }
        let factor = out ? 1.4 : 0.7
        winCount = max(10, min(total, Int(Double(winCount) * factor)))
        winStart = max(0, min(winStart, total - winCount))
        if winCount >= total { winCount = 0; winStart = 0 }
    }
    private func pan(_ dir: Int) {
        let total = candles.count
        guard winCount > 0, winCount < total else { return }
        let step = max(1, winCount / 4)
        winStart = max(0, min(total - winCount, winStart + dir * step))
    }

    // MARK: Import sheet
    private var importSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Load price data for \(effectiveSymbol)").font(.system(size: 17, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
            Text("Paste OHLC CSV (date,open,high,low,close[,volume]) or import a file. This is YOUR data — nothing is downloaded.")
                .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $csvText).font(.system(size: 11, design: .monospaced)).foregroundColor(BLTheme.text)
                .scrollContentBackground(.hidden).padding(8).frame(height: 200)
                .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
            HStack {
                GhostButton(label: "Import file", icon: "doc.badge.plus") { importFile() }
                Spacer()
                GhostButton(label: "Cancel") { showImporter = false }
                GoldButton(label: "Load", icon: "checkmark") { loadBars(); if !baseBars.isEmpty { showImporter = false } }
            }
        }.padding(22).frame(width: 560).background(BLTheme.bg)
    }
    private func loadBars() {
        let parsed = BarCSV.parse(csvText)
        baseBars = parsed.bars; winStart = 0; winCount = 0; crosshair = nil
        renkoBrick = CandleTransform.suggestedBrickSize(baseBars)
        importNote = baseBars.isEmpty ? "No valid rows found." : "Loaded \(baseBars.count) bars" + (parsed.skipped > 0 ? " (\(parsed.skipped) skipped)" : "") + "."
    }
    private func importFile() {
        let p = NSOpenPanel(); p.allowedContentTypes = [UTType.commaSeparatedText, UTType.plainText]; p.allowsMultipleSelection = false
        p.begin { resp in
            if resp == .OK, let url = p.url, let s = try? String(contentsOf: url, encoding: .utf8) { csvText = s; loadBars() }
        }
    }
}

// A gentle pulsing ring that signals a genuinely-flowing live feed. When inactive it renders
// nothing (so a static dot stays static — no fake "live" animation when the feed is off).
struct LivePulse: ViewModifier {
    let active: Bool
    @State private var on = false
    func body(content: Content) -> some View {
        content.background(
            Group {
                if active {
                    Circle().stroke(BLTheme.green, lineWidth: 1.5)
                        .scaleEffect(on ? 2.4 : 1).opacity(on ? 0 : 0.7)
                        .onAppear { withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { on = true } }
                        .onDisappear { on = false }
                }
            }
        )
    }
}
