import SwiftUI
import Charts

// MARK: - Equity curve (real SwiftUI Charts view fed by the graded session ledger)
struct EquityCurveCard: View {
    let points: [EquityPoint]
    private var last: Double { points.last?.equity ?? 0 }
    private var peak: Double { EquityCurve.peak(points) }
    private var maxDD: Double { EquityCurve.maxDrawdown(points) }
    private var curveTint: Color { last > 0 ? BLTheme.green : (last < 0 ? BLTheme.red : BLTheme.gold) }
    // Pad the y-domain a touch so the line never hugs the frame edges.
    private var yDomain: ClosedRange<Double> {
        let lo = min(0, EquityCurve.trough(points)), hi = max(0, peak)
        let pad = max(1, (hi - lo) * 0.12)
        return (lo - pad)...(hi + pad)
    }

    var body: some View {
        Panel(title: "Equity curve", icon: "chart.xyaxis.line", accent: points.isEmpty ? BLTheme.gold : curveTint) {
            if points.isEmpty {
                EmptyState(icon: "chart.xyaxis.line", title: "No equity curve yet",
                           hint: "Grade committed signals Win or Loss and your cumulative session P&L plots here — real data only, no track record implied.")
            } else {
                HStack(spacing: 12) {
                    curveStat("Session P&L", (last >= 0 ? "+" : "") + TradeMath.money(last), curveTint)
                    curveStat("Peak", (peak >= 0 ? "+" : "") + TradeMath.money(peak), BLTheme.gold)
                    curveStat("Max drawdown", maxDD > 0 ? "-" + TradeMath.money(maxDD) : TradeMath.money(0), BLTheme.red)
                }
                Chart {
                    // Zero reference line.
                    RuleMark(y: .value("Flat", 0))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(BLTheme.sub.opacity(0.35))
                    ForEach(points) { p in
                        AreaMark(x: .value("Step", p.index), y: .value("Equity", p.equity))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(LinearGradient(colors: [curveTint.opacity(0.28), curveTint.opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Step", p.index), y: .value("Equity", p.equity))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round))
                            .foregroundStyle(curveTint)
                    }
                    if let lastPt = points.last {
                        PointMark(x: .value("Step", lastPt.index), y: .value("Equity", lastPt.equity))
                            .symbolSize(70)
                            .foregroundStyle(curveTint)
                    }
                }
                .chartYScale(domain: yDomain)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: min(points.count, 6))) { _ in
                        AxisGridLine().foregroundStyle(BLTheme.stroke.opacity(0.5))
                        AxisValueLabel().foregroundStyle(BLTheme.sub)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(BLTheme.stroke.opacity(0.5))
                        AxisValueLabel {
                            if let v = value.as(Double.self) { Text(TradeMath.money(v)).foregroundStyle(BLTheme.sub) }
                        }
                    }
                }
                .frame(height: 200)
                .padding(.top, 4)
                Text("\(points.count - 1) graded signal\(points.count - 1 == 1 ? "" : "s") · cumulative realized P&L on this Mac. Not a track record.")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
            }
        }
    }

    @ViewBuilder private func curveStat(_ l: String, _ v: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(l.uppercased()).font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.5)
            Text(v).font(.system(size: 16, weight: .heavy, design: .rounded)).foregroundColor(tint).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(11).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Signals (primary dashboard — user-driven / scenario scoring engine)
struct SignalsScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var wc: WealthChartsStore
    @State private var inp = SignalInputs()
    @State private var scenarioIdx = 0
    @State private var committed = false
    @State private var priceStr = "5000"
    @State private var atrStr = "12"
    @State private var pvStr = "50"
    @State private var showConnectWC = false

    private var result: SignalResult { SignalEngine.evaluate(inp) }
    private var gates: [GateCheck] { GateEngine.evaluate(inp, result) }
    private var tfVotes: [TimeframeVote] { ConsensusEngine.votes(inp) }
    private var tfAgree: Int { ConsensusEngine.agreeing(tfVotes, with: result.direction) }
    private var gatesOK: Bool { GateEngine.allPass(gates) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    ScreenTitle(title: "Signals", subtitle: "Scenario scoring — not a live broker feed. 12 modules · 13 risk gates · 2-of-8 multi-TF consensus · direction lock.", icon: "dot.radiowaves.left.and.right")
                    Spacer()
                    StatusPill(text: "Scenario", tint: BLTheme.blue)
                }

                // Reachable WealthCharts entry point from the main dashboard (also in Settings).
                wealthChartsBanner

                // Hero signal card + composite.
                signalCard

                // Multi-timeframe consensus strip + 13-gate risk checklist.
                HStack(alignment: .top, spacing: 16) {
                    Panel(title: "Multi-timeframe consensus", icon: "rectangle.3.group.fill") {
                        Text("Direction-lock requires \(ConsensusEngine.requiredAgree) of 8 timeframes to agree.")
                            .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        HStack(spacing: 6) {
                            ForEach(tfVotes) { v in tfChip(v) }
                        }
                        Stat(label: "Agreeing with \(result.direction.rawValue)", value: "\(tfAgree) / 8",
                             tint: tfAgree >= ConsensusEngine.requiredAgree ? BLTheme.green : BLTheme.red)
                    }.frame(maxWidth: .infinity)
                    Panel(title: "Risk gates", icon: "checklist", accent: gatesOK ? BLTheme.green : BLTheme.red) {
                        HStack {
                            Text(gatesOK ? "All gates passed — signal valid" : "Blocked by failed gate(s)")
                                .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(gatesOK ? BLTheme.green : BLTheme.red)
                            Spacer()
                            StatusPill(text: "\(GateEngine.passedCount(gates)) / 13", tint: gatesOK ? BLTheme.green : BLTheme.gold)
                        }
                        VStack(spacing: 6) { ForEach(gates) { gateRow($0) } }
                    }.frame(maxWidth: .infinity)
                }

                // Two-column: factor controls | factor breakdown.
                HStack(alignment: .top, spacing: 16) {
                    Panel(title: "Factor inputs", icon: "slider.horizontal.3") {
                        HStack(spacing: 10) {
                            Field(title: "Symbol", text: $inp.symbol, prompt: "ES")
                            Field(title: "Price", text: $priceStr, prompt: "5000")
                        }
                        HStack(spacing: 10) {
                            Field(title: "ATR", text: $atrStr, prompt: "12")
                            Field(title: "$/point", text: $pvStr, prompt: "50")
                        }
                        Divider().background(BLTheme.stroke).padding(.vertical, 2)
                        ForEach(SignalFactor.allCases) { f in
                            FactorSlider(label: f.rawValue, value: factorBinding(f))
                        }
                        HStack(spacing: 8) {
                            GhostButton(label: "Reset", icon: "arrow.counterclockwise") { resetFactors() }
                            GhostButton(label: "Next scenario", icon: "forward.fill", tint: BLTheme.gold) { stepScenario() }
                        }.padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 16) {
                        Panel(title: "Factor breakdown", icon: "list.bullet.indent") {
                            ForEach(SignalFactor.allCases) { f in factorRow(f) }
                            Divider().background(BLTheme.stroke).padding(.vertical, 2)
                            Stat(label: "Composite score", value: String(format: "%+.0f", result.score), big: true)
                        }
                        Panel(title: "Trade plan", icon: "scope") {
                            Stat(label: "Direction", value: result.direction.rawValue, tint: result.direction.tint)
                            Stat(label: "Entry", value: TradeMath.num(result.entry))
                            Stat(label: "Stop", value: TradeMath.num(result.stop), tint: BLTheme.red)
                            Stat(label: "Target", value: TradeMath.num(result.target), tint: BLTheme.green)
                            Stat(label: "Risk", value: "\(TradeMath.num(result.riskPoints)) pts · \(TradeMath.money(result.riskDollars))")
                            Stat(label: "Reward : Risk", value: "\(TradeMath.num(result.rr))R", big: true)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }

                // Honestly-graded session ledger (persisted): committed signals graded W/L + running P&L.
                Panel(title: "Session ledger", icon: "tray.full.fill") {
                    HStack(spacing: 10) {
                        Text("Honestly graded — you grade each committed signal Win or Loss.")
                            .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        Spacer()
                    }
                    HStack(spacing: 12) {
                        ledgerStat("W / L", "\(model.signalWins) / \(model.signalLosses)", BLTheme.text)
                        ledgerStat("Win rate", model.gradedSignals.isEmpty ? "—" : TradeMath.pct(model.signalWinRate), BLTheme.gold)
                        ledgerStat("Session P&L", (model.sessionPnL >= 0 ? "+" : "") + TradeMath.money(model.sessionPnL),
                                   model.sessionPnL >= 0 ? BLTheme.green : BLTheme.red)
                    }
                    Divider().background(BLTheme.stroke).padding(.vertical, 2)
                    if model.signals.isEmpty {
                        EmptyState(icon: "tray", title: "No committed signals", hint: "Commit a gate-passing signal above; grade it Win or Loss to build an honest session record on this Mac.")
                    } else {
                        ForEach(model.signals) { s in signalLogRow(s) }
                    }
                }

                // Real equity curve, plotted from the graded session ledger above.
                EquityCurveCard(points: model.equityCurve)
            }
            .padding(24)
        }
        .onAppear { syncFromInputs() }
        .onChange(of: priceStr) { _ in pushNumbers() }
        .onChange(of: atrStr) { _ in pushNumbers() }
        .onChange(of: pvStr) { _ in pushNumbers() }
        .sheet(isPresented: $showConnectWC) { ConnectWealthChartsSheet().environmentObject(wc) }
    }

    // Reachable WealthCharts connection banner — visible on the primary dashboard.
    private var wealthChartsBanner: some View {
        let connected = wc.account.isConfigured
        return HStack(spacing: 14) {
            Image(systemName: connected ? "checkmark.seal.fill" : "link.badge.plus")
                .font(.system(size: 16, weight: .bold)).foregroundColor(Color(hex: 0x1A1305))
                .frame(width: 38, height: 38)
                .background(connected ? AnyShapeStyle(LinearGradient(colors: [BLTheme.green, BLTheme.green.opacity(0.7)], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(BLTheme.goldGrad))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .shadow(color: (connected ? BLTheme.green : BLTheme.gold).opacity(0.35), radius: 7, y: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(connected ? "WealthCharts account connected" : "Connect your WealthCharts account")
                    .font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Text(connected
                     ? "\(wc.account.username) · saved on this Mac. Signals-only, manual execution — no live feed wired."
                     : "Add your WealthCharts account so it's on hand for the engine method. Saved on this Mac — signals-only, never auto-traded.")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            GoldButton(label: connected ? "Manage" : "Connect", icon: connected ? "pencil" : "link") { showConnectWC = true }
        }
        .padding(16)
        .holoCard(radius: 16)
    }

    // Hero card.
    private var signalCard: some View {
        let r = result
        return HStack(spacing: 22) {
            // Direction badge.
            VStack(spacing: 8) {
                Image(systemName: r.direction.icon).font(.system(size: 30, weight: .black))
                    .foregroundColor(Color(hex: 0x111111))
                    .frame(width: 78, height: 78)
                    .background(r.direction == .flat ? AnyShapeStyle(BLTheme.sub.opacity(0.5)) : AnyShapeStyle(LinearGradient(colors: [r.direction.tint, r.direction.tint.opacity(0.7)], startPoint: .top, endPoint: .bottom)))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: r.direction.tint.opacity(0.5), radius: 16, y: 4)
                Text(r.direction.rawValue).font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundColor(r.direction.tint).tracking(1)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(r.symbol).font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
                    StatusPill(text: "\(Int(r.confidence))% conf", tint: BLTheme.gold)
                }
                Text("Composite score \(String(format: "%+.0f", r.score)) / 100")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                // Score bar.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(BLTheme.bg2).frame(height: 10)
                        Capsule().fill(LinearGradient(colors: [r.direction.tint.opacity(0.7), r.direction.tint], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(8, geo.size.width * CGFloat(abs(r.score)/100)), height: 10)
                            .shadow(color: r.direction.tint.opacity(0.5), radius: 6)
                    }
                }.frame(height: 10)
                HStack(spacing: 18) {
                    plan("Entry", TradeMath.num(r.entry), BLTheme.text)
                    plan("Stop", TradeMath.num(r.stop), BLTheme.red)
                    plan("Target", TradeMath.num(r.target), BLTheme.green)
                    plan("R:R", "\(TradeMath.num(r.rr))R", BLTheme.gold)
                }.padding(.top, 4)
            }
            Spacer()
            VStack(spacing: 8) {
                GoldButton(label: committed ? "Committed" : (gatesOK ? "Commit signal" : "Gates blocking"), icon: committed ? "checkmark" : (gatesOK ? "tray.and.arrow.down" : "lock.fill")) {
                    guard gatesOK else { return }
                    let log = SignalLog(symbol: r.symbol, direction: r.direction.rawValue, score: r.score,
                                        entry: r.entry, stop: r.stop, target: r.target,
                                        riskDollars: r.riskDollars, rr: r.rr,
                                        gatesPassed: GateEngine.passedCount(gates), tfAgree: tfAgree)
                    model.commit(log)
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { committed = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { committed = false }
                }
                .opacity(gatesOK ? 1 : 0.55).disabled(!gatesOK)
                Text(gatesOK ? TradeMath.money(r.riskDollars) + " at risk" : "Pass all 13 gates to commit").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
            }
        }
        .padding(22)
        // Holographic hero surface + a direction-tinted glow on top (semantic long/short colour).
        .holoCard(radius: 22)
        .shadow(color: r.direction.tint.opacity(0.18), radius: 26, y: 10)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: r.direction)
    }

    @ViewBuilder private func plan(_ l: String, _ v: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(l.uppercased()).font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.5)
            Text(v).font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundColor(tint).monospacedDigit()
        }
    }

    @ViewBuilder private func factorRow(_ f: SignalFactor) -> some View {
        let c = SignalEngine.contribution(f, inp)
        HStack(spacing: 10) {
            Image(systemName: f.icon).font(.system(size: 11, weight: .bold)).foregroundColor(BLTheme.gold).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(f.rawValue).font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                Text("w \(String(format: "%.0f%%", f.weight*100)) · \(f.blurb)").font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1)
            }
            Spacer()
            Text(String(format: "%+.0f", c)).font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundColor(c > 0.5 ? BLTheme.green : (c < -0.5 ? BLTheme.red : BLTheme.sub))
        }
    }

    @ViewBuilder private func tfChip(_ v: TimeframeVote) -> some View {
        VStack(spacing: 3) {
            Image(systemName: v.direction.icon).font(.system(size: 10, weight: .black)).foregroundColor(v.direction.tint)
            Text(v.label).font(.system(size: 9, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 7)
        .background(v.direction.tint.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(v.direction.tint.opacity(0.4), lineWidth: 1))
    }

    @ViewBuilder private func gateRow(_ c: GateCheck) -> some View {
        HStack(spacing: 8) {
            Image(systemName: c.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 12, weight: .bold)).foregroundColor(c.passed ? BLTheme.green : BLTheme.red)
            Text(c.gate.rawValue).font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
            Spacer()
            Text(c.detail).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1)
        }
    }

    @ViewBuilder private func ledgerStat(_ l: String, _ v: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(l.uppercased()).font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.5)
            Text(v).font(.system(size: 17, weight: .heavy, design: .rounded)).foregroundColor(tint).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func signalLogRow(_ s: SignalLog) -> some View {
        HStack(spacing: 14) {
            Image(systemName: s.dir.icon).font(.system(size: 13, weight: .bold)).foregroundColor(Color(hex: 0x111111))
                .frame(width: 30, height: 30).background(s.dir.tint).clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(s.symbol).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                HStack(spacing: 8) {
                    StatusPill(text: s.direction, tint: s.dir.tint)
                    Text("\(TradeMath.num(s.rr))R · \(s.gatesPassed)/13 gates · \(s.tfAgree)/8 TF").font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                }
            }
            Spacer()
            // Honest grading: pending shows Win/Loss buttons; graded shows result + P&L.
            if s.grade == "pending" {
                HStack(spacing: 6) {
                    GhostButton(label: "Win", icon: "checkmark", tint: BLTheme.green) { model.grade(s, as: "win") }
                    GhostButton(label: "Loss", icon: "xmark", tint: BLTheme.red) { model.grade(s, as: "loss") }
                }
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    StatusPill(text: s.grade, tint: s.grade == "win" ? BLTheme.green : BLTheme.red)
                    Text((s.pnl >= 0 ? "+" : "") + TradeMath.money(s.pnl))
                        .font(.system(size: 14, weight: .heavy, design: .rounded)).foregroundColor(s.pnl >= 0 ? BLTheme.green : BLTheme.red).monospacedDigit()
                }
            }
        }
        .padding(14).background(BLTheme.panel2).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
        .contextMenu {
            if s.grade != "pending" { Button("Reset grade") { model.grade(s, as: "pending") } }
            Button("Delete", role: .destructive) { model.deleteSignal(s) }
        }
    }

    // Bindings & helpers.
    private func factorBinding(_ f: SignalFactor) -> Binding<Double> {
        Binding(get: { inp.factors[f.rawValue] ?? 0 },
                set: { inp.factors[f.rawValue] = $0 })
    }
    private func syncFromInputs() {
        priceStr = TradeMath.numTrim(inp.price); atrStr = TradeMath.numTrim(inp.atr); pvStr = TradeMath.numTrim(inp.pointValue)
    }
    private func pushNumbers() {
        inp.price = Double(priceStr) ?? inp.price
        inp.atr = Double(atrStr) ?? inp.atr
        inp.pointValue = Double(pvStr) ?? inp.pointValue
    }
    private func resetFactors() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            for f in SignalFactor.allCases { inp.factors[f.rawValue] = 0 }
        }
    }
    private func stepScenario() {
        scenarioIdx = (scenarioIdx + 1) % SignalEngine.scenarios.count
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { inp = SignalEngine.scenarios[scenarioIdx].inputs }
        syncFromInputs()
    }
}

// MARK: - Journal (full CRUD, persisted)
struct JournalScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: Trade?
    @State private var showImport = false
    @State private var query = ""
    @State private var resultFilter: TradeResult? = nil
    let cols = [GridItem(.adaptive(minimum: 220), spacing: 14)]

    // Global search/filter over the journal (symbol / tags / notes + result).
    private var filtered: [Trade] {
        model.trades.filter { t in
            (resultFilter == nil || t.result == resultFilter) &&
            (query.isEmpty || t.symbol.lowercased().contains(query.lowercased())
                || t.notes.lowercased().contains(query.lowercased())
                || t.allTags.contains { $0.contains(query.lowercased()) })
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                ScreenTitle(title: "Journal", subtitle: "Every trade, with live risk math. Import your broker CSV, tag setups, track MAE/MFE + hold time.", icon: "list.bullet.rectangle.fill")
                Spacer()
                GhostButton(label: "Import CSV", icon: "square.and.arrow.down") { showImport = true }
                GoldButton(label: "Log trade", icon: "plus") { editing = Trade() }
            }.padding(24)
            ScrollView {
                VStack(spacing: 16) {
                    LazyVGrid(columns: cols, spacing: 14) {
                        MetricCard(label: "Trades", value: "\(model.trades.count)", icon: "list.bullet.rectangle.fill")
                        MetricCard(label: "Win rate", value: model.closedTrades.isEmpty ? "—" : TradeMath.pct(model.winRate), icon: "target")
                        MetricCard(label: "Avg R", value: model.closedTrades.isEmpty ? "—" : "\(TradeMath.num(model.avgRMultiple))R", icon: "chart.line.uptrend.xyaxis")
                        MetricCard(label: "Total P&L", value: TradeMath.money(model.totalPnL), icon: "dollarsign.circle.fill",
                                   tint: model.totalPnL >= 0 ? BLTheme.green : BLTheme.red)
                    }
                    if model.trades.isEmpty {
                        EmptyState(icon: "chart.xyaxis.line", title: "No trades logged yet", hint: "Tap “Log trade” to record an entry, stop, and target — or “Import CSV” to bring in your broker export. The dashboard math updates live.")
                            .padding(.top, 30)
                    } else {
                        // Search + result filter (global).
                        HStack(spacing: 10) {
                            HStack(spacing: 7) {
                                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(BLTheme.sub)
                                TextField("Search symbol, tag, or note…", text: $query).textFieldStyle(.plain).font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.text)
                            }.padding(.vertical, 8).padding(.horizontal, 11).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.stroke, lineWidth: 1))
                            ForEach([Optional<TradeResult>.none, .some(.win), .some(.loss), .some(.open)], id: \.self) { rf in
                                Button { resultFilter = rf } label: {
                                    Text(rf.map { $0.label } ?? "All").font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                        .foregroundColor(resultFilter == rf ? Color(hex: 0x1A1305) : BLTheme.sub)
                                        .padding(.vertical, 6).padding(.horizontal, 12)
                                        .background(resultFilter == rf ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2)).clipShape(Capsule())
                                        .overlay(Capsule().stroke(BLTheme.stroke, lineWidth: 1))
                                }.buttonStyle(.plain)
                            }
                        }
                        if filtered.isEmpty {
                            EmptyState(icon: "magnifyingglass", title: "No trades match", hint: "Adjust your search or filter.").padding(.top, 20)
                        } else {
                            Text("\(filtered.count) of \(model.trades.count) trades").font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).frame(maxWidth: .infinity, alignment: .leading)
                            LazyVStack(spacing: 10) { ForEach(filtered) { t in tradeRow(t) } }
                        }
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 24)
            }
        }
        .sheet(item: $editing) { t in TradeEditor(trade: t).environmentObject(model) }
        .sheet(isPresented: $showImport) { JournalImportSheet().environmentObject(model) }
    }
    @ViewBuilder private func tradeRow(_ t: Trade) -> some View {
        TradeRowView(trade: t) { editing = t }
            .contextMenu { Button("Delete", role: .destructive) { model.delete(t) } }
    }
}

// Broker-CSV journal import: paste/import, auto-map columns, preview, then commit. Honest —
// only mappable rows import; the mapping + skipped count are shown so nothing is silently faked.
struct JournalImportSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var text = ""
    @State private var parsed: (rows: [ImportedTrade], skipped: Int, mapping: [String: Int])? = nil
    @State private var imported = 0
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Import broker CSV").font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
                Text("Paste your broker/platform trade export. We auto-detect columns (symbol, side, qty, entry/exit, P&L, times, MAE/MFE, tags). Only mappable rows import — nothing is invented.")
                    .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $text).font(.system(size: 11, design: .monospaced)).foregroundColor(BLTheme.text)
                    .scrollContentBackground(.hidden).padding(8).frame(height: 160)
                    .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                HStack {
                    GhostButton(label: "Import file", icon: "doc.badge.plus") { importFile() }
                    GoldButton(label: "Preview", icon: "eye") { parsed = BrokerCSV.parse(text); imported = 0 }
                    Spacer()
                }
                if let p = parsed {
                    if p.rows.isEmpty {
                        EmptyState(icon: "exclamationmark.triangle", title: "No mappable rows",
                                   hint: "Couldn't find a P&L column or an entry/exit pair. Make sure the first row is a header with recognizable column names.")
                    } else {
                        // Mapping summary.
                        Panel(title: "Detected columns", icon: "checkmark.seal.fill", accent: BLTheme.green) {
                            FlowTags(p.mapping.keys.sorted())
                            Text("\(p.rows.count) rows ready · \(p.skipped) skipped").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                        }
                        // Preview first 8.
                        Panel(title: "Preview", icon: "list.bullet", accent: BLTheme.gold) {
                            ForEach(Array(p.rows.prefix(8).enumerated()), id: \.offset) { (_, r) in
                                HStack(spacing: 10) {
                                    Text(r.symbol.isEmpty ? "—" : r.symbol).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text).frame(width: 60, alignment: .leading)
                                    StatusPill(text: r.isLong ? "Long" : "Short", tint: r.isLong ? BLTheme.green : BLTheme.red)
                                    if r.qty > 0 { Text("×\(TradeMath.numTrim(r.qty))").font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub) }
                                    Spacer()
                                    Text((r.pnl >= 0 ? "+" : "") + TradeMath.money2(r.pnl)).font(.system(size: 12.5, weight: .heavy, design: .rounded)).monospacedDigit().foregroundColor(r.pnl >= 0 ? BLTheme.green : BLTheme.red)
                                }.padding(.vertical, 6).padding(.horizontal, 11).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            if p.rows.count > 8 { Text("+ \(p.rows.count - 8) more").font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub) }
                        }
                    }
                }
                if imported > 0 {
                    Text("Imported \(imported) trades into your journal.").font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.green)
                }
                HStack { Spacer()
                    GhostButton(label: imported > 0 ? "Done" : "Cancel") { dismiss() }
                    if let p = parsed, !p.rows.isEmpty, imported == 0 {
                        GoldButton(label: "Import \(p.rows.count) trades", icon: "tray.and.arrow.down") {
                            imported = model.importTrades(p.rows)
                        }
                    }
                }
            }.padding(24).frame(width: 600)
        }.frame(width: 600, height: 640).background(BLTheme.bg)
    }
    private func importFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText, .plainText]; panel.allowsMultipleSelection = false
        panel.begin { resp in
            if resp == .OK, let url = panel.url, let s = try? String(contentsOf: url, encoding: .utf8) { text = s; parsed = BrokerCSV.parse(s); imported = 0 }
        }
    }
}

// Simple wrapping tag row for the detected-columns summary.
struct FlowTags: View {
    let items: [String]
    init(_ items: [String]) { self.items = items }
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { t in
                Text(t.uppercased()).font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.gold).tracking(0.4)
                    .padding(.vertical, 4).padding(.horizontal, 9).background(BLTheme.gold.opacity(0.14)).clipShape(Capsule())
                    .overlay(Capsule().stroke(BLTheme.gold.opacity(0.4), lineWidth: 1))
            }
        }
    }
}

struct TradeRowView: View {
    let trade: Trade; let tap: () -> Void
    @State private var hover = false
    var body: some View {
        let t = trade
        Button(action: tap) {
            HStack(spacing: 14) {
                Image(systemName: t.direction.icon).font(.system(size: 13, weight: .bold)).foregroundColor(Color(hex: 0x1A1305))
                    .frame(width: 30, height: 30).background(t.direction.tint).clipShape(RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.symbol.isEmpty ? "—" : t.symbol.uppercased()).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    HStack(spacing: 8) {
                        StatusPill(text: t.result.label, tint: t.result.tint)
                        Text("R:R \(TradeMath.num(t.rrRatio))").font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if t.result == .open {
                        Text("OPEN").font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.gold)
                        Text("risk \(TradeMath.money(t.riskDollars))").font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    } else {
                        Text((t.pnl >= 0 ? "+" : "") + TradeMath.money2(t.pnl))
                            .font(.system(size: 16, weight: .heavy, design: .rounded)).foregroundColor(t.pnl >= 0 ? BLTheme.green : BLTheme.red)
                        Text("\(TradeMath.num(t.rMultiple))R").font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    }
                }
            }
            .padding(16).background(hover ? BLTheme.panel2 : BLTheme.panel).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(hover ? BLTheme.gold.opacity(0.35) : BLTheme.stroke, lineWidth: 1))
            .shadow(color: Color.black.opacity(hover ? 0.3 : 0.15), radius: hover ? 10 : 5, y: 3)
            .scaleEffect(hover ? 1.008 : 1)
        }.buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

struct TradeEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State var trade: Trade
    @State private var entry = ""; @State private var stop = ""; @State private var target = ""
    @State private var size = ""; @State private var pnl = ""
    @State private var exit = ""; @State private var mae = ""; @State private var mfe = ""
    @State private var tagsText = ""; @State private var hasClose = false
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            Text(trade.symbol.isEmpty ? "Log trade" : "Edit trade").font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
            HStack(spacing: 12) {
                Field(title: "Symbol", text: $trade.symbol, prompt: "ES, NQ, CL…")
                VStack(alignment: .leading, spacing: 4) {
                    Text("DIRECTION").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.5)
                    Picker("", selection: $trade.direction) { ForEach(TradeDirection.allCases) { Text($0.label).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden()
                }
            }
            HStack(spacing: 12) {
                Field(title: "Entry", text: $entry, prompt: "5000")
                Field(title: "Stop", text: $stop, prompt: "4990")
                Field(title: "Target", text: $target, prompt: "5025")
                Field(title: "Size", text: $size, prompt: "2")
            }
            let c = computed()
            HStack(spacing: 20) {
                Stat(label: "Risk / unit", value: TradeMath.num(c.riskPerUnit))
                Stat(label: "Dollar risk", value: TradeMath.money(c.riskDollars))
                Stat(label: "R:R", value: TradeMath.num(c.rrRatio), big: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("RESULT").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.5)
                Picker("", selection: $trade.result) { ForEach(TradeResult.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
            }
            if trade.result != .open {
                HStack(spacing: 12) {
                    Field(title: "Realized P&L ($)", text: $pnl, prompt: trade.result == .loss ? "-200" : "450")
                    Field(title: "Exit price", text: $exit, prompt: "5012")
                }
                HStack(spacing: 12) {
                    Field(title: "MAE (R)", text: $mae, prompt: "0.6")
                    Field(title: "MFE (R)", text: $mfe, prompt: "2.4")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CLOSE TIME").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.5)
                        HStack {
                            Toggle("", isOn: $hasClose).labelsHidden().tint(BLTheme.gold)
                            if hasClose {
                                DatePicker("", selection: Binding(get: { trade.closed ?? Date() }, set: { trade.closed = $0 }), displayedComponents: [.date, .hourAndMinute])
                                    .labelsHidden().datePickerStyle(.compact)
                            } else { Text("open-ended").font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub) }
                        }
                    }
                }
            }
            Field(title: "Tags (comma-separated)", text: $tagsText, prompt: "breakout, fomo, a-setup")
            VStack(alignment: .leading, spacing: 4) {
                Text("NOTES").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                TextEditor(text: $trade.notes).font(.system(size: 13, design: .rounded)).foregroundColor(BLTheme.text)
                    .scrollContentBackground(.hidden).padding(8).frame(height: 60).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                Text("Tip: #hashtags in notes also count as tags in Analytics.").font(.system(size: 10, design: .rounded)).foregroundColor(BLTheme.sub)
            }
            HStack { Spacer()
                GhostButton(label: "Cancel") { dismiss() }
                GoldButton(label: "Save trade", icon: "checkmark") { var t = computed(); t.id = trade.id; model.upsert(t); dismiss() }
            }
        }
        .padding(24).frame(width: 540)
        }
        .frame(width: 540, height: 700).background(BLTheme.bg)
        .onAppear {
            entry = trade.entry > 0 ? trimmed(trade.entry) : ""
            stop = trade.stop > 0 ? trimmed(trade.stop) : ""
            target = trade.target > 0 ? trimmed(trade.target) : ""
            size = trade.size > 0 ? trimmed(trade.size) : ""
            pnl = trade.pnl != 0 ? trimmed(trade.pnl) : ""
            exit = trade.exit > 0 ? trimmed(trade.exit) : ""
            mae = trade.maeR > 0 ? trimmed(trade.maeR) : ""
            mfe = trade.mfeR > 0 ? trimmed(trade.mfeR) : ""
            tagsText = trade.tags.joined(separator: ", ")
            hasClose = trade.closed != nil
        }
    }
    private func trimmed(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
    private func computed() -> Trade {
        var t = trade
        t.entry = Double(entry) ?? 0; t.stop = Double(stop) ?? 0; t.target = Double(target) ?? 0
        t.size = Double(size) ?? 0
        t.pnl = t.result == .open ? 0 : (Double(pnl) ?? 0)
        t.exit = Double(exit) ?? 0
        t.maeR = Double(mae) ?? 0
        t.mfeR = Double(mfe) ?? 0
        t.closed = (t.result != .open && hasClose) ? (trade.closed ?? Date()) : nil
        t.tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        return t
    }
}

// MARK: - Calculators
struct CalculatorsScreen: View {
    @State private var account = "50000"; @State private var riskPct = "1"; @State private var psEntry = "5000"; @State private var psStop = "4990"
    @State private var rrEntry = "5000"; @State private var rrStop = "4990"; @State private var rrTarget = "5030"
    @State private var cStart = "10000"; @State private var cMonthly = "5"; @State private var cMonths = "12"
    let cols = [GridItem(.adaptive(minimum: 320), spacing: 16)]

    private var ps: (riskDollars: Double, perUnitRisk: Double, size: Double, notional: Double) {
        TradeMath.positionSize(account: Double(account) ?? 0, riskPct: Double(riskPct) ?? 0, entry: Double(psEntry) ?? 0, stop: Double(psStop) ?? 0)
    }
    private var rr: (risk: Double, reward: Double, ratio: Double) {
        TradeMath.riskReward(entry: Double(rrEntry) ?? 0, stop: Double(rrStop) ?? 0, target: Double(rrTarget) ?? 0)
    }
    private var compounded: [Double] {
        TradeMath.compound(start: Double(cStart) ?? 0, monthlyPct: Double(cMonthly) ?? 0, months: Int(cMonths) ?? 0)
    }

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            ScreenTitle(title: "Calculators", subtitle: "Position sizing, risk:reward, and compounding.", icon: "function")
            LazyVGrid(columns: cols, spacing: 16) {
                Panel(title: "Position Size", icon: "scalemass.fill") {
                    HStack(spacing: 10) { Field(title: "Account", text: $account); Field(title: "Risk %", text: $riskPct) }
                    HStack(spacing: 10) { Field(title: "Entry", text: $psEntry); Field(title: "Stop", text: $psStop) }
                    Stat(label: "Risk amount", value: TradeMath.money2(ps.riskDollars))
                    Stat(label: "Per-unit risk", value: TradeMath.num(ps.perUnitRisk))
                    Stat(label: "Position size", value: TradeMath.num(ps.size), big: true)
                    Stat(label: "Notional", value: TradeMath.money(ps.notional))
                }
                Panel(title: "Risk : Reward", icon: "arrow.left.arrow.right") {
                    HStack(spacing: 10) { Field(title: "Entry", text: $rrEntry); Field(title: "Stop", text: $rrStop); Field(title: "Target", text: $rrTarget) }
                    Stat(label: "Risk / unit", value: TradeMath.num(rr.risk))
                    Stat(label: "Reward / unit", value: TradeMath.num(rr.reward))
                    Stat(label: "R:R ratio", value: TradeMath.num(rr.ratio), big: true)
                    Stat(label: "1R move equals", value: "\(TradeMath.num(rr.risk)) pts")
                }
                Panel(title: "Compounding Projector", icon: "chart.line.uptrend.xyaxis") {
                    HStack(spacing: 10) { Field(title: "Start", text: $cStart); Field(title: "Monthly %", text: $cMonthly); Field(title: "Months", text: $cMonths) }
                    Stat(label: "Ending balance", value: TradeMath.money(compounded.last ?? (Double(cStart) ?? 0)), big: true)
                    Stat(label: "Total growth", value: {
                        let s = Double(cStart) ?? 0; let e = compounded.last ?? s
                        return s > 0 ? TradeMath.pct((e - s) / s * 100) : "—"
                    }())
                    if !compounded.isEmpty {
                        Divider().background(BLTheme.stroke)
                        ForEach(Array(milestones().enumerated()), id: \.offset) { _, row in
                            Stat(label: "Month \(row.0)", value: TradeMath.money(row.1))
                        }
                    }
                }
            }
        }.padding(24) }
    }
    private func milestones() -> [(Int, Double)] {
        let n = compounded.count
        guard n > 0 else { return [] }
        if n <= 4 { return compounded.enumerated().map { ($0.offset + 1, $0.element) } }
        let picks = [n/4, n/2, (3*n)/4, n].map { max(1, $0) }
        var seen = Set<Int>(); var out: [(Int, Double)] = []
        for m in picks where !seen.contains(m) { seen.insert(m); out.append((m, compounded[m-1])) }
        return out
    }
}

// MARK: - Firms (prop firm reference)
struct FirmsScreen: View {
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            ScreenTitle(title: "Prop Firms", subtitle: "Futures evaluation firms and their rules — confirm current terms on each firm's site.", icon: "building.columns.fill")
            ForEach(FirmData.all) { f in FirmRow(firm: f) }
        }.padding(24) }
    }
}

struct FirmRow: View {
    let firm: PropFirm
    @State private var hover = false
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "building.columns.fill").font(.system(size: 13, weight: .bold)).foregroundColor(Color(hex: 0x1A1305))
                .frame(width: 30, height: 30).background(BLTheme.goldGrad).clipShape(RoundedRectangle(cornerRadius: 9))
                .shadow(color: BLTheme.gold.opacity(0.3), radius: 5, y: 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(firm.name).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Text(firm.note).font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(hover ? BLTheme.panel2 : BLTheme.panel).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(hover ? BLTheme.gold.opacity(0.3) : BLTheme.stroke, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.18), radius: hover ? 10 : 5, y: 3)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

// MARK: - Settings (account management incl. deletion)
struct SettingsScreen: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var model: AppModel
    @State private var confirmDelete = false
    @State private var googleClientID = AppSettingsStore.googleClientID
    @State private var googleSaved = false
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            ScreenTitle(title: "Settings", subtitle: "Account, connections, and app info.", icon: "gearshape.fill")
            Panel(title: "Account", icon: "person.crop.circle") {
                Stat(label: "Signed in as", value: session.email.isEmpty ? "guest" : session.email)
                HStack {
                    GhostButton(label: "Sign out", icon: "rectangle.portrait.and.arrow.right") { withAnimation { session.signedIn = false } }
                    if session.email != "guest" && !session.email.isEmpty {
                        GhostButton(label: "Delete account", icon: "trash", tint: BLTheme.red) { confirmDelete = true }
                    }
                }
            }

            // Theme / Appearance Studio — the buyer owns the holographic look (live preview + presets).
            ThemeStudioPanel()

            // Headline ask: a real, reachable place to enter the WealthCharts account.
            WealthChartsPanel()

            // Make the Google sign-in option configurable rather than silently hidden.
            Panel(title: "Sign-in providers", icon: "globe") {
                Text("Both the Apple and Google buttons always appear on the login screen. Apple sign-in runs for real in the signed (provisioned) build; email/password and guest always work. To make the Google button do a real login, paste your own Google DESKTOP OAuth client ID below — it's stored on this Mac, never bundled. A Web client ID will NOT work for the app's loopback flow; create a \"Desktop\" client in the Google Cloud console.")
                    .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                Field(title: "Google Desktop Client ID", text: $googleClientID, prompt: "xxxx…apps.googleusercontent.com")
                HStack(spacing: 8) {
                    GoldButton(label: "Save", icon: "checkmark") {
                        AppSettingsStore.setGoogleClientID(googleClientID)
                        googleClientID = AppSettingsStore.googleClientID
                        withAnimation { googleSaved = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { googleSaved = false } }
                    }
                    if !googleClientID.isEmpty {
                        GhostButton(label: "Clear", icon: "xmark", tint: BLTheme.red) {
                            AppSettingsStore.setGoogleClientID(""); googleClientID = ""
                        }
                    }
                    if googleSaved {
                        Text("Saved — the Google button now does a real login (sign out to use it).")
                            .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.green)
                    }
                }
            }
            Panel(title: "Products & roadmap", icon: "shippingbox.fill") {
                productRow("Trading Engine", "$499/mo · Pro", "16-module stack, 13 risk gates, multi-TF consensus, direction lock, session vault.", BLTheme.gold, "Available")
                productRow("Signals", "$100/mo", "Engine-parity, direction-locked alerts — manual execution on your broker. Same modules & 13-gate validation.", BLTheme.gold, "Available")
                productRow("Marketing", "$1,475/mo", "Six-platform content pipeline. Channels will post from credentials you own.", BLTheme.sub, "Coming soon")
                productRow("Outbound", "$15 intro meet", "Lead gen and outreach — scoped intro before a monthly lane opens.", BLTheme.sub, "Intro")
                Text("This app is a scenario-scoring dashboard for the engine method — it scores factors you set, runs the 13 gates, and keeps an honestly-graded session ledger on this Mac. It is NOT a live broker feed and not a track record.")
                    .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
            Panel(title: "About", icon: "info.circle") {
                Text("Black Label Trading v1.0").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Text("A signal dashboard built on the Black Label engine method: a multi-module composite scoring engine, a 13-gate risk checklist, multi-timeframe consensus, a trade journal, risk calculators, and a prop-firm reference. Signals are user-driven scenarios, not a live broker feed. All data is stored privately on this Mac.")
                    .font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(24) }
        .alert("Delete your account?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { AccountStore.delete(session.email); withAnimation { session.signedIn = false; session.email = "" } }
        } message: { Text("This permanently removes your account credentials from this Mac. Your saved trades and signals remain in the app's local store.") }
    }
    @ViewBuilder private func productRow(_ name: String, _ price: String, _ desc: String, _ tint: Color, _ status: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(name).font(.system(size: 13.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    Text(price).font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
                }
                Text(desc).font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            StatusPill(text: status, tint: tint)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - WealthCharts connection panel (reusable — shown in Settings)
// HONEST FRAMING: stores the buyer's own WealthCharts account reference on THIS Mac only.
// Not a live broker feed; does not auto-trade or move money. Username + note → UserDefaults,
// password → macOS Keychain. The UI states plainly what is and isn't connected.
struct WealthChartsPanel: View {
    @EnvironmentObject var wc: WealthChartsStore
    @State private var showConnect = false

    var body: some View {
        Panel(title: "WealthCharts account", icon: "link", accent: wc.account.isConfigured ? BLTheme.green : BLTheme.gold) {
            HStack(spacing: 10) {
                Image(systemName: wc.account.isConfigured ? "checkmark.seal.fill" : "link.badge.plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(wc.account.isConfigured ? BLTheme.green : BLTheme.gold)
                VStack(alignment: .leading, spacing: 2) {
                    Text(wc.account.isConfigured ? "Account saved on this Mac" : "No WealthCharts account connected")
                        .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    Text(wc.account.isConfigured
                         ? "Stored locally — signals-only, manual execution. No live feed wired."
                         : "Add your WealthCharts account to keep it on hand for the engine method.")
                        .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                StatusPill(text: wc.account.isConfigured ? "Saved" : "Not connected",
                           tint: wc.account.isConfigured ? BLTheme.green : BLTheme.sub)
            }

            if wc.account.isConfigured {
                Divider().background(BLTheme.stroke).padding(.vertical, 2)
                Stat(label: "Username", value: wc.account.username)
                if !wc.account.note.isEmpty { Stat(label: "Label", value: wc.account.note) }
                Stat(label: "Password", value: wc.hasSecret ? "Saved in Keychain" : "Not saved")
                if let when = wc.account.connectedAt {
                    Stat(label: "Saved", value: when.formatted(date: .abbreviated, time: .shortened))
                }
            }

            HStack(spacing: 8) {
                GoldButton(label: wc.account.isConfigured ? "Update connection" : "Connect WealthCharts",
                           icon: wc.account.isConfigured ? "pencil" : "link") { showConnect = true }
                if wc.account.isConfigured {
                    GhostButton(label: "Disconnect", icon: "xmark.circle", tint: BLTheme.red) { wc.disconnect() }
                }
            }.padding(.top, 2)

            Text("Your WealthCharts details stay on this Mac (username & label saved locally, password saved in the macOS Keychain). This app is signals-only — it does not log in for you, auto-trade, move money, or stream a live broker feed. A real WealthCharts data feed is not wired in this build; this saves your account so it's ready for the engine method and manual execution on your own platform.")
                .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
        }
        .sheet(isPresented: $showConnect) { ConnectWealthChartsSheet().environmentObject(wc) }
    }
}

// Sheet to enter / update the WealthCharts account.
struct ConnectWealthChartsSheet: View {
    @EnvironmentObject var wc: WealthChartsStore
    @Environment(\.dismiss) var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var note = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "link").font(.system(size: 15, weight: .bold)).foregroundColor(Color(hex: 0x1A1305))
                        .frame(width: 30, height: 30).background(BLTheme.goldGrad).clipShape(RoundedRectangle(cornerRadius: 9))
                    Text("Connect WealthCharts").font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
                }
                Text("Saved on this Mac only. Signals-only — this does not auto-trade, move money, or stream a live broker feed. The password is stored in the macOS Keychain.")
                    .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)

                Field(title: "WealthCharts username / email", text: $username, prompt: "you@wealthcharts.com")
                VStack(alignment: .leading, spacing: 5) {
                    Text("PASSWORD (OPTIONAL)").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.6)
                    SecureField("••••••••", text: $password)
                        .textFieldStyle(.plain).font(.system(size: 14, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                        .padding(.vertical, 10).padding(.horizontal, 12)
                        .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                    Text("Stored in the macOS Keychain on this device. Leave blank to keep any previously saved password.")
                        .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
                }
                Field(title: "Label (optional)", text: $note, prompt: "e.g. Topstep 50K eval")

                HStack { Spacer()
                    GhostButton(label: "Cancel") { dismiss() }
                    GoldButton(label: "Save connection", icon: "checkmark") {
                        wc.save(username: username, password: password, note: note)
                        dismiss()
                    }
                }.padding(.top, 4)
            }
            .padding(24).frame(width: 460)
        }
        .frame(width: 460, height: 460).background(BLTheme.bg)
        .onAppear { username = wc.account.username; note = wc.account.note }
    }
}
