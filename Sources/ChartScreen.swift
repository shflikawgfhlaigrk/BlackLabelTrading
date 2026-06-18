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
    var sma = true
    var ema = false
    var bollinger = false
    var vwap = false
    var rsi = false
    var macd = false
    var atr = false
    var smaPeriod = 20
    var emaPeriod = 50
    var bbPeriod = 20
    var bbK = 2.0
    var vwapWindow = 20
    var rsiPeriod = 14
    var atrPeriod = 14
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

struct ChartScreen: View {
    @EnvironmentObject var drawings: DrawingStore
    @State private var symbol = ""
    @State private var baseBars: [Bar] = []
    @State private var csvText = ""
    @State private var importNote = ""
    @State private var style: CandleStyle = .candles
    @State private var timeframe: ChartTimeframe = .base
    @State private var ind = ChartScreen.loadIndicators()
    @State private var renkoBrick: Double = 0
    @State private var showImporter = false

    // Drawing state
    @State private var activeTool: DrawingKind? = nil
    @State private var dragStart: CGPoint? = nil
    @State private var dragCurrent: CGPoint? = nil
    @State private var showFib = false

    // Zoom/pan: a visible window [winStart, winStart+winCount) over the candle index space.
    @State private var winStart = 0
    @State private var winCount = 0     // 0 = show all
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
            if baseBars.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        toolbar
                        priceChartCard
                        if ind.rsi { rsiPane }
                        if ind.macd { macdPane }
                        if ind.atr { atrPane }
                        drawingsList
                    }.padding(20)
                }
            }
        }
    }

    // MARK: Header (title + symbol + load)
    private var header: some View {
        HStack(alignment: .top) {
            ScreenTitle(title: "Chart", subtitle: "Candlestick / Heikin-Ashi / Renko on YOUR imported bars — indicators, drawing tools, multi-timeframe. Nothing downloaded or invented.", icon: "chart.xyaxis.line")
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Symbol", text: $symbol)
                        .textFieldStyle(.plain).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                        .frame(width: 90).padding(.vertical, 8).padding(.horizontal, 11)
                        .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.stroke, lineWidth: 1))
                        .onChange(of: symbol) { _ in winStart = 0 }
                    GoldButton(label: "Load bars", icon: "square.and.arrow.down") { showImporter = true }
                }
                if !importNote.isEmpty {
                    Text(importNote).font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(baseBars.isEmpty ? BLTheme.red : BLTheme.green)
                }
            }
        }
        .padding(20)
        .sheet(isPresented: $showImporter) { importSheet.sheetCloseBar() }
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            EmptyState(icon: "chart.xyaxis.line", title: "Load your own price data",
                       hint: "Import an OHLC CSV (date,open,high,low,close[,volume]) for a symbol. The chart, indicators and drawings all run on your data — nothing is fetched or faked.")
            GoldButton(label: "Import OHLC CSV", icon: "square.and.arrow.down") { showImporter = true }
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

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
        let lo = vis.map(\.low).min() ?? 0
        let hi = vis.map(\.high).max() ?? 1
        let pad = (hi - lo) * 0.06
        let yDomain = (lo - pad)...(hi + pad)
        let xLo = vis.first?.index ?? 0
        let xHi = (vis.last?.index ?? 1) + 1
        // Indicator series aligned to the (full) candle index space, then filtered to visible.
        let closes = candles.map(\.close)
        let smaS = ind.sma ? Indicators.sma(closes, ind.smaPeriod) : []
        let emaS = ind.ema ? Indicators.ema(closes, ind.emaPeriod) : []
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
                        RuleMark(x: .value("i", c.index), yStart: .value("low", c.low), yEnd: .value("high", c.high))
                            .foregroundStyle(c.up ? BLTheme.green.opacity(0.9) : BLTheme.red.opacity(0.9)).lineStyle(StrokeStyle(lineWidth: 1.2))
                        // Body
                        RectangleMark(x: .value("i", c.index),
                                      yStart: .value("o", c.up ? c.open : c.close),
                                      yEnd: .value("c", c.up ? c.close : c.open),
                                      width: .ratio(0.62))
                            .foregroundStyle(c.up ? BLTheme.green : BLTheme.red).cornerRadius(1.5)
                    }
                }
                overlayMarks(smaS, color: BLTheme.gold, name: "SMA")
                overlayMarks(emaS, color: BLTheme.goldHi, name: "EMA")
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
            }
            .chartXScale(domain: Double(xLo)...Double(xHi))
            .chartYScale(domain: yDomain)
            .chartYAxis { AxisMarks(position: .trailing) { v in AxisGridLine().foregroundStyle(BLTheme.stroke.opacity(0.4))
                AxisValueLabel { if let d = v.as(Double.self) { Text(TradeMath.num(d)).font(.system(size: 9)).foregroundStyle(BLTheme.sub) } } } }
            .chartXAxis { AxisMarks { v in AxisGridLine().foregroundStyle(BLTheme.stroke.opacity(0.3))
                AxisValueLabel { if let i = v.as(Int.self), let c = candles.first(where: { $0.index == i }) {
                    Text(c.date.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 8)).foregroundStyle(BLTheme.sub) } } } }
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
        return "\(s) · \(style.rawValue) · \(timeframe.rawValue) · \(bars.count) bars"
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
