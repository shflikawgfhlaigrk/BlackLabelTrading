// Black Label Trading — Pass-3 screens: visual Strategy Builder, Pattern auto-detection,
// Paper-trade simulator, Trade Replay, and a multi-chart Grid. All operate on the user's OWN
// imported OHLC bars (the same CSV the backtester/chart eat) — honest framing throughout:
// nothing is downloaded, no prices/signals/results are fabricated, empty input -> empty state.
import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers

// MARK: - Shared form-field helpers (free functions so every Pass-3 screen reuses them).
@ViewBuilder func bltLabeledField<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 5) {
        Text(title.uppercased()).font(.system(size: 9.5, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.8)
        content()
    }
}
@ViewBuilder func bltIntField(_ title: String, _ v: Binding<Int>) -> some View {
    bltLabeledField(title) {
        TextField("", value: v, format: .number).textFieldStyle(.plain)
            .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
            .padding(8).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(BLTheme.stroke, lineWidth: 1))
    }
}
@ViewBuilder func bltDblField(_ title: String, _ v: Binding<Double>) -> some View {
    bltLabeledField(title) {
        TextField("", value: v, format: .number).textFieldStyle(.plain)
            .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
            .padding(8).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(BLTheme.stroke, lineWidth: 1))
    }
}
@ViewBuilder func bltTextField(_ title: String, _ v: Binding<String>, placeholder: String = "") -> some View {
    bltLabeledField(title) {
        TextField(placeholder, text: v).textFieldStyle(.plain)
            .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
            .padding(8).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(BLTheme.stroke, lineWidth: 1))
    }
}
@ViewBuilder func bltPicker<T: Hashable>(_ title: String, _ sel: Binding<T>, _ opts: [T], _ label: @escaping (T) -> String) -> some View {
    bltLabeledField(title) {
        Picker("", selection: sel) { ForEach(opts, id: \.self) { Text(label($0)).tag($0) } }
            .labelsHidden().pickerStyle(.menu).tint(BLTheme.gold)
            .font(.system(size: 12.5, design: .rounded))
    }
}
@ViewBuilder func bltMetricTile(_ l: String, _ v: String, _ tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(v).font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundColor(tint)
        Text(l.uppercased()).font(.system(size: 9, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.5)
    }
    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
    .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.stroke, lineWidth: 1))
}

// A "load your bars" panel reused by Pass-3 screens. Reports parsed bars via a binding.
struct BarLoaderPanel: View {
    @Binding var bars: [Bar]
    @State private var csvText = ""
    @State private var note = ""
    var onLoad: (() -> Void)? = nil
    var body: some View {
        Panel(title: "Your historical bars", icon: "square.and.arrow.down") {
            Text("Paste CSV (date,open,high,low,close[,volume]) or import a file. This is YOUR data — nothing is downloaded or invented.")
                .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $csvText).font(.system(size: 11, design: .monospaced)).foregroundColor(BLTheme.text)
                .scrollContentBackground(.hidden).padding(8).frame(height: 80)
                .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
            HStack(spacing: 8) {
                GhostButton(label: "Import CSV file", icon: "doc.badge.plus") { importFile() }
                GoldButton(label: "Load bars", icon: "checkmark") { load() }
                if !note.isEmpty {
                    Text(note).font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(bars.isEmpty ? BLTheme.red : BLTheme.green)
                }
            }
            if !bars.isEmpty, let f = bars.first, let l = bars.last {
                HStack(spacing: 12) {
                    Stat(label: "Bars", value: "\(bars.count)")
                    Stat(label: "Range", value: "\(f.date.formatted(date: .abbreviated, time: .omitted)) → \(l.date.formatted(date: .abbreviated, time: .omitted))")
                }
            }
        }
    }
    private func load() {
        let (parsed, skipped) = BarCSV.parse(csvText)
        bars = parsed
        note = parsed.isEmpty ? "No valid rows found." : "Loaded \(parsed.count) bars\(skipped > 0 ? " (\(skipped) skipped)" : "")."
        if !parsed.isEmpty { onLoad?() }
    }
    private func importFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText, .plainText]; panel.allowsMultipleSelection = false
        panel.begin { resp in
            if resp == .OK, let url = panel.url, let s = try? String(contentsOf: url, encoding: .utf8) { csvText = s; load() }
        }
    }
}

// A compact candle chart with optional pattern markers + entry markers. Reusable, pure render
// over the user's bars. Renders an honest empty state when there are no bars.
struct MiniCandleChart: View {
    let bars: [Bar]
    var entryIndices: Set<Int> = []
    var patternIndices: [Int: Int] = [:]   // index -> bias (+1/-1/0) for a marker tint
    var highlight: Int? = nil               // a single highlighted bar (replay cursor)
    var height: CGFloat = 220
    var body: some View {
        if bars.isEmpty {
            EmptyState(icon: "chart.xyaxis.line", title: "No bars", hint: "Load OHLC data to render the chart.")
                .frame(height: height)
        } else {
            let candles = CandleTransform.candles(bars)
            Chart {
                ForEach(candles) { c in
                    RectangleMark(x: .value("i", c.index), yStart: .value("l", c.low), yEnd: .value("h", c.high), width: 1.2)
                        .foregroundStyle((c.up ? BLTheme.green : BLTheme.red).opacity(0.55))
                    RectangleMark(x: .value("i", c.index), yStart: .value("o", min(c.open, c.close)), yEnd: .value("c", max(c.open, c.close)), width: 5)
                        .foregroundStyle(c.up ? BLTheme.green : BLTheme.red)
                    if let bias = patternIndices[c.index] {
                        PointMark(x: .value("i", c.index), y: .value("p", c.high))
                            .symbol(.triangle).symbolSize(70)
                            .foregroundStyle(bias > 0 ? BLTheme.green : (bias < 0 ? BLTheme.red : BLTheme.gold))
                    }
                    if entryIndices.contains(c.index) {
                        PointMark(x: .value("i", c.index), y: .value("e", c.low))
                            .symbol(.circle).symbolSize(60).foregroundStyle(BLTheme.gold)
                    }
                    if highlight == c.index {
                        RuleMark(x: .value("i", c.index)).foregroundStyle(BLTheme.gold.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3,3]))
                    }
                }
            }
            .frame(height: height)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { _ in AxisGridLine().foregroundStyle(BLTheme.stroke.opacity(0.3)) } }
            .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(BLTheme.stroke.opacity(0.3)); AxisValueLabel().foregroundStyle(BLTheme.sub) } }
        }
    }
}

// =====================================================================================
// MARK: - Strategy Builder screen
// Compose entry conditions + filters visually -> backtest on your bars -> save -> alertable.
// =====================================================================================
struct StrategyBuilderScreen: View {
    @EnvironmentObject var store: StrategyStore
    @EnvironmentObject var alerts: AlertStore
    @EnvironmentObject var nav: Nav
    @State private var bars: [Bar] = []
    @State private var strat = VisualStrategy(entry: [RuleCondition()])
    @State private var result: (trades: [BacktestTrade], stats: [TradeStat])? = nil
    @State private var alertSymbol = ""
    @State private var exportNote = ""

    private var report: PerfReport? { result.map { Analytics.report($0.stats) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenTitle(title: "Strategy Builder", subtitle: "Compose entry rules with no code, backtest them on YOUR bars, save, and turn mappable rules into alerts. Research — never a track record or advice.", icon: "wand.and.stars")

                BarLoaderPanel(bars: $bars) { result = nil }

                // Rule composition.
                Panel(title: "Entry rules", icon: "slider.horizontal.3", accent: BLTheme.blue) {
                    HStack(spacing: 10) {
                        bltPicker("Direction", $strat.direction, TradeDirection.allCases) { $0.label }
                        bltPicker("Combine", $strat.combine, AlertCombine.allCases) { $0 == .all ? "Match ALL" : "Match ANY" }
                        bltTextField("Strategy name", $strat.name)
                    }
                    ForEach($strat.entry) { $cond in conditionRow($cond) }
                    HStack {
                        GhostButton(label: "Add condition", icon: "plus") { strat.entry.append(RuleCondition()) }
                        if strat.entry.count > 1 {
                            GhostButton(label: "Remove last", icon: "minus", tint: BLTheme.red) { strat.entry.removeLast() }
                        }
                        Spacer()
                    }
                }

                // Exit + risk (reuses the honest trade-management model).
                Panel(title: "Exit & risk", icon: "shield.lefthalf.filled") {
                    HStack(spacing: 10) {
                        bltPicker("Exit", $strat.exit, ExitRule.allCases) { $0.rawValue }
                        bltIntField("ATR period", $strat.atrPeriod)
                        bltDblField("ATR stop ×", $strat.atrStopMult)
                        bltDblField("Target (R)", $strat.targetR)
                        bltIntField("Time stop", $strat.timeStopBars)
                    }
                    HStack(spacing: 10) {
                        bltDblField("$/point", $strat.pointValue)
                        bltDblField("Commission", $strat.commissionPerTrade)
                        bltDblField("Slippage/side", $strat.slippagePerSide)
                    }
                    HStack(spacing: 10) {
                        GoldButton(label: "Run backtest", fill: true, icon: "play.fill") {
                            result = VisualStrategyEngine.run(bars, strat)
                        }.disabled(bars.isEmpty || strat.entry.isEmpty).opacity(bars.isEmpty || strat.entry.isEmpty ? 0.5 : 1)
                        GhostButton(label: "Save strategy", icon: "tray.and.arrow.down") { store.add(strat); exportNote = "Saved “\(strat.name)”." }
                    }
                }

                // Results.
                if let rep = report, let res = result {
                    if res.trades.isEmpty {
                        Panel(title: "Results", icon: "chart.bar.xaxis") {
                            EmptyState(icon: "exclamationmark.magnifyingglass", title: "No trades triggered",
                                       hint: "These rules produced no entries on these bars. Adjust conditions, periods, or load more data.")
                        }
                    } else {
                        Panel(title: "Results", icon: "chart.bar.xaxis", accent: rep.netPnL >= 0 ? BLTheme.green : BLTheme.red) {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                                bltMetricTile("Trades", "\(rep.trades)", BLTheme.text)
                                bltMetricTile("Win rate", TradeMath.pct(rep.winRate), rep.winRate >= 50 ? BLTheme.green : BLTheme.gold)
                                bltMetricTile("Net P&L", TradeMath.money(rep.netPnL), rep.netPnL >= 0 ? BLTheme.green : BLTheme.red)
                                bltMetricTile("Expectancy", "\(TradeMath.num(rep.expectancyR))R", rep.expectancyR >= 0 ? BLTheme.green : BLTheme.red)
                                bltMetricTile("Profit factor", rep.profitFactor.isInfinite ? "∞" : TradeMath.num(rep.profitFactor), BLTheme.text)
                                bltMetricTile("Max DD", TradeMath.money(rep.maxDrawdown), BLTheme.red)
                                bltMetricTile("Avg win", TradeMath.money(rep.avgWin), BLTheme.green)
                                bltMetricTile("Avg loss", TradeMath.money(rep.avgLoss), BLTheme.red)
                            }
                            Text("Honest framing: this is a backtest on your own bars. Validate it out-of-sample (Backtest → Walk-forward) before trusting any edge — a single positive run is not a track record.")
                                .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                        }
                        BacktestEquityCard(stats: res.stats)
                        MiniCandleChart(bars: bars, entryIndices: Set(VisualStrategyEngine.entryBars(bars, strat)), height: 200)
                            .padding(16).holoCard(radius: 18, sweep: false)
                    }
                }

                // Make it alertable.
                Panel(title: "Turn into an alert", icon: "bell.badge", accent: BLTheme.gold) {
                    Text("Rules that map onto live-snapshot metrics (price / RSI vs a constant) can become an alert you’ll get notified on. Indicator-vs-indicator rules (e.g. SMA cross) stay backtest-only — we tell you which, never silently drop logic.")
                        .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        bltTextField("ES contract", $alertSymbol, placeholder: "ES or CM.ESU6")
                        GoldButton(label: "Create alert", icon: "bell.fill") { exportAlert() }
                            .disabled(alertSymbol.trimmingCharacters(in: .whitespaces).isEmpty)
                            .opacity(alertSymbol.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
                    }
                    if !exportNote.isEmpty {
                        Text(exportNote).font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
                    }
                }

                // Saved strategies.
                if !store.strategies.isEmpty {
                    Panel(title: "Saved strategies", icon: "tray.full.fill") {
                        ForEach(store.strategies) { s in
                            HStack(spacing: 10) {
                                Image(systemName: s.direction == .long ? "arrow.up.right" : "arrow.down.right")
                                    .foregroundColor(s.direction.tint).font(.system(size: 12, weight: .bold))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.name).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                                    Text(s.entry.map { $0.summary }.joined(separator: s.combine == .all ? "  AND  " : "  OR  "))
                                        .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1)
                                }
                                Spacer()
                                GhostButton(label: "Load", icon: "square.and.arrow.up") { strat = s; result = nil }
                                GhostButton(label: "Delete", icon: "trash", tint: BLTheme.red) { store.delete(s.id) }
                            }
                            .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }.padding(24)
        }
    }

    @ViewBuilder private func conditionRow(_ c: Binding<RuleCondition>) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                bltPicker("Indicator", c.left, RuleIndicator.allCases) { $0.rawValue }
                if c.wrappedValue.left.needsPeriod { bltIntField("Period", c.leftPeriod) }
                bltPicker("Condition", c.comparator, RuleComparator.allCases) { $0.rawValue }
                rightOperandEditor(c)
            }
            HStack { Text(c.wrappedValue.summary).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(BLTheme.gold); Spacer() }
        }
        .padding(12).background(BLTheme.bg2.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.stroke, lineWidth: 1))
    }

    @ViewBuilder private func rightOperandEditor(_ c: Binding<RuleCondition>) -> some View {
        // Toggle: compare against another indicator OR a constant value.
        let isConst = Binding<Bool>(
            get: { if case .constant = c.wrappedValue.right { return true } else { return false } },
            set: { c.wrappedValue.right = $0 ? .constant(0) : .indicator(.sma, period: 30) }
        )
        let indSel = Binding<RuleIndicator>(
            get: { if case .indicator(let i, _) = c.wrappedValue.right { return i } else { return .sma } },
            set: { new in if case .indicator(_, let p) = c.wrappedValue.right { c.wrappedValue.right = .indicator(new, period: p) } else { c.wrappedValue.right = .indicator(new, period: 30) } }
        )
        let indPeriod = Binding<Int>(
            get: { if case .indicator(_, let p) = c.wrappedValue.right { return p } else { return 30 } },
            set: { new in if case .indicator(let i, _) = c.wrappedValue.right { c.wrappedValue.right = .indicator(i, period: new) } }
        )
        let constVal = Binding<Double>(
            get: { if case .constant(let v) = c.wrappedValue.right { return v } else { return 0 } },
            set: { c.wrappedValue.right = .constant($0) }
        )
        bltLabeledField("vs") {
            Picker("", selection: isConst) { Text("Value").tag(true); Text("Indicator").tag(false) }
                .labelsHidden().pickerStyle(.segmented).controlSize(.small)
        }
        if isConst.wrappedValue { bltDblField("Value", constVal) }
        else {
            bltPicker("Right ind.", indSel, RuleIndicator.allCases) { $0.rawValue }
            if indSel.wrappedValue.needsPeriod { bltIntField("Period", indPeriod) }
        }
    }

    private func exportAlert() {
        let s = alertSymbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard TradingSymbolScope.isES(s) else {
            exportNote = "Alerts are ES-only. Use ES or a captured ES contract."
            return
        }
        let (alert, unmappable) = VisualStrategyEngine.toAlert(strat, symbol: s)
        if let a = alert {
            alerts.add(a)
            exportNote = "Alert created for \(s)." + (unmappable.isEmpty ? "" : " \(unmappable.count) rule(s) couldn’t be mapped and stay backtest-only.")
        } else {
            exportNote = "No rules in this strategy map to a live-snapshot alert (they’re indicator-vs-indicator). They stay backtest-only — that’s honest."
        }
    }
}

// =====================================================================================
// MARK: - Patterns screen (candlestick + chart-structure auto-detection)
// =====================================================================================
struct PatternsScreen: View {
    @State private var bars: [Bar] = []
    @State private var summary: PatternScanner.Summary? = nil
    @State private var biasFilter = 0   // 0 = all, 1 = bullish, -1 = bearish, 2 = neutral
    @State private var sensitivity: Double = 0.1   // doji body fraction

    private var filteredHits: [PatternHit] {
        guard let s = summary else { return [] }
        switch biasFilter {
        case 1: return s.hits.filter { $0.bias > 0 }
        case -1: return s.hits.filter { $0.bias < 0 }
        case 2: return s.hits.filter { $0.bias == 0 }
        default: return s.hits
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenTitle(title: "Pattern Detection", subtitle: "Auto-detect candlestick & chart-structure patterns on YOUR imported bars. A detected pattern is a geometric fact, not a forecast — confirm before acting.", icon: "waveform.path.ecg.rectangle.fill")

                BarLoaderPanel(bars: $bars) { runScan() }

                Panel(title: "Scan", icon: "scope") {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Doji sensitivity (body ≤ \(Int(sensitivity*100))% of range)").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                            Slider(value: $sensitivity, in: 0.02...0.3).tint(BLTheme.gold).frame(width: 240)
                        }
                        GoldButton(label: "Scan patterns", icon: "sparkle.magnifyingglass") { runScan() }
                            .disabled(bars.isEmpty).opacity(bars.isEmpty ? 0.5 : 1)
                        Spacer()
                    }
                }

                if let s = summary {
                    Panel(title: "Summary", icon: "chart.pie.fill") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                            bltMetricTile("Total hits", "\(s.hits.count)", BLTheme.text)
                            bltMetricTile("Bullish", "\(s.bullish)", BLTheme.green)
                            bltMetricTile("Bearish", "\(s.bearish)", BLTheme.red)
                            bltMetricTile("Neutral", "\(s.neutral)", BLTheme.gold)
                        }
                    }

                    let pIdx = Dictionary(filteredHits.map { ($0.index, $0.bias) }, uniquingKeysWith: { a, _ in a })
                    Panel(title: "Chart with markers", icon: "chart.xyaxis.line") {
                        MiniCandleChart(bars: bars, patternIndices: pIdx, height: 240)
                    }

                    if !s.levels.isEmpty {
                        Panel(title: "Support / resistance levels", icon: "ruler") {
                            ForEach(s.levels.prefix(8)) { lv in
                                HStack {
                                    StatusPill(text: lv.isSupport ? "support" : "resistance", tint: lv.isSupport ? BLTheme.green : BLTheme.red)
                                    Text(TradeMath.num(lv.price)).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundColor(BLTheme.text)
                                    Spacer()
                                    Text("\(lv.touches) touches").font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub)
                                }.padding(.vertical, 4)
                            }
                        }
                    }

                    Panel(title: "Detected patterns", icon: "list.bullet") {
                        Picker("", selection: $biasFilter) {
                            Text("All").tag(0); Text("Bullish").tag(1); Text("Bearish").tag(-1); Text("Neutral").tag(2)
                        }.pickerStyle(.segmented).labelsHidden()
                        if filteredHits.isEmpty {
                            EmptyState(icon: "magnifyingglass", title: "No patterns in this filter", hint: "Switch the filter or rescan with different sensitivity.")
                        } else {
                            ForEach(filteredHits.reversed().prefix(60)) { h in
                                HStack(spacing: 10) {
                                    Image(systemName: h.candle?.icon ?? "rectangle.on.rectangle")
                                        .foregroundColor(h.bias > 0 ? BLTheme.green : (h.bias < 0 ? BLTheme.red : BLTheme.gold)).font(.system(size: 13, weight: .bold))
                                    Text(h.label).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                                    Spacer()
                                    Text("bar \(h.index)").font(.system(size: 10.5, design: .monospaced)).foregroundColor(BLTheme.sub)
                                    Text(h.date.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
                                }.padding(.vertical, 3)
                            }
                        }
                    }
                } else if !bars.isEmpty {
                    Panel(title: "Ready", icon: "scope") {
                        EmptyState(icon: "sparkle.magnifyingglass", title: "Scan to detect patterns", hint: "Your bars are loaded — tap Scan patterns.")
                    }
                }
            }.padding(24)
        }
    }

    private func runScan() {
        guard !bars.isEmpty else { summary = nil; return }
        var p = CandleScan.Params(); p.dojiBodyFrac = sensitivity
        summary = PatternScanner.scan(bars, candleParams: p)
    }
}

// =====================================================================================
// MARK: - Paper-trade simulator screen
// =====================================================================================
struct PaperTradeScreen: View {
    @EnvironmentObject var book: PaperBook
    @State private var symbol = ""
    @State private var direction: TradeDirection = .long
    @State private var qty = 1.0
    @State private var entry = 0.0
    @State private var stop = 0.0
    @State private var target = 0.0
    @State private var pointValue = 1.0
    @State private var commission = 0.0
    @State private var note = ""
    @State private var marksText = ""   // optional "SYM=price, SYM=price" to mark open positions

    private var marks: [String: Double] {
        var out: [String: Double] = [:]
        for pair in marksText.split(separator: ",") {
            let kv = pair.split(separator: "="); if kv.count == 2, let v = Double(kv[1].trimmingCharacters(in: .whitespaces)) {
                out[kv[0].trimmingCharacters(in: .whitespaces).uppercased()] = v
            }
        }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenTitle(title: "Paper Trade", subtitle: "A PRACTICE blotter. Open/close simulated positions at prices you enter — honest P&L, clearly a simulation. Not a live feed, not execution, not real money.", icon: "doc.text.magnifyingglass")

                // Equity summary (simulation).
                Panel(title: "Simulated account", icon: "banknote", accent: BLTheme.gold) {
                    HStack(spacing: 10) {
                        bltDblField("Starting balance", $book.startingBalance)
                        bltTextField("Marks (ES=price, …)", $marksText, placeholder: "ES=4500")
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                        bltMetricTile("Equity (sim)", TradeMath.money(book.equity(marks: marks)), BLTheme.gold)
                        bltMetricTile("Realized", TradeMath.money(book.realizedPnL()), book.realizedPnL() >= 0 ? BLTheme.green : BLTheme.red)
                        bltMetricTile("Open", "\(book.open.count)", BLTheme.text)
                        bltMetricTile("Closed", "\(book.closed.count)", BLTheme.text)
                    }
                    Text("Equity = starting + realized + unrealized (only for open positions you supply a mark for). No mark ⇒ that position contributes nothing — never an invented price.")
                        .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                }

                // New simulated position.
                Panel(title: "Open a simulated position", icon: "plus.circle") {
                    HStack(spacing: 10) {
                        bltTextField("Symbol", $symbol, placeholder: "ES")
                        bltPicker("Direction", $direction, TradeDirection.allCases) { $0.label }
                        bltDblField("Qty", $qty)
                        bltDblField("Entry", $entry)
                    }
                    HStack(spacing: 10) {
                        bltDblField("Stop (optional)", $stop)
                        bltDblField("Target (optional)", $target)
                        bltDblField("$/point", $pointValue)
                        bltDblField("Commission", $commission)
                    }
                    bltTextField("Note", $note, placeholder: "setup / plan")
                    GoldButton(label: "Open position", fill: true, icon: "arrow.right.circle.fill") { openPosition() }
                        .disabled(symbol.trimmingCharacters(in: .whitespaces).isEmpty || entry == 0)
                        .opacity(symbol.trimmingCharacters(in: .whitespaces).isEmpty || entry == 0 ? 0.5 : 1)
                }

                // Open positions.
                Panel(title: "Open positions", icon: "circle.dotted") {
                    if book.open.isEmpty {
                        EmptyState(icon: "tray", title: "No open positions", hint: "Open a simulated position above to start practicing.")
                    } else {
                        ForEach(book.open) { p in openPositionRow(p) }
                    }
                }

                // Closed positions + honest stats.
                if !book.closed.isEmpty {
                    let stats = book.stats()
                    let rep = Analytics.report(stats)
                    Panel(title: "Closed — honest results", icon: "checkmark.seal.fill", accent: rep.netPnL >= 0 ? BLTheme.green : BLTheme.red) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                            bltMetricTile("Trades", "\(rep.trades)", BLTheme.text)
                            bltMetricTile("Win rate", TradeMath.pct(rep.winRate), rep.winRate >= 50 ? BLTheme.green : BLTheme.gold)
                            bltMetricTile("Net P&L", TradeMath.money(rep.netPnL), rep.netPnL >= 0 ? BLTheme.green : BLTheme.red)
                            bltMetricTile("Profit factor", rep.profitFactor.isInfinite ? "∞" : TradeMath.num(rep.profitFactor), BLTheme.text)
                        }
                    }
                    BacktestEquityCard(stats: stats)
                    Panel(title: "Trade history", icon: "list.bullet") {
                        ForEach(book.closed) { p in closedRow(p) }
                    }
                    HStack { Spacer(); GhostButton(label: "Reset blotter", icon: "trash", tint: BLTheme.red) { book.reset() } }
                }
            }.padding(24)
        }
    }

    @ViewBuilder private func openPositionRow(_ p: PaperPosition) -> some View {
        let mark = marks[p.symbol.uppercased()]
        let unreal = p.unrealizedDollars(mark: mark)
        HStack(spacing: 12) {
            Image(systemName: p.direction.icon).foregroundColor(p.direction.tint).font(.system(size: 13, weight: .bold))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(p.symbol.uppercased())  ·  \(TradeMath.num(p.quantity)) @ \(TradeMath.num(p.entryPrice))").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                if let s = p.stop { Text("stop \(TradeMath.num(s))\(p.target.map { "  ·  target \(TradeMath.num($0))" } ?? "")").font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub) }
            }
            Spacer()
            if let u = unreal {
                Text(TradeMath.money(u)).font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundColor(u >= 0 ? BLTheme.green : BLTheme.red)
            } else {
                Text("no mark").font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub)
            }
            CloseButton(p: p)
        }
        .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func closedRow(_ p: PaperPosition) -> some View {
        HStack(spacing: 12) {
            Image(systemName: p.direction.icon).foregroundColor(p.direction.tint).font(.system(size: 12, weight: .bold))
            Text("\(p.symbol.uppercased())").font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text).frame(width: 60, alignment: .leading)
            Text("\(TradeMath.num(p.entryPrice)) → \(TradeMath.num(p.exitPrice ?? 0))").font(.system(size: 11, design: .monospaced)).foregroundColor(BLTheme.sub)
            Spacer()
            if let r = p.realizedR() { Text("\(TradeMath.num(r))R").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub) }
            Text(TradeMath.money(p.realizedDollars() ?? 0)).font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundColor((p.realizedDollars() ?? 0) >= 0 ? BLTheme.green : BLTheme.red).frame(width: 90, alignment: .trailing)
        }.padding(.vertical, 3)
    }

    private func openPosition() {
        let p = PaperPosition(symbol: symbol.uppercased(), direction: direction, quantity: qty, entryPrice: entry,
                              stop: stop != 0 ? stop : nil, target: target != 0 ? target : nil,
                              pointValue: pointValue, commission: commission, note: note)
        book.openPosition(p)
        symbol = ""; entry = 0; stop = 0; target = 0; note = ""
    }

    // Small inline close control with a price prompt.
    struct CloseButton: View {
        @EnvironmentObject var book: PaperBook
        let p: PaperPosition
        @State private var show = false
        @State private var exitPx = 0.0
        var body: some View {
            GhostButton(label: "Close", icon: "xmark.circle") { exitPx = p.entryPrice; show = true }
                .popover(isPresented: $show) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Close \(p.symbol.uppercased())").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                        bltDblField("Exit price", $exitPx)
                        HStack {
                            GhostButton(label: "Delete", icon: "trash", tint: BLTheme.red) { book.delete(p.id); show = false }
                            Spacer()
                            GoldButton(label: "Close at price", icon: "checkmark") { book.close(p.id, at: exitPx); show = false }
                        }
                    }.padding(16).frame(width: 280).background(BLTheme.bg)
                }
        }
    }
}

// =====================================================================================
// MARK: - Trade Replay screen (step a session bar-by-bar)
// =====================================================================================
struct ReplayScreen: View {
    @EnvironmentObject var store: StrategyStore
    @State private var bars: [Bar] = []
    @State private var frames: [ReplayFrame] = []
    @State private var cursor = 0
    @State private var selectedStrategy: VisualStrategy? = nil
    @State private var playing = false
    private let tick = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenTitle(title: "Trade Replay", subtitle: "Step a session bar-by-bar with NO look-ahead. See the patterns and (optionally) strategy entries that were knowable at each bar — pure coaching over your own data.", icon: "play.rectangle.on.rectangle.fill")

                BarLoaderPanel(bars: $bars) { buildFrames() }

                if !store.strategies.isEmpty {
                    Panel(title: "Overlay a strategy (optional)", icon: "wand.and.stars") {
                        Picker("", selection: Binding(get: { selectedStrategy?.id }, set: { id in selectedStrategy = store.strategies.first { $0.id == id }; buildFrames() })) {
                            Text("None").tag(UUID?.none)
                            ForEach(store.strategies) { Text($0.name).tag(Optional($0.id)) }
                        }.labelsHidden().pickerStyle(.menu).tint(BLTheme.gold)
                    }
                }

                if frames.isEmpty {
                    Panel(title: "Replay", icon: "play.rectangle") {
                        EmptyState(icon: "play.rectangle.on.rectangle", title: "Load a session to replay", hint: "Import OHLC bars above to step through them bar-by-bar.")
                    }
                } else {
                    let f = frames[min(cursor, frames.count - 1)]
                    let visible = Array(bars.prefix(f.visibleBars))
                    let entrySet: Set<Int> = selectedStrategy != nil ? Set(frames.prefix(f.index + 1).filter { $0.entryHere }.map { $0.index }) : []
                    let patIdx = Dictionary(frames.prefix(f.index + 1).flatMap { fr in fr.newPatterns.map { ($0.index, $0.bias) } }, uniquingKeysWith: { a, _ in a })

                    Panel(title: "Session", icon: "chart.xyaxis.line") {
                        MiniCandleChart(bars: visible, entryIndices: entrySet, patternIndices: patIdx, highlight: f.index, height: 260)
                        // Transport controls.
                        HStack(spacing: 10) {
                            GhostButton(label: "", icon: "backward.end.fill") { cursor = 0; playing = false }
                            GhostButton(label: "", icon: "backward.fill") { cursor = max(0, cursor - 1); playing = false }
                            GoldButton(label: playing ? "Pause" : "Play", icon: playing ? "pause.fill" : "play.fill") { playing.toggle() }
                            GhostButton(label: "", icon: "forward.fill") { step() }
                            GhostButton(label: "", icon: "forward.end.fill") { cursor = frames.count - 1; playing = false }
                            Spacer()
                            Text("Bar \(f.index + 1) / \(frames.count)").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                        }
                        Slider(value: Binding(get: { Double(cursor) }, set: { cursor = Int($0); playing = false }), in: 0...Double(max(1, frames.count - 1))).tint(BLTheme.gold)
                    }

                    // Current-bar state.
                    Panel(title: "As of this bar", icon: "info.circle") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                            bltMetricTile("Close", TradeMath.num(f.bar.close), BLTheme.text)
                            bltMetricTile("From open", TradeMath.pct(f.changeFromOpenPct), f.changeFromOpenPct >= 0 ? BLTheme.green : BLTheme.red)
                            bltMetricTile("Session high", TradeMath.num(f.runningHigh), BLTheme.green)
                            bltMetricTile("Session low", TradeMath.num(f.runningLow), BLTheme.red)
                        }
                        if f.entryHere {
                            HStack { Image(systemName: "bolt.fill").foregroundColor(BLTheme.gold); Text("Strategy entry signal at this bar").font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.gold) }
                        }
                        if f.newPatterns.isEmpty {
                            Text("No new pattern completed at this bar.").font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub)
                        } else {
                            ForEach(f.newPatterns) { h in
                                HStack(spacing: 8) {
                                    Image(systemName: h.candle?.icon ?? "rectangle.on.rectangle").foregroundColor(h.bias > 0 ? BLTheme.green : (h.bias < 0 ? BLTheme.red : BLTheme.gold))
                                    Text(h.label).font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                                }
                            }
                        }
                    }

                    // Key moments jump-list.
                    let key = ReplaySession.keyMoments(frames)
                    if !key.isEmpty {
                        Panel(title: "Key moments", icon: "flag.fill") {
                            ForEach(key.prefix(40)) { km in
                                Button { cursor = km.index; playing = false } label: {
                                    HStack(spacing: 8) {
                                        Text("Bar \(km.index + 1)").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(BLTheme.gold).frame(width: 64, alignment: .leading)
                                        if km.entryHere { StatusPill(text: "entry", tint: BLTheme.gold) }
                                        Text(km.newPatterns.map { $0.label }.joined(separator: ", ")).font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.text).lineLimit(1)
                                        Spacer()
                                    }.padding(.vertical, 3).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }.padding(24)
        }
        .onReceive(tick) { _ in if playing { step() } }
    }

    private func buildFrames() {
        frames = ReplaySession.build(bars, strategy: selectedStrategy)
        cursor = 0; playing = false
    }
    private func step() {
        if cursor < frames.count - 1 { cursor += 1 } else { playing = false }
    }
}

// =====================================================================================
// MARK: - Multi-chart Grid screen
// =====================================================================================
struct GridScreen: View {
    // Each tile holds its own imported bars (the user's own data per tile).
    @State private var tiles: [GridTile] = [GridTile(), GridTile(), GridTile(), GridTile()]
    @State private var cols = 2

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenTitle(title: "Chart Grid", subtitle: "A grid of charts — load different symbols/timeframes side by side. Each tile renders YOUR own imported bars; empty tiles show an honest empty state.", icon: "square.grid.2x2.fill")

                Panel(title: "Layout", icon: "rectangle.grid.2x2") {
                    HStack(spacing: 12) {
                        bltLabeledField("Columns") {
                            Picker("", selection: $cols) { Text("1").tag(1); Text("2").tag(2); Text("3").tag(3) }.pickerStyle(.segmented).labelsHidden().frame(width: 160)
                        }
                        bltLabeledField("Tiles") {
                            HStack(spacing: 6) {
                                GhostButton(label: "Add", icon: "plus") { if tiles.count < 9 { tiles.append(GridTile()) } }
                                GhostButton(label: "Remove", icon: "minus", tint: BLTheme.red) { if tiles.count > 1 { tiles.removeLast() } }
                            }
                        }
                        Spacer()
                        Text("\(tiles.count) charts").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                    }
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: cols), spacing: 14) {
                    ForEach($tiles) { $tile in GridTileView(tile: $tile) }
                }
            }.padding(24)
        }
    }
}

struct GridTile: Identifiable {
    var id = UUID()
    var symbol = ""
    var bars: [Bar] = []
    var csv = ""
}

struct GridTileView: View {
    @Binding var tile: GridTile
    @State private var showImport = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Symbol", text: $tile.symbol).textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    .padding(6).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 7)).frame(width: 110)
                Spacer()
                if !tile.bars.isEmpty { Text("\(tile.bars.count) bars").font(.system(size: 10, design: .rounded)).foregroundColor(BLTheme.sub) }
                Button { importFile() } label: { Image(systemName: "doc.badge.plus").font(.system(size: 12, weight: .bold)).foregroundColor(BLTheme.gold) }.buttonStyle(.plain)
            }
            MiniCandleChart(bars: tile.bars, height: 170)
            if let last = tile.bars.last {
                HStack {
                    Text(TradeMath.num(last.close)).font(.system(size: 14, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
                    Spacer()
                    Text(last.date.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 10, design: .rounded)).foregroundColor(BLTheme.sub)
                }
            }
        }
        .padding(14).holoCard(radius: 16)
    }
    private func importFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText, .plainText]; panel.allowsMultipleSelection = false
        panel.begin { resp in
            if resp == .OK, let url = panel.url, let s = try? String(contentsOf: url, encoding: .utf8) {
                let (parsed, _) = BarCSV.parse(s); tile.bars = parsed; tile.csv = s
            }
        }
    }
}
