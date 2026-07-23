// Black Label Trading — the candlestick chart screen (the headline daily-driver surface).
// Renders the USER'S imported OHLC bars (same source as the backtester) as candles /
// Heikin-Ashi / Renko / line, with indicator overlays (MA/EMA/RSI/MACD/VWAP/Bollinger/ATR)
// and persisted drawing tools (trendline / level / zone / fib). Honest framing: the chart is
// empty until the user loads their own bars — nothing is downloaded, sampled, or invented.
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Which indicators are currently shown. Persists in UserDefaults so the layout sticks.
struct ChartIndicatorSet: Codable, Equatable {
    var sma = false
    var ema = true
    var engines = true       // overlay each engine's entry/stop/target on the chart (toggle)
    var bollinger = false
    var vwap = false
    var rsi = false
    var macd = false
    var atr = false
    var stochastic = false
    var stochPeriod = 14
    var stochD = 3
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
// Real minute timeframes (base capture bars are 15s, so 1m = 4 base bars) so the live chart
// opens on readable 1-minute candles instead of choppy 15-second micro-bars.
enum ChartTimeframe: String, CaseIterable, Identifiable, Codable {
    case m1 = "1m", m5 = "5m", m15 = "15m", m30 = "30m", h1 = "1h", d1 = "1D"
    var id: String { rawValue }
    // Fixed-count aggregation factor over the 15s base bars. Daily (.d1) is calendar-based, not a
    // fixed count, so it resamples via Resampler.daily instead (see `isDaily`).
    var factor: Int { switch self { case .m1: return 4; case .m5: return 20; case .m15: return 60; case .m30: return 120; case .h1: return 240; case .d1: return 240 } }
    var isDaily: Bool { self == .d1 }
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
                               close: l.close, volume: chunk.reduce(0) { $0 + $1.volume },
                               delta: chunk.reduce(0) { $0 + $1.delta }))
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
                       low: chunk.map(\.low).min() ?? f.low, close: l.close,
                       volume: chunk.reduce(0) { $0 + $1.volume },
                       delta: chunk.reduce(0) { $0 + $1.delta })
        }
    }
}

// Where the chart's bars come from. Live = the buyer's own webhook-pushed platform data (via
// the product's own backend); Import = a CSV the user pastes. Both are the user's OWN data -
// Live is never fabricated, it shows an honest "feed offline" state when capture isn't flowing.
enum ChartSource: String, CaseIterable, Identifiable {
    case live = "Live feed", importCSV = "Import"
    var id: String { rawValue }
    var icon: String { self == .live ? "dot.radiowaves.left.and.right" : "square.and.arrow.down" }
}

struct ChartScreen: View {
    @EnvironmentObject var drawings: DrawingStore
    @EnvironmentObject var feed: FeedClient
    @EnvironmentObject var nav: Nav
    @State private var source: ChartSource = .live
    @State private var symbol = ""
    @State private var baseBars: [Bar] = []
    @State private var csvText = ""
    @State private var importNote = ""
    @State private var style: CandleStyle = .candles
    @State private var timeframe: ChartTimeframe = .m1   // default 1-minute candles
    @State private var ind = ChartScreen.loadIndicators()
    @State private var renkoBrick: Double = 0
    @State private var showImporter = false

    // Live feed state
    @State private var liveTick: LiveTick? = nil
    @State private var activeFire: FireRow? = nil      // latest fire (any engine)
    @State private var engineFires: [FireRow] = []     // latest fire per engine — color-coded on chart
    @State private var feedNote = ""
    @State private var loadingFeed = false
    @State private var livePollTask: Task<Void, Never>? = nil
    @State private var lastLiveClose: Double? = nil

    // Drawing state — the active tool; placement happens inside the native chart canvas.
    @State private var activeTool: DrawingKind? = nil

    // Native chart controller (toolbar zoom/pan/fit/live → the live NSView). The visible window,
    // crosshair, drag-pan and pinch all live inside BLChartNSView now.
    @StateObject private var chartCtl = BLChartController()

    private static let indKey = "com.blacklabel.trading.chartIndicators"
    static func loadIndicators() -> ChartIndicatorSet {
        guard let d = UserDefaults.standard.data(forKey: indKey),
              let s = try? JSONDecoder().decode(ChartIndicatorSet.self, from: d) else { return ChartIndicatorSet() }
        return s
    }
    private func saveIndicators() {
        if let d = try? JSONEncoder().encode(ind) { UserDefaults.standard.set(d, forKey: Self.indKey) }
    }

    // Bars after timeframe resampling (every timeframe aggregates the 15s base bars). Daily aggregates
    // by calendar day; all others by a fixed count. Honest down-sampling of the buyer's OWN bars.
    private var bars: [Bar] {
        timeframe.isDaily ? Resampler.daily(baseBars) : Resampler.resample(baseBars, factor: timeframe.factor)
    }
    // Candles for the current style.
    private var candles: [Candle] {
        switch style {
        case .candles, .line: return CandleTransform.candles(bars)
        case .heikinAshi:     return CandleTransform.heikinAshi(bars)
        case .renko:          return CandleTransform.renko(bars, brickSize: renkoBrick > 0 ? renkoBrick : CandleTransform.suggestedBrickSize(bars))
        }
    }
    private var lineMode: Bool { style == .line }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(BLTheme.stroke)
            if source == .live { feedBanner }
            if baseBars.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    toolbar
                    chartCard
                    drawingsList
                }.padding(20)
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
            // Keep polling as long as we're on the LIVE chart — DON'T stop just because the feed
            // state momentarily flips (the API degrades/recovers every so often; the store keeps
            // ticking). Stopping on every flip is what froze the live chart. The poll itself gets
            // nil ticks when genuinely quiet, so leaving it running is safe and keeps updates live.
            if source == .live { startLivePoll() }
        }
        .onChange(of: timeframe) { _ in
            // The native chart re-anchors its own window to the new candle count and snaps to the
            // live edge on the next data push.
            chartCtl.jumpToLive()
        }
        .onDisappear { stopLivePoll() }
    }

    // MARK: Honest live-feed banner - every word reflects a REAL backend response. No "connected"
    // unless the buyer's own webhook data is genuinely reachable and flowing.
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
                GhostButton(label: "Connect", icon: "globe") { nav.section = .feeds }
                GhostButton(label: "Refresh webhook", icon: "arrow.clockwise") {
                    Task { loadingFeed = true; await refreshFeed(); loadingFeed = false }
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
        // The SEPARATE evaluator process produces signals; if it's down, bars keep landing but
        // signals silently stop. Say so honestly, regardless of feed state.
        if feed.capture.evaluatorDownWhileConnected {
            return "Data is flowing, but the signal engine is offline — signals are paused. Restart the app to resume."
        }
        let src = feed.capture.sourceLabel
        switch s {
        case .live: return "Ticks flowing from \(src) into your local store."
        case .idle: return "Feed reachable, no fresh ticks right now (market quiet / closed)."
        case .connecting: return "Webhook receiver ready - waiting for pushed ticks or bars."
        case .loggedOut: return "Waiting for browser feed data — sign into TopstepX or WealthCharts in the app-owned browser."
        case .notSignedIn: return "Backend reachable - connecting your local session..."
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
                            .onChange(of: symbol) { _ in chartCtl.jumpToLive() }
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

    // Live symbol picker: a menu of the buyer's own captured ES contracts + free-text entry.
    private var liveSymbolField: some View {
        HStack(spacing: 6) {
            TextField("ES", text: $symbol)
                .textFieldStyle(.plain).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                .frame(width: 110).padding(.vertical, 8).padding(.horizontal, 11)
                .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.stroke, lineWidth: 1))
                .onSubmit { Task { await loadLiveBars() } }
                .onChange(of: symbol) { _ in chartCtl.jumpToLive() }
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
                EmptyState(icon: "wifi.slash", title: "Your data service isn't running",
                           hint: "Black Label runs its own small data service inside the app, here on your Mac. Start it, then refresh — or switch to Import to chart a CSV file.")
                HStack(spacing: 8) {
                    GoldButton(label: "Start my backend", icon: "bolt.fill") {
                        Task { loadingFeed = true; await feed.ensureBackendRunning(); await reconnectFeed(); loadingFeed = false }
                    }
                    GhostButton(label: "Retry connection", icon: "arrow.clockwise") { Task { await reconnectFeed() } }
                }
            case .loggedOut, .notSignedIn, .connecting:
                EmptyState(icon: "dot.radiowaves.left.and.right", title: "Waiting for browser feed data",
                           hint: "One step: open your platform (TopstepX or WealthCharts) and sign in the way you always do. Black Label reads the live prices from your charts and shows them here. Nothing is ever made up.")
                HStack(spacing: 8) {
                    // The one action a stranded buyer needs, right here — same call as the Connect
                    // screen's primary button (backend picks the default platform when source is nil).
                    GoldButton(label: feed.connecting ? "Opening your platform…" : "Connect — open my platform", icon: "globe") {
                        Task { loadingFeed = true; await feed.launchCapture(); await refreshFeed(); loadingFeed = false }
                    }
                    GhostButton(label: "Connect screen", icon: "antenna.radiowaves.left.and.right") { nav.section = .feeds }
                    GhostButton(label: "Refresh", icon: "arrow.clockwise") {
                        Task { loadingFeed = true; await refreshFeed(); loadingFeed = false }
                    }
                }
            default:
                if feed.symbols.pickerList.isEmpty {
                    EmptyState(icon: "hourglass", title: "Feed connected — store is still filling",
                               hint: "\(feed.capture.sourceLabel.prefix(1).uppercased())\(feed.capture.sourceLabel.dropFirst()) is reachable but your local store has no bars yet. Keep your session open; bars accumulate here, and signals appear after enough bars build (several minutes) and only when a proven edge is present. Honest empty until real bars arrive.")
                } else {
                    EmptyState(icon: "chart.xyaxis.line", title: "Pick a contract to chart",
                               hint: "Your captured instruments are in the dropdown next to the symbol field. Choose one to load its real bars.")
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
        if source == .live { startLivePoll() }   // poll whenever on the live chart (resilient to API blips)
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
        let raw = await feed.recentBars(symbol: s, limit: 400)
        // Show only the recent contiguous session — drop stale cross-day bars (left from when
        // capture was intermittent) so the chart isn't squished by an old price level + a giant
        // overnight-gap candle. Keep everything within ~4h of the newest bar.
        let cutoff = (raw.last?.date ?? Date()).addingTimeInterval(-4 * 3600)
        let bars = raw.filter { $0.date >= cutoff }
        baseBars = bars; liveTick = nil; lastLiveClose = nil
        renkoBrick = CandleTransform.suggestedBrickSize(baseBars)
        if bars.isEmpty {
            feedNote = feed.state.hasData ? "No bars captured for \(s) yet." : "Feed offline — no bars to show."
        } else {
            feedNote = "Loaded \(bars.count) live bars for \(s)."
        }
        // Pull the engine signals on load so entry/stop/target show on the chart even in a quiet
        // market (not only while the live poll is running). One latest fire per engine.
        let fires = await feed.recentFires(limit: 60).filter { $0.symbol == s || $0.symbol == nil }
        engineFires = fires
        activeFire = fires.first
        if source == .live { startLivePoll() }   // poll whenever on the live chart (resilient to API blips)
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
                        let fires = await feed.recentFires(limit: 60).filter { $0.symbol == s || $0.symbol == nil }
                        engineFires = fires
                        activeFire = fires.first
                    }
                    // Every ~30s re-pull recent bars so newly-printed candles appear, and refresh
                    // the honest feed status banner.
                    if sinceRepull >= 75 {
                        sinceRepull = 0
                        await feed.refreshStatus()
                        let rawFresh = await feed.recentBars(symbol: s, limit: 400)
                        let cut = (rawFresh.last?.date ?? Date()).addingTimeInterval(-4 * 3600)
                        let fresh = rawFresh.filter { $0.date >= cut }
                        if !fresh.isEmpty {
                            var merged = fresh
                            if let t = liveTick { merged = LiveFold.apply(t, to: merged) }
                            baseBars = merged
                            // The native chart stays glued to the live edge automatically when the
                            // user hasn't scrolled back in time.
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
                // Zoom / pan controls — drive the native chart canvas.
                HStack(spacing: 6) {
                    iconBtn("minus.magnifyingglass") { chartCtl.zoomOut() }
                    iconBtn("plus.magnifyingglass") { chartCtl.zoomIn() }
                    iconBtn("arrow.left") { chartCtl.panLeft() }
                    iconBtn("arrow.right") { chartCtl.panRight() }
                    iconBtn("arrow.up.left.and.arrow.down.right") { chartCtl.fitAll() }       // fit-all
                    iconBtn("forward.end.alt.fill") { chartCtl.jumpToLive() }                 // jump to live edge
                }
            }
            // Indicator toggles
            HStack(spacing: 8) {
                indToggle("Engines", $ind.engines, BLTheme.green)
                indToggle("SMA \(ind.smaPeriod)", $ind.sma, BLTheme.gold)
                indToggle("EMA \(ind.emaPeriod)", $ind.ema, BLTheme.goldHi)
                indToggle("Bollinger", $ind.bollinger, BLTheme.blue)
                indToggle("VWAP", $ind.vwap, BLTheme.green)
                indToggle("RSI", $ind.rsi, BLTheme.blue)
                indToggle("MACD", $ind.macd, BLTheme.goldDim)
                indToggle("ATR", $ind.atr, BLTheme.red)
                indToggle("Stochastic", $ind.stochastic, BLTheme.blue)
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
                stepField("Stoch period", $ind.stochPeriod, 2...100)
                Spacer()
            }
        }
        .padding(12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
    }

    // MARK: Price chart card — the native interactive canvas (BLChartView). Hosts the SAME
    // CoreGraphics renderer the headless proof uses, with TradingView-grade scroll-zoom / drag-pan /
    // pinch / crosshair. Fills the available height like a real terminal chart.
    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            chartHeaderBar
            BLChartView(candles: candles, indicators: renderIndicators, lineMode: lineMode,
                        drawings: drawings.drawings(for: effectiveSymbol), symbol: effectiveSymbol,
                        showVolume: true, activeTool: activeTool, controller: chartCtl,
                        onCommitDrawing: { d in drawings.add(d, to: effectiveSymbol); activeTool = nil })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.stroke, lineWidth: 1))
            chartHint
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Compact header strip above the canvas: symbol, style/timeframe, live pill, last-bar OHLC.
    private var chartHeaderBar: some View {
        HStack(spacing: 14) {
            Text(effectiveSymbol).font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
            Text("\(style.rawValue) · \(timeframe.rawValue) · \(bars.count) bars")
                .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
            if source == .live && feed.state.isFlowing {
                HStack(spacing: 4) {
                    Circle().fill(BLTheme.green).frame(width: 6, height: 6).modifier(LivePulse(active: true))
                    Text("LIVE").font(.system(size: 9, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.green)
                }
            }
            Spacer()
            lastBarReadout
        }
    }
    @ViewBuilder private var lastBarReadout: some View {
        if let c = candles.last {
            HStack(spacing: 12) {
                ohlc("O", c.open); ohlc("H", c.high); ohlc("L", c.low); ohlc("C", c.close)
                if c.volume > 0 { ohlc("V", c.volume) }
            }
        }
    }
    private var chartHint: some View {
        Text("Scroll to zoom · drag to pan · pinch · double-click → live edge · ←/→ pan · +/− zoom · F fit. Drawings persist per symbol.")
            .font(.system(size: 9.5, design: .rounded)).foregroundColor(BLTheme.sub)
    }
    @ViewBuilder private func ohlc(_ l: String, _ v: Double) -> some View {
        HStack(spacing: 3) {
            Text(l).font(.system(size: 9.5, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.sub)
            Text(TradeMath.num(v)).font(.system(size: 11.5, weight: .semibold, design: .rounded)).monospacedDigit().foregroundColor(BLTheme.text)
        }
    }

    // Build the renderer's overlay config from the SwiftUI indicator toggles + live overlays.
    private var renderIndicators: RenderIndicators {
        var r = RenderIndicators()
        if ind.sma { r.sma = ind.smaPeriod }
        if ind.ema { r.ema1 = ind.emaPeriod; r.ema2 = ind.ema2Period }
        if ind.vwap { r.vwapWindow = ind.vwapWindow }
        if ind.bollinger { r.bollinger = (period: ind.bbPeriod, k: ind.bbK) }
        if ind.rsi { r.rsiPeriod = ind.rsiPeriod }
        if ind.macd { r.macd = true }
        if ind.atr { r.atrPeriod = ind.atrPeriod }
        if ind.stochastic { r.stochastic = (period: ind.stochPeriod, d: ind.stochD) }
        r.logScale = ind.logScale
        r.lastPriceLine = livePriceLine
        if ind.engines {
            r.fires = enginesToPlot.map { f in
                let active = f.engine == activeFire?.engine
                return RenderFire(direction: f.direction, engine: EngineRoster.label(for: f.engine), entry: f.entry,
                                  stop: active ? activeFire?.stop : nil, target: active ? activeFire?.target : nil,
                                  outcome: f.outcome)
            }
        }
        return r
    }

    // The live last-price line: shown only on a flowing live feed with a real tick. nil otherwise
    // (import mode, offline feed, or no tick) — so the chart never draws a fabricated price.
    private var livePriceLine: Double? {
        guard source == .live, style != .renko else { return nil }
        if let t = liveTick { return t.price }       // freshest tick while flowing
        if let c = lastLiveClose { return c }
        return bars.last?.close                       // always show the latest reading, even quiet
    }

    // Latest fire PER ENGINE (engineFires is newest-first) — one entry line per engine on the chart.
    private var enginesToPlot: [FireRow] {
        var seen = Set<String>(); var out: [FireRow] = []
        for f in engineFires where !seen.contains(f.engine) { seen.insert(f.engine); out.append(f) }
        return out
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
        baseBars = parsed.bars
        renkoBrick = CandleTransform.suggestedBrickSize(baseBars)
        chartCtl.jumpToLive()
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
    @Environment(\.blMotion) private var motion   // pause the pulse when app is backgrounded
    func body(content: Content) -> some View {
        content.background(
            Group {
                if active && motion {
                    // Expanding ring driven by a pausable TimelineView — wall-clock sawtooth with an
                    // ease-out, replacing the uncancelable repeatForever loop (20fps is smooth here).
                    TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !(active && motion))) { tl in
                        let p = FXClock.loop(tl.date, 1.6)
                        let e = 1 - pow(1 - p, 2)   // easeOut, matching the old curve's feel
                        Circle().stroke(BLTheme.green, lineWidth: 1.5)
                            .scaleEffect(1 + 1.4 * e).opacity(0.7 * (1 - e))
                    }
                }
            }
        )
    }
}
