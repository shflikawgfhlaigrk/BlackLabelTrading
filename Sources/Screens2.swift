// Black Label Trading — UI for the markets/research feature set:
// Watchlists · Screener · Alerts · Backtest · Analytics, plus the ⌘K command palette and
// the macOS notification bridge. Built on the existing Theme.swift components. Honest framing
// throughout: every number traces to the user's own entered/imported data — no live feed,
// no fabricated values. Empty states teach instead of faking content.
import SwiftUI
import Charts
import UserNotifications
import UniformTypeIdentifiers
import AppKit

// MARK: - macOS notification bridge for alerts
enum NotificationCenterBridge {
    static func configure(_ store: AlertStore) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        store.onFire = { alert, sym in
            let content = UNMutableNotificationContent()
            content.title = "Black Label alert · \(alert.symbol.uppercased())"
            content.body = alert.summary
            content.sound = .default
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(req)
        }
    }
}

// MARK: - Command palette (⌘K)
struct CommandPalette: View {
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var watch: WatchlistStore
    @State private var query = ""
    @FocusState private var focused: Bool

    private var sectionHits: [Section] {
        if query.isEmpty { return Section.allCases }
        return Section.allCases.filter { $0.rawValue.lowercased().contains(query.lowercased()) }
    }
    private var symbolHits: [WatchSymbol] {
        guard !query.isEmpty else { return [] }
        return watch.allSymbols.filter { $0.symbol.lowercased().contains(query.lowercased()) }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.55).ignoresSafeArea().onTapGesture { nav.showPalette = false }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .bold)).foregroundColor(BLTheme.gold)
                    TextField("Jump to a screen or symbol…", text: $query)
                        .textFieldStyle(.plain).font(.system(size: 16, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                        .focused($focused)
                        .onSubmit { if let first = sectionHits.first { go(first) } }
                    Text("ESC").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                        .padding(.horizontal, 6).padding(.vertical, 3).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 5))
                }.padding(16)
                Divider().background(BLTheme.stroke)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if !sectionHits.isEmpty {
                            paletteHeader("Screens")
                            ForEach(sectionHits) { s in
                                paletteRow(icon: s.icon, title: s.rawValue, sub: s.group) { go(s) }
                            }
                        }
                        if !symbolHits.isEmpty {
                            paletteHeader("Symbols")
                            ForEach(symbolHits) { sym in
                                paletteRow(icon: "chart.line.uptrend.xyaxis", title: sym.display,
                                           sub: sym.note.isEmpty ? "Open Watchlists" : sym.note) { go(.watchlists) }
                            }
                        }
                        if sectionHits.isEmpty && symbolHits.isEmpty {
                            Text("No matches for “\(query)”").font(.system(size: 13, design: .rounded))
                                .foregroundColor(BLTheme.sub).padding(20).frame(maxWidth: .infinity)
                        }
                    }.padding(8)
                }.frame(maxHeight: 340)
            }
            .frame(width: 560)
            .holoCard(radius: 18, sweep: false)
            .shadow(color: .black.opacity(0.5), radius: 40, y: 18)
            .padding(.top, 110)
        }
        .onAppear { focused = true }
    }
    private func go(_ s: Section) { nav.section = s; nav.showPalette = false; query = "" }
    @ViewBuilder private func paletteHeader(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 9.5, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.sub)
            .tracking(1).padding(.horizontal, 10).padding(.top, 8)
    }
    @ViewBuilder private func paletteRow(icon: String, title: String, sub: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 11) {
                Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundColor(BLTheme.gold).frame(width: 22)
                Text(title).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                Spacer()
                Text(sub).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
            }
            .padding(.vertical, 9).padding(.horizontal, 10).contentShape(Rectangle())
        }.buttonStyle(PaletteRowStyle())
    }
}
struct PaletteRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? BLTheme.gold.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

// MARK: - Shared: optional-number field that distinguishes "unknown" (nil) from 0.
struct OptNumberField: View {
    let title: String
    @Binding var value: Double?
    var prompt = "—"
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.6)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain).font(.system(size: 14, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                .padding(.vertical, 9).padding(.horizontal, 11)
                .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.stroke, lineWidth: 1))
                .onAppear { text = value.map { TradeMath.numTrim($0) } ?? "" }
                .onChange(of: text) { t in
                    let trimmed = t.trimmingCharacters(in: .whitespaces)
                    value = trimmed.isEmpty ? nil : Double(trimmed)
                }
        }
    }
}

// MARK: - Watchlists screen
struct WatchlistsScreen: View {
    @EnvironmentObject var watch: WatchlistStore
    @State private var newSymbol = ""
    @State private var newListName = ""
    @State private var showNewList = false
    @State private var editing: WatchSymbol?

    private var list: Watchlist? { watch.selected }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                ScreenTitle(title: "Watchlists", subtitle: "Track your symbols and the snapshot metrics you enter. No live feed — your data, on this Mac.", icon: "star.fill")
                Spacer()
                GoldButton(label: "New list", icon: "plus") { showNewList = true }
            }.padding(24)

            if watch.lists.isEmpty {
                EmptyState(icon: "star", title: "No watchlists yet",
                           hint: "Create a list, then add the instruments you trade. Enter each symbol's latest snapshot (price, % change, RSI, relative volume) and the Screener and Alerts run on exactly those values.")
                    .padding(.top, 24)
                Spacer()
            } else {
                // List selector chips.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(watch.lists) { l in listChip(l) }
                    }.padding(.horizontal, 24)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let list = list {
                            // Add-symbol row.
                            HStack(spacing: 10) {
                                Field(title: "Add symbol", text: $newSymbol, prompt: "e.g. ES, NQ, CL, EURUSD")
                                GoldButton(label: "Add", icon: "plus") {
                                    let s = newSymbol.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard TradingSymbolScope.inScope(s) else { return }
                                    watch.addSymbol(s, to: list.id); newSymbol = ""
                                }.padding(.top, 18)
                            }
                            if list.symbols.isEmpty {
                                EmptyState(icon: "plus.magnifyingglass", title: "No symbols in “\(list.name)”",
                                           hint: "Add a symbol above, then tap it to enter its latest snapshot — those values power the Screener and Alerts.")
                            } else {
                                // Header row.
                                watchHeader
                                ForEach(list.symbols) { s in symbolRow(s, in: list) }
                            }
                        }
                    }.padding(.horizontal, 24).padding(.bottom, 24).padding(.top, 8)
                }
            }
        }
        .sheet(item: $editing) { s in SymbolEditor(symbol: s, listID: watch.selectedID ?? UUID()).environmentObject(watch).sheetCloseBar() }
        .alert("New watchlist", isPresented: $showNewList) {
            TextField("List name", text: $newListName)
            Button("Cancel", role: .cancel) { newListName = "" }
            Button("Create") { watch.addList(newListName); newListName = "" }
        }
    }

    @ViewBuilder private func listChip(_ l: Watchlist) -> some View {
        let on = l.id == watch.selectedID
        Button { watch.selectedID = l.id } label: {
            HStack(spacing: 6) {
                Image(systemName: "star.fill").font(.system(size: 10, weight: .bold))
                Text(l.name).font(.system(size: 12.5, weight: .bold, design: .rounded))
                Text("\(l.symbols.count)").font(.system(size: 10, weight: .heavy, design: .rounded))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(on ? Color.black.opacity(0.2) : BLTheme.bg2).clipShape(Capsule())
            }
            .foregroundColor(on ? Color(hex: 0x1A1305) : BLTheme.sub)
            .padding(.vertical, 7).padding(.horizontal, 12)
            .background(on ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.panel)).clipShape(Capsule())
            .overlay(Capsule().stroke(on ? Color.clear : BLTheme.stroke, lineWidth: 1))
        }.buttonStyle(.plain)
        .contextMenu {
            Button("Delete list", role: .destructive) { watch.deleteList(l.id) }
        }
    }

    private var watchHeader: some View {
        HStack(spacing: 0) {
            Text("SYMBOL").frame(width: 110, alignment: .leading)
            Text("LAST").frame(maxWidth: .infinity, alignment: .trailing)
            Text("CHG%").frame(maxWidth: .infinity, alignment: .trailing)
            Text("REL VOL").frame(maxWidth: .infinity, alignment: .trailing)
            Text("RSI").frame(maxWidth: .infinity, alignment: .trailing)
            Text("").frame(width: 70)
        }
        .font(.system(size: 9.5, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.8)
        .padding(.horizontal, 14)
    }

    @ViewBuilder private func symbolRow(_ s: WatchSymbol, in list: Watchlist) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Button { watch.toggleFlag(s.id, in: list.id) } label: {
                    Image(systemName: s.flagged ? "flag.fill" : "flag")
                        .font(.system(size: 11, weight: .bold)).foregroundColor(s.flagged ? BLTheme.gold : BLTheme.sub)
                }.buttonStyle(.plain)
                Text(s.display).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
            }.frame(width: 110, alignment: .leading)
            cell(s.last.map { TradeMath.num($0) })
            cellPct(s.changePct)
            cell(s.relVolume.map { TradeMath.num($0) + "×" })
            cell(s.rsi.map { String(format: "%.0f", $0) }, tint: rsiTint(s.rsi))
            HStack(spacing: 6) {
                Button { editing = s } label: { Image(systemName: "pencil").font(.system(size: 11, weight: .bold)).foregroundColor(BLTheme.gold) }.buttonStyle(.plain)
                Button { watch.removeSymbol(s.id, from: list.id) } label: { Image(systemName: "trash").font(.system(size: 11, weight: .bold)).foregroundColor(BLTheme.red) }.buttonStyle(.plain)
            }.frame(width: 70)
        }
        .padding(.vertical, 11).padding(.horizontal, 14)
        .background(BLTheme.panel).clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
        .contextMenu {
            Button("Edit snapshot") { editing = s }
            Button(s.flagged ? "Unflag" : "Flag") { watch.toggleFlag(s.id, in: list.id) }
            Button("Remove", role: .destructive) { watch.removeSymbol(s.id, from: list.id) }
        }
    }
    @ViewBuilder private func cell(_ v: String?, tint: Color = BLTheme.text) -> some View {
        Text(v ?? "—").font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
            .foregroundColor(v == nil ? BLTheme.sub : tint).frame(maxWidth: .infinity, alignment: .trailing)
    }
    @ViewBuilder private func cellPct(_ v: Double?) -> some View {
        Text(v.map { (($0 >= 0) ? "+" : "") + String(format: "%.2f%%", $0) } ?? "—")
            .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
            .foregroundColor(v == nil ? BLTheme.sub : (v! >= 0 ? BLTheme.green : BLTheme.red))
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
    private func rsiTint(_ r: Double?) -> Color {
        guard let r = r else { return BLTheme.text }
        if r >= 70 { return BLTheme.red }; if r <= 30 { return BLTheme.green }; return BLTheme.text
    }
}

// Sheet to edit a symbol's user-entered snapshot.
struct SymbolEditor: View {
    @EnvironmentObject var watch: WatchlistStore
    @Environment(\.dismiss) var dismiss
    @State var symbol: WatchSymbol
    let listID: UUID
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 15, weight: .bold)).foregroundColor(Color(hex: 0x1A1305))
                        .frame(width: 30, height: 30).background(BLTheme.goldGrad).clipShape(RoundedRectangle(cornerRadius: 9))
                    Text(symbol.display).font(.system(size: 20, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
                }
                Text("Enter the latest snapshot for this symbol. These are the values you observe on your own platform — the Screener and Alerts run on exactly these. Leave a field blank to mark it unknown (it won't match numeric filters).")
                    .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    OptNumberField(title: "Last price", value: $symbol.last)
                    OptNumberField(title: "% change", value: $symbol.changePct)
                }
                HStack(spacing: 10) {
                    OptNumberField(title: "Volume", value: $symbol.volume)
                    OptNumberField(title: "Relative volume", value: $symbol.relVolume)
                }
                HStack(spacing: 10) {
                    OptNumberField(title: "RSI(14)", value: $symbol.rsi)
                    OptNumberField(title: "ATR", value: $symbol.atr)
                }
                HStack(spacing: 10) {
                    OptNumberField(title: "P/E ratio", value: $symbol.peRatio)
                    OptNumberField(title: "Market cap ($)", value: $symbol.marketCap)
                }
                HStack(spacing: 10) {
                    OptNumberField(title: "Price vs 50-SMA %", value: $symbol.sma50Rel)
                    OptNumberField(title: "Price vs 200-SMA %", value: $symbol.sma200Rel)
                }
                HStack(spacing: 10) {
                    OptNumberField(title: "Dist from 52w high %", value: $symbol.high52wRel)
                    Field(title: "Sector", text: $symbol.sector, prompt: "Tech, Energy…")
                }
                Field(title: "Note", text: $symbol.note, prompt: "Setup / thesis")
                HStack { Spacer()
                    GhostButton(label: "Cancel") { dismiss() }
                    GoldButton(label: "Save snapshot", icon: "checkmark") {
                        symbol.updated = Date()
                        watch.upsertSymbol(symbol, in: listID); dismiss()
                    }
                }.padding(.top, 4)
            }.padding(24).frame(width: 520)
        }
        .frame(width: 520, height: 620).background(BLTheme.bg)
    }
}

// MARK: - Screener screen
struct ScreenerScreen: View {
    @EnvironmentObject var watch: WatchlistStore
    @EnvironmentObject var nav: Nav
    @State private var query = ScreenQuery()
    @State private var symbolText = ""
    @State private var addMetric: ScreenMetric = .changePct
    @State private var addOp: ScreenOp = .gte
    @State private var addA = ""
    @State private var addB = ""

    // Dedup by display symbol (keep first): a ticker held in multiple watchlists must count ONCE,
    // else results.count / universe.count inflate and the screener shows duplicate rows + CSV lines.
    // (Set(allSymbols) won't collapse them — WatchSymbol hashes by its unique id.)
    private var universe: [WatchSymbol] {
        var seen = Set<String>()
        return watch.allSymbols.filter { seen.insert($0.display).inserted }
    }
    private var results: [WatchSymbol] { Screener.run(effectiveQuery, over: universe) }
    private var effectiveQuery: ScreenQuery { var q = query; q.symbolContains = symbolText; return q }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenTitle(title: "Screener", subtitle: "Scan your watchlist symbols by the snapshot metrics you've entered. No live feed — honest no-data never matches.", icon: "line.3.horizontal.decrease.circle.fill")

                if universe.isEmpty {
                    EmptyState(icon: "tray", title: "No symbols to scan",
                               hint: "Add symbols to a watchlist and enter their snapshots first. The screener runs on those values — nothing is fabricated.")
                    GhostButton(label: "Go to Watchlists", icon: "star.fill") { nav.section = .watchlists }
                        .frame(maxWidth: .infinity)
                } else {
                    // Preset library.
                    Panel(title: "Preset scans", icon: "square.grid.2x2.fill") {
                        Text("One-tap category presets — load one, then refine the filters below.")
                            .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], spacing: 10) {
                            ForEach(ScreenPresets.all) { p in presetCard(p) }
                        }
                    }

                    // Custom filter builder.
                    Panel(title: "Filters", icon: "slider.horizontal.3") {
                        HStack(spacing: 10) {
                            Field(title: "Ticker contains", text: $symbolText, prompt: "optional")
                            VStack(alignment: .leading, spacing: 5) {
                                Text("LOGIC").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.6)
                                Picker("", selection: $query.logic) { ForEach(ScreenLogic.allCases) { Text($0.rawValue).tag($0) } }
                                    .pickerStyle(.segmented).labelsHidden()
                            }
                        }
                        Divider().background(BLTheme.stroke)
                        // Active filters.
                        if query.filters.isEmpty {
                            Text("No filters yet — load a preset or add one below.")
                                .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub)
                        } else {
                            ForEach(query.filters) { f in
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundColor(BLTheme.gold)
                                    Text(f.summary).font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                                    Spacer()
                                    Button { query.filters.removeAll { $0.id == f.id } } label: {
                                        Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundColor(BLTheme.red)
                                    }.buttonStyle(.plain)
                                }
                                .padding(.vertical, 7).padding(.horizontal, 11)
                                .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                            }
                        }
                        Divider().background(BLTheme.stroke)
                        // Add-filter row.
                        HStack(spacing: 8) {
                            Picker("", selection: $addMetric) { ForEach(ScreenMetric.allCases) { Text($0.rawValue).tag($0) } }
                                .labelsHidden().frame(width: 180)
                            Picker("", selection: $addOp) { ForEach(ScreenOp.allCases) { Text($0.rawValue).tag($0) } }
                                .labelsHidden().frame(width: 130)
                            TextField("value", text: $addA).textFieldStyle(.plain).frame(width: 70)
                                .padding(8).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 8)).foregroundColor(BLTheme.text)
                            if addOp == .between {
                                TextField("to", text: $addB).textFieldStyle(.plain).frame(width: 60)
                                    .padding(8).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 8)).foregroundColor(BLTheme.text)
                            }
                            GoldButton(label: "Add filter", icon: "plus") {
                                guard let a = Double(addA) else { return }
                                query.filters.append(ScreenFilter(metric: addMetric, op: addOp, a: a, b: Double(addB) ?? 0))
                                addA = ""; addB = ""
                            }
                        }
                        if !query.filters.isEmpty {
                            GhostButton(label: "Clear all filters", icon: "trash", tint: BLTheme.red) { query.filters = []; symbolText = "" }
                        }
                    }

                    // Results.
                    Panel(title: "Matches", icon: "checklist", accent: results.isEmpty ? BLTheme.gold : BLTheme.green) {
                        HStack {
                            Text("\(results.count) of \(universe.count) symbol\(universe.count == 1 ? "" : "s") match")
                                .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                            Spacer()
                            if !results.isEmpty {
                                GhostButton(label: "Export CSV", icon: "square.and.arrow.up") { exportResults() }
                            }
                        }
                        if results.isEmpty {
                            EmptyState(icon: "magnifyingglass", title: "No matches",
                                       hint: "No watchlist symbol satisfies these filters with the snapshots you've entered. Loosen the criteria or update your snapshots.")
                        } else {
                            ForEach(results) { s in resultRow(s) }
                        }
                    }
                }
            }.padding(24)
        }
    }

    @ViewBuilder private func presetCard(_ p: ScreenPreset) -> some View {
        Button { query = p.query; symbolText = "" } label: {
            HStack(spacing: 10) {
                Image(systemName: p.icon).font(.system(size: 14, weight: .bold)).foregroundColor(Color(hex: 0x1A1305))
                    .frame(width: 30, height: 30).background(BLTheme.goldGrad).clipShape(RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    Text(p.blurb).font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.stroke, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    @ViewBuilder private func resultRow(_ s: WatchSymbol) -> some View {
        HStack(spacing: 14) {
            Text(s.display).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text).frame(width: 80, alignment: .leading)
            metricChip("CHG", s.changePct.map { (($0 >= 0) ? "+" : "") + String(format: "%.1f%%", $0) }, s.changePct.map { $0 >= 0 ? BLTheme.green : BLTheme.red } ?? BLTheme.sub)
            metricChip("RVOL", s.relVolume.map { TradeMath.num($0) + "×" }, BLTheme.gold)
            metricChip("RSI", s.rsi.map { String(format: "%.0f", $0) }, BLTheme.blue)
            metricChip("LAST", s.last.map { TradeMath.num($0) }, BLTheme.text)
            Spacer()
        }
        .padding(.vertical, 10).padding(.horizontal, 14)
        .background(BLTheme.panel).clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
    }
    @ViewBuilder private func metricChip(_ l: String, _ v: String?, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(l).font(.system(size: 8.5, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.5)
            Text(v ?? "—").font(.system(size: 12.5, weight: .bold, design: .rounded)).monospacedDigit().foregroundColor(v == nil ? BLTheme.sub : tint)
        }.frame(width: 64, alignment: .leading)
    }

    private func exportResults() {
        func f(_ v: Double?) -> String { v.map { String($0) } ?? "" }
        var csv = "symbol,last,changePct,relVolume,rsi,peRatio\n"
        for s in results {
            let cols = [s.display, f(s.last), f(s.changePct), f(s.relVolume), f(s.rsi), f(s.peRatio)]
            csv += cols.joined(separator: ",") + "\n"
        }
        FileExport.save(csv, suggested: "screener-results.csv")
    }
}

// MARK: - File export helper (NSSavePanel)
enum FileExport {
    static func save(_ text: String, suggested: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.begin { resp in
            if resp == .OK, let url = panel.url {
                try? text.data(using: .utf8)?.write(to: url)
            }
        }
    }
}

// MARK: - Alerts screen
struct AlertsScreen: View {
    @EnvironmentObject var alerts: AlertStore
    @EnvironmentObject var watch: WatchlistStore
    @EnvironmentObject var nav: Nav
    @State private var showNew = false
    @State private var justEvaluated: Int? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    ScreenTitle(title: "Alerts", subtitle: "Price / % / volume / RSI conditions on your symbols. Fires a real macOS notification when your snapshot meets them.", icon: "bell.badge.fill")
                    Spacer()
                    GoldButton(label: "New alert", icon: "plus") { showNew = true }
                }

                // Evaluate panel — honest: alerts run on entered snapshots, not the live feed.
                Panel(title: "Run a check", icon: "play.circle.fill") {
                    Text("Watchlist alerts run on the snapshots you enter, not the live feed. Update a symbol's snapshot in Watchlists, then run a check — any alert whose condition is newly met fires a macOS notification. “Crosses” compares against the snapshot from the previous check.")
                        .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        GoldButton(label: "Check now against watchlists", icon: "bolt.fill") {
                            let fired = alerts.evaluate(watch.allSymbols)
                            withAnimation { justEvaluated = fired.count }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { withAnimation { justEvaluated = nil } }
                        }
                        if let n = justEvaluated {
                            Text(n == 0 ? "No alerts met their conditions." : "\(n) alert\(n == 1 ? "" : "s") fired.")
                                .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(n == 0 ? BLTheme.sub : BLTheme.green)
                        }
                        Spacer()
                        Stat(label: "Active", value: "\(alerts.activeCount)")
                    }
                }

                // Alert list.
                Panel(title: "Your alerts", icon: "bell.fill") {
                    if alerts.alerts.isEmpty {
                        EmptyState(icon: "bell.slash", title: "No alerts yet",
                                   hint: "Create an alert on a symbol you track. When you run a check and your snapshot meets the condition, you'll get a macOS notification.")
                    } else {
                        ForEach(alerts.alerts) { a in alertRow(a) }
                    }
                }

                // Fire log.
                if !alerts.fireLog.isEmpty {
                    Panel(title: "Recent fires (this session)", icon: "clock.fill") {
                        HStack { Spacer(); GhostButton(label: "Clear", icon: "trash", tint: BLTheme.red) { alerts.clearLog() } }
                        ForEach(alerts.fireLog) { f in
                            HStack(spacing: 10) {
                                Image(systemName: "bell.fill").font(.system(size: 11)).foregroundColor(BLTheme.gold)
                                Text(f.message).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                                Spacer()
                                Text(f.at.formatted(date: .omitted, time: .standard)).font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
                            }.padding(.vertical, 5)
                        }
                    }
                }
            }.padding(24)
        }
        .sheet(isPresented: $showNew) { AlertEditor().environmentObject(alerts).environmentObject(watch).sheetCloseBar() }
    }

    @ViewBuilder private func alertRow(_ a: TradeAlert) -> some View {
        HStack(spacing: 14) {
            Image(systemName: a.enabled ? "bell.fill" : "bell.slash.fill")
                .font(.system(size: 13, weight: .bold)).foregroundColor(a.enabled ? Color(hex: 0x1A1305) : BLTheme.sub)
                .frame(width: 30, height: 30)
                .background(a.enabled ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2)).clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(a.symbol.uppercased()).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    StatusPill(text: a.repeats ? "repeat" : "one-shot", tint: BLTheme.blue)
                    if a.fireCount > 0 { StatusPill(text: "fired \(a.fireCount)×", tint: BLTheme.green) }
                }
                Text(a.summary).font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            HStack(spacing: 6) {
                GhostButton(label: a.enabled ? "Pause" : "Arm", icon: a.enabled ? "pause" : "play", tint: a.enabled ? BLTheme.gold : BLTheme.green) { alerts.toggle(a.id) }
                Button { alerts.clone(a.id) } label: { Image(systemName: "doc.on.doc").font(.system(size: 12, weight: .bold)).foregroundColor(BLTheme.sub) }.buttonStyle(.plain)
                Button { alerts.delete(a.id) } label: { Image(systemName: "trash").font(.system(size: 12, weight: .bold)).foregroundColor(BLTheme.red) }.buttonStyle(.plain)
            }
        }
        .padding(14).background(BLTheme.panel).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
    }
}

// New-alert editor.
struct AlertEditor: View {
    @EnvironmentObject var alerts: AlertStore
    @EnvironmentObject var watch: WatchlistStore
    @Environment(\.dismiss) var dismiss
    @State private var symbol = ""
    @State private var combine: AlertCombine = .all
    @State private var repeats = false
    @State private var conditions: [AlertCondition] = [AlertCondition(metric: .last, op: .crossesAbove, threshold: 0)]

    private var knownSymbols: [String] { Array(Set(watch.allSymbols.map { $0.display })).sorted() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "bell.badge.fill").font(.system(size: 15, weight: .bold)).foregroundColor(Color(hex: 0x1A1305))
                        .frame(width: 30, height: 30).background(BLTheme.goldGrad).clipShape(RoundedRectangle(cornerRadius: 9))
                    Text("New alert").font(.system(size: 20, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
                }
                Field(title: "Symbol", text: $symbol, prompt: "e.g. ES, NQ, CL, EURUSD")
                if !knownSymbols.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(knownSymbols, id: \.self) { s in
                                Button { symbol = s } label: {
                                    Text(s).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(BLTheme.gold)
                                        .padding(.vertical, 4).padding(.horizontal, 9).background(BLTheme.gold.opacity(0.12)).clipShape(Capsule())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("CONDITIONS").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.6)
                        Spacer()
                        if conditions.count > 1 {
                            Picker("", selection: $combine) { ForEach(AlertCombine.allCases) { Text("Match \($0.rawValue)").tag($0) } }
                                .pickerStyle(.segmented).labelsHidden().frame(width: 170)
                        }
                    }
                    ForEach($conditions) { $c in
                        HStack(spacing: 8) {
                            Picker("", selection: $c.metric) { ForEach(AlertMetric.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 150)
                            Picker("", selection: $c.op) { ForEach(AlertOp.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 130)
                            TextField("value", value: $c.threshold, format: .number).textFieldStyle(.plain).frame(width: 70)
                                .padding(8).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 8)).foregroundColor(BLTheme.text)
                            if conditions.count > 1 {
                                Button { conditions.removeAll { $0.id == c.id } } label: { Image(systemName: "minus.circle.fill").foregroundColor(BLTheme.red) }.buttonStyle(.plain)
                            }
                        }
                    }
                    GhostButton(label: "Add condition", icon: "plus") { conditions.append(AlertCondition(metric: .changePct, op: .above, threshold: 0)) }
                }
                Toggle(isOn: $repeats) {
                    Text("Re-arm after firing (repeat)").font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                }.tint(BLTheme.gold)
                HStack { Spacer()
                    GhostButton(label: "Cancel") { dismiss() }
                    GoldButton(label: "Create alert", icon: "checkmark") {
                        let s = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard TradingSymbolScope.inScope(s), !conditions.isEmpty else { return }
                        alerts.add(TradeAlert(symbol: s.uppercased(), conditions: conditions, combine: combine, enabled: true, repeats: repeats))
                        dismiss()
                    }
                }.padding(.top, 4)
            }.padding(24).frame(width: 560)
        }
        .frame(width: 560, height: 560).background(BLTheme.bg)
    }
}

// MARK: - Backtest screen
struct BacktestScreen: View {
    @EnvironmentObject var feed: FeedClient
    @EnvironmentObject var nav: Nav
    @State private var csvText = ""
    @State private var bars: [Bar] = []
    @State private var skipped = 0
    @State private var cfg = StrategyConfig()
    @State private var result: (trades: [BacktestTrade], stats: [TradeStat])? = nil
    @State private var importNote = ""
    // Robustness depth (in-house, honest).
    @State private var wfFolds = 4
    @State private var wf: WalkForwardResult? = nil
    @State private var mcRuns = 1000
    @State private var mcCapital = 50000.0
    @State private var mc: MonteCarloResult? = nil
    // No-code edge-gate lab (item 10): pick engine + instrument + date range over the buyer's OWN
    // captured bars, run the SHIPPED prover, show per-fold n/W-L/maxDrawdownR/p + prover_sha.
    @State private var labEngine = "meanrev"
    @State private var labSymbol = ""
    @State private var labFolds = 3
    @State private var labSymbols: [String] = []
    @State private var labUseRange = false
    @State private var labStart = Date().addingTimeInterval(-86_400 * 30)
    @State private var labEnd = Date()
    @State private var labBoundsNote = ""
    @State private var labReport: BacktestLabReport? = nil
    @State private var labRunning = false

    // TR-19 local parameter research screen: fan the fixed grid across this Mac's cores over the
    // buyer's OWN bars. A pass is selection-only and must survive separate nested confirmation.
    @State private var farmEngine = "meanrev"
    @State private var farmSymbol = ""
    @State private var farmReport: BacktestFarmReport? = nil
    @State private var farmRunning = false

    private var report: PerfReport? { result.map { Analytics.report($0.stats) } }
    private var panel: Analytics.RiskPanel? { result.map { Analytics.riskPanel($0.stats) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenTitle(title: "Backtest", subtitle: "Run the SHIPPED edge-gate on YOUR captured bars — no code — or paste your own CSV to test a custom rule set. Honest metrics on real data, never a fabricated track record.", icon: "clock.arrow.circlepath")

                labPanel

                farmPanel

                HStack(spacing: 10) {
                    Rectangle().fill(BLTheme.stroke).frame(height: 1)
                    Text("OR TEST A CUSTOM RULE SET ON PASTED BARS").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.6).fixedSize()
                    Rectangle().fill(BLTheme.stroke).frame(height: 1)
                }.padding(.vertical, 2)

                // Data input.
                Panel(title: "1 · Your historical bars", icon: "square.and.arrow.down") {
                    Text("Paste CSV (date,open,high,low,close[,volume]) or import a file. Dates: ISO-8601 / yyyy-MM-dd / MM/dd/yyyy. This is your data — nothing is downloaded or invented.")
                        .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                    TextEditor(text: $csvText).font(.system(size: 11, design: .monospaced)).foregroundColor(BLTheme.text)
                        .scrollContentBackground(.hidden).padding(8).frame(height: 90)
                        .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                    HStack(spacing: 8) {
                        GhostButton(label: "Import CSV file", icon: "doc.badge.plus") { importFile() }
                        GoldButton(label: "Load bars", icon: "checkmark") { loadBars() }
                        if !importNote.isEmpty {
                            Text(importNote).font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(bars.isEmpty ? BLTheme.red : BLTheme.green)
                        }
                    }
                    if !bars.isEmpty {
                        HStack(spacing: 12) {
                            Stat(label: "Bars loaded", value: "\(bars.count)")
                            if let f = bars.first, let l = bars.last {
                                Stat(label: "Range", value: "\(f.date.formatted(date: .abbreviated, time: .omitted)) → \(l.date.formatted(date: .abbreviated, time: .omitted))")
                            }
                        }
                    }
                }

                // Strategy config.
                Panel(title: "2 · Strategy", icon: "slider.horizontal.3") {
                    HStack(spacing: 10) {
                        pickerField("Entry", $cfg.entry, EntryRule.allCases) { $0.rawValue }
                        pickerField("Exit", $cfg.exit, ExitRule.allCases) { $0.rawValue }
                    }
                    HStack(spacing: 10) {
                        intField("Fast SMA", $cfg.fastSMA)
                        intField("Slow SMA", $cfg.slowSMA)
                        intField("RSI period", $cfg.rsiPeriod)
                        intField("Breakout lookback", $cfg.breakoutLookback)
                    }
                    HStack(spacing: 10) {
                        intField("ATR period", $cfg.atrPeriod)
                        dblField("ATR stop ×", $cfg.atrStopMult)
                        dblField("Target (R)", $cfg.targetR)
                        intField("Time stop (bars)", $cfg.timeStopBars)
                    }
                    HStack(spacing: 10) {
                        dblField("$/point", $cfg.pointValue)
                        dblField("Commission/trade", $cfg.commissionPerTrade)
                        dblField("Slippage/side", $cfg.slippagePerSide)
                    }
                    GoldButton(label: "Run backtest", fill: true, icon: "play.fill") {
                        result = Backtester.run(bars, cfg); wf = nil; mc = nil
                    }.disabled(bars.isEmpty).opacity(bars.isEmpty ? 0.5 : 1)
                }

                // Results.
                if let rep = report, let res = result {
                    if res.trades.isEmpty {
                        Panel(title: "3 · Results", icon: "chart.bar.xaxis") {
                            EmptyState(icon: "exclamationmark.magnifyingglass", title: "No trades triggered",
                                       hint: "The rules didn't produce an entry on these bars. Try different SMA periods, a different entry rule, or more bars.")
                        }
                    } else {
                        backtestMetrics(rep, panel)
                        BacktestEquityCard(stats: res.stats)
                        RDistributionCard(stats: res.stats)
                        walkForwardCard(res)
                        monteCarloCard(res)
                        Panel(title: "Trade list", icon: "list.bullet") {
                            ForEach(res.trades) { t in backtestTradeRow(t) }
                        }
                    }
                }
            }.padding(24)
        }
    }

    // MARK: - No-code edge-gate lab. Pick engine + instrument + optional date range; the backend
    // runs the SAME shipped prover (bltd_store.PROVERS) on the buyer's OWN captured bars, split into
    // contiguous folds, and returns per-fold n / W-L / max-drawdown-R / p-value + the prover sha256.
    // NO aggregate win-rate, NO equity, NO $ figure — the buyer's own edge math on their own data.
    private var labPanel: some View {
        Panel(title: "No-code edge-gate lab", icon: "flask.fill", accent: BLTheme.gold) {
            Text("Pick an engine and one captured instrument, then run the shipped research screen over the whole range or a slice. You get the out-of-sample trade count, wins / losses, max drawdown in R, and one-sided realized-mean-R p-value with serial-dependence penalty per fold, plus the prover fingerprint for reproduction (shasum -a 256 bltd_store.py). Fewer than \(labReport?.minTrades ?? 30) OOS trades in a fold shows as insufficient. Any pass still requires separate nested confirmation and is never live-adopted by this screen.")
                .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)

            if !feed.isSignedIn {
                EmptyState(icon: "person.crop.circle.badge.questionmark", title: "Sign in to run the lab",
                           hint: "The lab runs entirely on your own local backend and your own captured bars. Connect in the Feeds tab.")
                GhostButton(label: "Go to Feeds", icon: "globe") { nav.section = .feeds }
            } else if labSymbols.isEmpty {
                EmptyState(icon: "square.stack.3d.up.slash", title: "No captured instruments yet",
                           hint: "Connect your feed and let bars accumulate — an instrument becomes testable once enough bars are stored. Nothing is downloaded or invented.")
                GhostButton(label: "Connect my feed", icon: "globe") { nav.section = .feeds }
            } else {
                // 1. Engine + instrument pickers.
                HStack(spacing: 10) {
                    pickerField("Engine", $labEngine, EngineRoster.order) { EngineRoster.label(for: $0) }
                    pickerField("Instrument", $labSymbol, labSymbols) { $0 }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("FOLDS").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.5)
                        Stepper(value: $labFolds, in: 1...8) { Text("\(labFolds)").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text).monospacedDigit() }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if !labBoundsNote.isEmpty {
                    Text(labBoundsNote).font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
                }
                // 2. Optional date range over the buyer's captured bars.
                Toggle(isOn: $labUseRange) {
                    Text("Limit to a date range (default: your whole captured series)")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                }.toggleStyle(.switch).tint(BLTheme.gold)
                if labUseRange {
                    HStack(spacing: 12) {
                        DatePicker("From", selection: $labStart, displayedComponents: .date).datePickerStyle(.field)
                            .font(.system(size: 12, design: .rounded)).foregroundColor(BLTheme.text)
                        DatePicker("To", selection: $labEnd, displayedComponents: .date).datePickerStyle(.field)
                            .font(.system(size: 12, design: .rounded)).foregroundColor(BLTheme.text)
                    }
                }
                HStack(spacing: 10) {
                    GoldButton(label: labRunning ? "Running the prover…" : "Run edge-gate on my bars", fill: true, icon: "play.fill") {
                        Task { await runLab() }
                    }.disabled(labRunning || labSymbol.isEmpty)
                    if let r = labReport, r.available {
                        StatusPill(text: labStatusText(r), tint: labStatusTint(r))
                    }
                }
                if let r = labReport { labResults(r) }
            }
        }
        .task { await loadLabSymbols() }
        .onChange(of: labSymbol) { _ in Task { await refreshLabBounds() } }
    }

    @ViewBuilder private func labResults(_ r: BacktestLabReport) -> some View {
        if !r.available {
            EmptyState(icon: "shield.lefthalf.filled", title: "Nothing to test yet",
                       hint: r.reason.isEmpty ? "Not enough captured bars for this instrument and range." : r.reason)
        } else {
            Divider().background(BLTheme.stroke).padding(.vertical, 2)
            // Mandatory honesty label — verbatim, always shown with results.
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill").font(.system(size: 11)).foregroundColor(BLTheme.gold)
                Text("Research screen on your captured bars only. A pass requires separate nested confirmation; this screen never enables or live-adopts a strategy.")
                    .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold).fixedSize(horizontal: false, vertical: true)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(BLTheme.gold.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.gold.opacity(0.35), lineWidth: 1))

            if let w = r.whole {
                Text("WHOLE RANGE (\(r.totalBars) bars)").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.6)
                labFoldRow(w, minTrades: r.minTrades, headline: true)
            }
            if r.folds.count > 1 {
                Text("PER FOLD").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.6)
                VStack(spacing: 8) { ForEach(r.folds) { labFoldRow($0, minTrades: r.minTrades, headline: false) } }
            }
            Text("Reproducible: \(r.proverLine)" + (r.generatedUTC.isEmpty ? "" : " · ran \(r.generatedUTC)") + " · instrument \(r.symbol)")
                .font(.system(size: 9, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func labFoldRow(_ f: BacktestLabFold, minTrades: Int, headline: Bool) -> some View {
        let tint = f.proven ? BLTheme.blue : (f.insufficient ? BLTheme.sub : BLTheme.gold)
        let status = f.proven ? "SCREEN PASS" : (f.insufficient ? "THIN" : "NO EDGE")
        return HStack(spacing: 12) {
            Image(systemName: f.proven ? "checkmark.circle.fill" : (f.insufficient ? "hourglass" : "xmark.seal"))
                .font(.system(size: 14, weight: .bold)).foregroundColor(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline ? "Whole range" : "Fold \(f.fold)").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Text(f.statLine(minTrades: minTrades)).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).monospacedDigit().lineLimit(1)
            }
            Spacer()
            StatusPill(text: status, tint: tint)
        }
        .padding(12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
    }

    private func labStatusText(_ r: BacktestLabReport) -> String {
        switch r.status {
        case "candidate": return "RESEARCH SCREEN PASS"
        case "no_edge": return "NO EDGE"
        default: return "INSUFFICIENT"
        }
    }
    private func labStatusTint(_ r: BacktestLabReport) -> Color {
        switch r.status {
        case "candidate": return BLTheme.blue
        case "no_edge": return BLTheme.gold
        default: return BLTheme.sub
        }
    }

    private func loadLabSymbols() async {
        guard feed.isSignedIn else { return }
        await feed.refreshStatus()
        let syms = feed.symbols.backtestable
        await MainActor.run {
            labSymbols = syms
            if labSymbol.isEmpty || !syms.contains(labSymbol) { labSymbol = syms.first ?? "" }
        }
        await refreshLabBounds()
    }

    private func refreshLabBounds() async {
        guard feed.isSignedIn, !labSymbol.isEmpty else { return }
        let b = await feed.barBounds(symbol: labSymbol)
        await MainActor.run {
            if b.count > 0, let lo = b.firstTs, let hi = b.lastTs {
                let loD = Date(timeIntervalSince1970: TimeInterval(lo))
                let hiD = Date(timeIntervalSince1970: TimeInterval(hi))
                labStart = loD; labEnd = hiD
                let df = DateFormatter(); df.dateStyle = .medium
                labBoundsNote = "\(b.count) bars captured for \(labSymbol): \(df.string(from: loD)) → \(df.string(from: hiD))."
            } else {
                labBoundsNote = "No bars captured for \(labSymbol) yet."
            }
        }
    }

    private func runLab() async {
        await MainActor.run { labRunning = true }
        let startTs = labUseRange ? Int(labStart.timeIntervalSince1970) : nil
        let endTs = labUseRange ? Int(labEnd.timeIntervalSince1970) : nil
        let r = await feed.runBacktestLab(engine: labEngine, symbol: labSymbol, startTs: startTs, endTs: endTs, folds: labFolds)
        await MainActor.run { labReport = r; labRunning = false }
    }

    // MARK: - TR-19 local parameter research screen. Pick engine + instrument; the backend fans the
    // fixed grid across THIS Mac's cores over the buyer's OWN captured bars. Every pass is a
    // selection for separate nested confirmation, never a strategy enablement or live adoption.
    private var farmPanel: some View {
        Panel(title: "Local parameter research screen", icon: "cpu.fill", accent: BLTheme.gold) {
            Text("Screen a fixed parameter grid on this Mac's performance cores using only your captured bars. No cloud, no data fee, nothing downloaded. Every p-value is Benjamini–Hochberg FDR-corrected across ALL cells tried; a raw best-cell p is never shown. Fewer than \(farmReport?.minTrades ?? 30) OOS trades in a cell shows as insufficient. A screen pass is selection-only, requires separate anchored nested confirmation, and is never live-adopted by this screen.")
                .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)

            if !feed.isSignedIn {
                EmptyState(icon: "person.crop.circle.badge.questionmark", title: "Sign in to run the research screen",
                           hint: "The screen runs entirely on your local backend and your captured bars. Connect in the Feeds tab.")
                GhostButton(label: "Go to Feeds", icon: "globe") { nav.section = .feeds }
            } else if labSymbols.isEmpty {
                EmptyState(icon: "square.stack.3d.up.slash", title: "No captured instruments yet",
                           hint: "Connect your feed and let bars accumulate — screening can start once enough bars are stored. Nothing is downloaded or invented.")
                GhostButton(label: "Connect my feed", icon: "globe") { nav.section = .feeds }
            } else {
                HStack(spacing: 10) {
                    pickerField("Engine", $farmEngine, EngineRoster.order) { EngineRoster.label(for: $0) }
                    pickerField("Instrument", $farmSymbol, labSymbols) { $0 }
                }
                HStack(spacing: 10) {
                    GoldButton(label: farmRunning ? "Screening on your cores…" : "Run research screen", fill: true, icon: "cpu") {
                        Task { await runFarm() }
                    }.disabled(farmRunning || farmSymbol.isEmpty)
                    if let r = farmReport, r.available {
                        StatusPill(text: farmStatusText(r), tint: farmStatusTint(r))
                    }
                }
                if let r = farmReport { farmResults(r) }
            }
        }
        .onAppear { if farmSymbol.isEmpty { farmSymbol = labSymbols.first ?? "" } }
        .onChange(of: labSymbols) { syms in if farmSymbol.isEmpty || !syms.contains(farmSymbol) { farmSymbol = syms.first ?? "" } }
    }

    @ViewBuilder private func farmResults(_ r: BacktestFarmReport) -> some View {
        if !r.available {
            EmptyState(icon: "shield.lefthalf.filled", title: "Nothing to sweep yet",
                       hint: r.reason.isEmpty ? "Not enough captured bars for this instrument." : r.reason)
        } else {
            Divider().background(BLTheme.stroke).padding(.vertical, 2)
            // Mandatory selection-only banner, always shown with results.
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle.fill").font(.system(size: 11)).foregroundColor(BLTheme.gold)
                Text("\(r.cellsTried) parameter cells screened on your captured bars. Any pass is selection-only; separate anchored nested confirmation is required. This screen never enables or live-adopts a strategy. \(r.overfitNote)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold).fixedSize(horizontal: false, vertical: true)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(BLTheme.gold.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.gold.opacity(0.35), lineWidth: 1))

            HStack(spacing: 12) {
                Stat(label: "Cells screened", value: "\(r.cellsTried)")
                Stat(label: "Selections", value: "\(r.selectionCount)")
                Stat(label: "Insufficient", value: "\(r.cellsInsufficient)")
                Stat(label: "Compute", value: r.compute.isEmpty ? "—" : r.compute)
            }
            if !r.reason.isEmpty {
                Text(r.reason).font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }
            if let b = r.best {
                Text("TOP SCREENED CELL (BY FDR-ADJUSTED p)").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.6)
                farmCellRow(b, headline: true)
            }
            let shown = Array(r.cells.prefix(12))
            if !shown.isEmpty {
                Text("CELLS (top \(shown.count) of \(r.cellsTried))").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.6)
                VStack(spacing: 8) { ForEach(shown) { farmCellRow($0, headline: false) } }
            }
            Text("Reproducible: \(r.proverLine) · \(r.cores) cores" + (r.generatedUTC.isEmpty ? "" : " · ran \(r.generatedUTC)") + " · instrument \(r.symbol)")
                .font(.system(size: 9, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func farmCellRow(_ c: BacktestFarmCell, headline: Bool) -> some View {
        let tint = c.selectedForConfirmation ? BLTheme.blue : (c.insufficient ? BLTheme.sub : BLTheme.gold)
        let status = c.selectedForConfirmation ? "SELECTED ONLY" : (c.insufficient ? "THIN" : "NO EDGE")
        return HStack(spacing: 12) {
            Image(systemName: c.selectedForConfirmation ? "checkmark.circle.fill" : (c.insufficient ? "hourglass" : "xmark.seal"))
                .font(.system(size: 14, weight: .bold)).foregroundColor(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.params.isEmpty ? "default" : c.params).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text).lineLimit(1)
                Text(c.statLine).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).monospacedDigit().lineLimit(1)
            }
            Spacer()
            StatusPill(text: status, tint: tint)
        }
        .padding(12).background(headline ? BLTheme.gold.opacity(0.06) : BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(headline ? BLTheme.gold.opacity(0.35) : BLTheme.stroke, lineWidth: 1))
    }

    private func farmStatusText(_ r: BacktestFarmReport) -> String {
        switch r.status {
        case "candidate": return "SELECTED FOR CONFIRMATION"
        case "no_edge": return "NO EDGE"
        default: return "INSUFFICIENT"
        }
    }
    private func farmStatusTint(_ r: BacktestFarmReport) -> Color {
        switch r.status {
        case "candidate": return BLTheme.blue
        case "no_edge": return BLTheme.gold
        default: return BLTheme.sub
        }
    }

    private func runFarm() async {
        await MainActor.run { farmRunning = true }
        let r = await feed.runBacktestFarm(engine: farmEngine, symbol: farmSymbol)
        await MainActor.run { farmReport = r; farmRunning = false }
    }

    // MARK: - Walk-forward robustness (in-house — is the edge consistent across time?)
    @ViewBuilder private func walkForwardCard(_ res: (trades: [BacktestTrade], stats: [TradeStat])) -> some View {
        Panel(title: "Walk-forward robustness", icon: "rectangle.split.3x1.fill", accent: BLTheme.blue) {
            Text("Splits your bars into contiguous folds and re-runs the SAME rules on each — edge concentrated in one slice is a red flag, not a track record.")
                .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Stepper(value: $wfFolds, in: 2...12) { Text("Folds: \(wfFolds)").font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text) }.fixedSize()
                GoldButton(label: "Run walk-forward", icon: "play.fill") { wf = WalkForward.run(bars, cfg, folds: wfFolds) }
                Spacer()
            }
            if let wf = wf {
                if wf.totalFolds == 0 {
                    EmptyState(icon: "exclamationmark.triangle", title: "Not enough bars", hint: "Need at least \(wfFolds * 10) bars for \(wfFolds) folds. Load more data or reduce folds.")
                } else {
                    HStack(spacing: 12) {
                        metricTile("Positive folds", "\(wf.positiveFolds)/\(wf.totalFolds)", wf.consistency >= 0.5 ? BLTheme.green : BLTheme.red)
                        metricTile("Consistency", TradeMath.pct(wf.consistency * 100), wf.consistency >= 0.5 ? BLTheme.green : BLTheme.gold)
                        metricTile("Avg fold expectancy", "\(TradeMath.num(wf.avgExpectancyR))R", wf.avgExpectancyR >= 0 ? BLTheme.green : BLTheme.red)
                        metricTile("Combined trades", "\(wf.combinedReport.trades)", BLTheme.text)
                    }
                    Chart(wf.folds) { f in
                        BarMark(x: .value("Fold", f.index), y: .value("Net", f.report.netPnL))
                            .foregroundStyle(f.report.netPnL >= 0 ? BLTheme.green : BLTheme.red).cornerRadius(4)
                    }
                    .frame(height: 130)
                    .chartXAxis { AxisMarks(values: .stride(by: 1)) { v in AxisValueLabel { if let i = v.as(Int.self) { Text("F\(i)").font(.system(size: 9)).foregroundStyle(BLTheme.sub) } } } }
                    .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(BLTheme.stroke.opacity(0.4)); AxisValueLabel().foregroundStyle(BLTheme.sub) } }
                    ForEach(wf.folds) { f in
                        HStack(spacing: 10) {
                            Text("Fold \(f.index)").font(.system(size: 11.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.gold).frame(width: 56, alignment: .leading)
                            Text(f.startDate.formatted(date: .abbreviated, time: .omitted) + " → " + f.endDate.formatted(date: .abbreviated, time: .omitted))
                                .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
                            Spacer()
                            Text("\(f.trades) trades").font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
                            Text(TradeMath.pct(f.report.winRate)).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text).frame(width: 50, alignment: .trailing)
                            Text((f.report.netPnL >= 0 ? "+" : "") + TradeMath.money(f.report.netPnL)).font(.system(size: 12, weight: .heavy, design: .rounded)).monospacedDigit()
                                .foregroundColor(f.report.netPnL >= 0 ? BLTheme.green : BLTheme.red).frame(width: 84, alignment: .trailing)
                        }.padding(.vertical, 6).padding(.horizontal, 11).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    // MARK: - Monte-Carlo (bootstrap the realized trades into an outcome distribution)
    @ViewBuilder private func monteCarloCard(_ res: (trades: [BacktestTrade], stats: [TradeStat])) -> some View {
        Panel(title: "Monte-Carlo simulation", icon: "dice.fill", accent: BLTheme.gold) {
            Text("Resamples your realized trades (with replacement) to show the DISTRIBUTION of outcomes + risk of ruin — so one lucky run isn't mistaken for an edge. Seeded → reproducible.")
                .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Stepper(value: $mcRuns, in: 100...10000, step: 100) { Text("Runs: \(mcRuns)").font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text) }.fixedSize()
                VStack(alignment: .leading, spacing: 3) {
                    Text("ACCOUNT $").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                    TextField("", value: $mcCapital, format: .number).textFieldStyle(.plain).frame(width: 90)
                        .font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.text).padding(7).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                GoldButton(label: "Run Monte-Carlo", icon: "play.fill") {
                    mc = MonteCarlo.run(res.stats, runs: mcRuns, startingCapital: mcCapital, ruinFraction: 1.0)
                }
                Spacer()
            }
            if let mc = mc, mc.runs > 0 {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    metricTile("Median outcome", (mc.medianFinalEquity >= 0 ? "+" : "") + TradeMath.money(mc.medianFinalEquity), mc.medianFinalEquity >= 0 ? BLTheme.green : BLTheme.red)
                    metricTile("5th pct (downside)", (mc.p5FinalEquity >= 0 ? "+" : "") + TradeMath.money(mc.p5FinalEquity), BLTheme.red)
                    metricTile("95th pct (upside)", "+" + TradeMath.money(mc.p95FinalEquity), BLTheme.green)
                    metricTile("Prob. profitable", TradeMath.pct(mc.probProfit), mc.probProfit >= 50 ? BLTheme.green : BLTheme.gold)
                    metricTile("Median max DD", "-" + TradeMath.money(mc.medianMaxDrawdown), BLTheme.red)
                    metricTile("Worst-case DD (p95)", "-" + TradeMath.money(mc.p95MaxDrawdown), BLTheme.red)
                    metricTile("Risk of ruin", TradeMath.pct(mc.riskOfRuin), mc.riskOfRuin > 5 ? BLTheme.red : BLTheme.green)
                }
                Chart(MonteCarlo.histogram(mc.finals)) { b in
                    BarMark(x: .value("Outcome", b.mid), y: .value("Count", b.count))
                        .foregroundStyle(b.mid >= 0 ? BLTheme.green.opacity(0.8) : BLTheme.red.opacity(0.8))
                }
                .frame(height: 150)
                .chartXAxis { AxisMarks { v in AxisValueLabel { if let d = v.as(Double.self) { Text(TradeMath.money(d)).font(.system(size: 8)).foregroundStyle(BLTheme.sub) } } } }
                .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(BLTheme.stroke.opacity(0.4)); AxisValueLabel().foregroundStyle(BLTheme.sub) } }
                Text("Distribution of terminal net P&L over \(mc.runs) bootstrapped runs of \(mc.samplePerRun) trades each. This is robustness analysis on your own results — not a forecast or guarantee.")
                    .font(.system(size: 10, design: .rounded)).foregroundColor(BLTheme.sub)
            }
        }
    }

    @ViewBuilder private func backtestMetrics(_ r: PerfReport, _ p: Analytics.RiskPanel?) -> some View {
        Panel(title: "3 · Performance (honest, on your data)", icon: "chart.bar.xaxis", accent: r.netPnL >= 0 ? BLTheme.green : BLTheme.red) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                metricTile("Net P&L", (r.netPnL >= 0 ? "+" : "") + TradeMath.money(r.netPnL), r.netPnL >= 0 ? BLTheme.green : BLTheme.red)
                metricTile("Trades", "\(r.trades)", BLTheme.text)
                metricTile("Win rate", TradeMath.pct(r.winRate), BLTheme.gold)
                metricTile("Profit factor", r.profitFactor.isInfinite ? "∞" : TradeMath.num(r.profitFactor), BLTheme.gold)
                metricTile("Expectancy", TradeMath.num(r.expectancyR) + "R", BLTheme.text)
                metricTile("Avg win / loss", "\(TradeMath.num(r.payoffRatio))×", BLTheme.text)
                metricTile("Max drawdown", "-" + TradeMath.money(r.maxDrawdown), BLTheme.red)
                metricTile("Largest win", "+" + TradeMath.money(r.largestWin), BLTheme.green)
                metricTile("Largest loss", TradeMath.money(r.largestLoss), BLTheme.red)
                metricTile("Max win streak", "\(r.maxWinStreak)", BLTheme.green)
                metricTile("Max loss streak", "\(r.maxLossStreak)", BLTheme.red)
                metricTile("Avg MAE / MFE", "\(TradeMath.num(r.avgMAE)) / \(TradeMath.num(r.avgMFE))R", BLTheme.sub)
                if let p = p {
                    metricTile("Sharpe (per trade)", TradeMath.num(p.sharpe), BLTheme.blue)
                    metricTile("Sortino", TradeMath.num(p.sortino), BLTheme.blue)
                    metricTile("SQN", TradeMath.num(p.sqn), BLTheme.blue)
                }
            }
            Text("Includes \(TradeMath.money(cfg.commissionPerTrade))/trade commission and \(TradeMath.num(cfg.slippagePerSide)) pts/side slippage. Past results on historical bars do not guarantee future performance.")
                .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).padding(.top, 4)
        }
    }

    @ViewBuilder private func backtestTradeRow(_ t: BacktestTrade) -> some View {
        HStack(spacing: 12) {
            Image(systemName: t.direction.icon).font(.system(size: 11, weight: .bold)).foregroundColor(Color(hex: 0x111111))
                .frame(width: 24, height: 24).background(t.r >= 0 ? BLTheme.green : BLTheme.red).clipShape(RoundedRectangle(cornerRadius: 7))
            Text(t.entryDate.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).frame(width: 90, alignment: .leading)
            Text("\(TradeMath.num(t.entry)) → \(TradeMath.num(t.exit))").font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit().foregroundColor(BLTheme.text)
            Spacer()
            Text("\(t.barsHeld) bars").font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
            Text("\(TradeMath.num(t.r))R").font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(t.r >= 0 ? BLTheme.green : BLTheme.red).frame(width: 56, alignment: .trailing)
            Text((t.pnlDollars >= 0 ? "+" : "") + TradeMath.money(t.pnlDollars)).font(.system(size: 12.5, weight: .heavy, design: .rounded)).monospacedDigit().foregroundColor(t.pnlDollars >= 0 ? BLTheme.green : BLTheme.red).frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 8).padding(.horizontal, 12)
        .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
    }

    // Small field helpers.
    @ViewBuilder private func metricTile(_ l: String, _ v: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(l.uppercased()).font(.system(size: 9, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.5)
            Text(v).font(.system(size: 17, weight: .heavy, design: .rounded)).foregroundColor(tint).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(11).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
    }
    @ViewBuilder private func pickerField<T: Hashable>(_ title: String, _ sel: Binding<T>, _ opts: [T], _ label: @escaping (T) -> String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.6)
            Picker("", selection: sel) { ForEach(opts, id: \.self) { Text(label($0)).tag($0) } }.labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private func intField(_ title: String, _ v: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.5)
            TextField("", value: v, format: .number).textFieldStyle(.plain).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                .padding(8).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(BLTheme.stroke, lineWidth: 1))
        }.frame(maxWidth: .infinity)
    }
    @ViewBuilder private func dblField(_ title: String, _ v: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.5)
            TextField("", value: v, format: .number).textFieldStyle(.plain).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                .padding(8).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(BLTheme.stroke, lineWidth: 1))
        }.frame(maxWidth: .infinity)
    }

    private func loadBars() {
        let parsed = BarCSV.parse(csvText)
        bars = parsed.bars; skipped = parsed.skipped; result = nil
        importNote = bars.isEmpty ? "No valid rows found." : "Loaded \(bars.count) bars" + (skipped > 0 ? " (\(skipped) skipped)" : "") + "."
    }
    private func importFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText, .plainText]; panel.allowsMultipleSelection = false
        panel.begin { resp in
            if resp == .OK, let url = panel.url, let s = try? String(contentsOf: url, encoding: .utf8) {
                csvText = s; loadBars()
            }
        }
    }
}

// Equity curve for a set of stats (reused by backtest + analytics).
struct BacktestEquityCard: View {
    let stats: [TradeStat]
    private var points: [(Int, Double)] {
        var eq = 0.0; var pts: [(Int, Double)] = [(0, 0)]
        for (i, s) in stats.sorted(by: { $0.date < $1.date }).enumerated() { eq += s.pnl; pts.append((i+1, eq)) }
        return pts
    }
    var body: some View {
        let last = points.last?.1 ?? 0
        let tint: Color = last >= 0 ? BLTheme.green : BLTheme.red
        Panel(title: "Equity curve", icon: "chart.xyaxis.line", accent: tint) {
            Chart {
                ForEach(points, id: \.0) { p in
                    AreaMark(x: .value("Trade", p.0), y: .value("Equity", p.1))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Trade", p.0), y: .value("Equity", p.1))
                        .interpolationMethod(.monotone).lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round)).foregroundStyle(tint)
                }
                RuleMark(y: .value("Flat", 0)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4,4])).foregroundStyle(BLTheme.sub.opacity(0.3))
            }
            .frame(height: 180)
            .chartYAxis { AxisMarks(position: .leading) { v in AxisGridLine().foregroundStyle(BLTheme.stroke.opacity(0.5)); AxisValueLabel { if let d = v.as(Double.self) { Text(TradeMath.money(d)).foregroundStyle(BLTheme.sub) } } } }
            .chartXAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(BLTheme.stroke.opacity(0.5)); AxisValueLabel().foregroundStyle(BLTheme.sub) } }
        }
    }
}

// R-multiple distribution histogram.
struct RDistributionCard: View {
    let stats: [TradeStat]
    var body: some View {
        let dist = Analytics.rDistribution(stats)
        Panel(title: "R-multiple distribution", icon: "chart.bar.fill") {
            Chart(dist) { b in
                BarMark(x: .value("Bucket", b.label), y: .value("Count", b.count))
                    .foregroundStyle(b.lo >= 0 ? BLTheme.green : BLTheme.red)
                    .cornerRadius(4)
            }
            .frame(height: 160)
            .chartXAxis { AxisMarks { v in AxisValueLabel { if let s = v.as(String.self) { Text(s).font(.system(size: 8)).foregroundStyle(BLTheme.sub) } } } }
            .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(BLTheme.stroke.opacity(0.4)); AxisValueLabel().foregroundStyle(BLTheme.sub) } }
        }
    }
}

// MARK: - Analytics screen (journal performance depth + unified risk panel)
struct AnalyticsScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Nav

    // Build honest TradeStats from the user's CLOSED journal trades. Uses the trade's real
    // exit-time hold duration, recorded MAE/MFE, and explicit tags + #hashtags from notes.
    private var stats: [TradeStat] {
        model.closedTrades.map { t in
            TradeStat(symbol: t.symbol, direction: t.direction, pnl: t.pnl, r: t.rMultiple,
                      date: t.created, holdMinutes: t.holdMinutes, mae: t.maeR, mfe: t.mfeR, tags: t.allTags)
        }
    }

    private var report: PerfReport { Analytics.report(stats) }
    private var panel: Analytics.RiskPanel { Analytics.riskPanel(stats) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenTitle(title: "Analytics", subtitle: "Deep performance analytics on your own closed journal trades. Every stat is computed — none invented.", icon: "chart.bar.xaxis")

                if stats.isEmpty {
                    EmptyState(icon: "chart.bar.xaxis", title: "No closed trades to analyze",
                               hint: "Log trades in the Journal and mark them Win or Loss with a realized P&L. Add #tags in notes (e.g. #breakout #fomo) to unlock setup/mistake breakdowns here.")
                    GhostButton(label: "Go to Journal", icon: "list.bullet.rectangle.fill") { nav.section = .journal }.frame(maxWidth: .infinity)
                } else {
                    // Headline report.
                    Panel(title: "Performance summary", icon: "chart.line.uptrend.xyaxis", accent: report.netPnL >= 0 ? BLTheme.green : BLTheme.red) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                            tile("Net P&L", (report.netPnL >= 0 ? "+" : "") + TradeMath.money(report.netPnL), report.netPnL >= 0 ? BLTheme.green : BLTheme.red)
                            tile("Closed trades", "\(report.trades)", BLTheme.text)
                            tile("Win rate", TradeMath.pct(report.winRate), BLTheme.gold)
                            tile("Profit factor", report.profitFactor.isInfinite ? "∞" : TradeMath.num(report.profitFactor), BLTheme.gold)
                            tile("Expectancy", TradeMath.num(report.expectancyR) + "R", BLTheme.text)
                            tile("Avg win / loss", "\(TradeMath.num(report.payoffRatio))×", BLTheme.text)
                            tile("Max drawdown", "-" + TradeMath.money(report.maxDrawdown), BLTheme.red)
                            tile("Long / Short WR", "\(TradeMath.pct(report.longWinRate)) / \(TradeMath.pct(report.shortWinRate))", BLTheme.blue)
                        }
                    }

                    // The unified risk panel — the differentiator no journal bundles in one view.
                    riskPanelCard

                    // R-distribution + equity from journal.
                    BacktestEquityCard(stats: stats)
                    RDistributionCard(stats: stats)

                    // Calendar P&L heatmap.
                    CalendarHeatmapCard(stats: stats)

                    // Time-of-day + weekday.
                    HStack(alignment: .top, spacing: 16) {
                        TimeOfDayCard(stats: stats)
                        WeekdayCard(stats: stats)
                    }

                    // By symbol + by tag.
                    HStack(alignment: .top, spacing: 16) {
                        BySymbolCard(stats: stats)
                        ByTagCard(stats: stats)
                    }

                    // Seasonality (monthly) + hold-time edge.
                    SeasonalityCard(stats: stats)
                    HoldTimeCard(stats: stats)

                    // Symbol correlation matrix (needs >= 2 symbols overlapping on days).
                    CorrelationCard(stats: stats)
                }
            }.padding(24)
        }
    }

    private var riskPanelCard: some View {
        Panel(title: "Unified risk panel", icon: "shield.lefthalf.filled", accent: BLTheme.blue) {
            Text("Sharpe + Sortino + SQN + Kelly + streak Z-score in one view — risk math the leading journals don't bundle together. Computed over \(panel.sampleSize) closed trades.")
                .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                tile("Sharpe (per trade)", TradeMath.num(panel.sharpe), BLTheme.blue)
                tile("Sortino", TradeMath.num(panel.sortino), BLTheme.blue)
                tile("SQN", TradeMath.num(panel.sqn), sqnTint(panel.sqn))
                tile("Kelly fraction", TradeMath.pct(panel.kelly * 100), BLTheme.gold)
                tile("Half-Kelly (suggested)", TradeMath.pct(panel.halfKelly * 100), BLTheme.gold)
                tile("Streak Z-score", TradeMath.num(panel.streakZ), panel.streaksNonRandom ? BLTheme.red : BLTheme.green)
            }
            VStack(alignment: .leading, spacing: 4) {
                interp("SQN", sqnLabel(panel.sqn))
                interp("Kelly", "Full Kelly risks \(TradeMath.pct(panel.kelly*100)) of capital per trade for max growth — most traders use half-Kelly (\(TradeMath.pct(panel.halfKelly*100))) to cut volatility.")
                interp("Streaks", panel.streaksNonRandom
                       ? "|Z| > 1.96 — your win/loss runs are statistically non-random (\(panel.streakZ > 0 ? "streaky — outcomes cluster" : "choppy — outcomes alternate"))."
                       : "Within ±1.96 — your win/loss sequence is statistically indistinguishable from random.")
            }.padding(.top, 4)
        }
    }
    @ViewBuilder private func interp(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(k.uppercased()).font(.system(size: 9.5, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.gold).frame(width: 56, alignment: .leading)
            Text(v).font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func sqnTint(_ s: Double) -> Color { s >= 2.5 ? BLTheme.green : (s >= 1.6 ? BLTheme.gold : BLTheme.red) }
    private func sqnLabel(_ s: Double) -> String {
        if s >= 7 { return "Holy Grail (≥7) — exceptional, verify the sample." }
        if s >= 5 { return "Superb (5–7)." }; if s >= 3 { return "Excellent (3–5)." }
        if s >= 2.5 { return "Good (2.5–3)." }; if s >= 2 { return "Average (2–2.5)." }
        if s >= 1.6 { return "Below average (1.6–2)." }; return "Hard to trade (<1.6) — small/negative edge."
    }
    @ViewBuilder private func tile(_ l: String, _ v: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(l.uppercased()).font(.system(size: 9, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.5)
            Text(v).font(.system(size: 17, weight: .heavy, design: .rounded)).foregroundColor(tint).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(11).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// Calendar P&L heatmap — colored squares per day with trades.
struct CalendarHeatmapCard: View {
    let stats: [TradeStat]
    var body: some View {
        let daily = Analytics.dailyPnL(stats)
        let maxAbs = max(1, daily.map { abs($0.netPnL) }.max() ?? 1)
        Panel(title: "Calendar P&L", icon: "calendar") {
            if daily.isEmpty {
                Text("No dated results yet.").font(.system(size: 12, design: .rounded)).foregroundColor(BLTheme.sub)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                    ForEach(daily) { d in
                        let intensity = abs(d.netPnL) / maxAbs
                        let tint: Color = d.netPnL >= 0 ? BLTheme.green : BLTheme.red
                        VStack(spacing: 3) {
                            Text(d.day.formatted(.dateTime.month(.abbreviated).day())).font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                            Text((d.netPnL >= 0 ? "+" : "") + TradeMath.money(d.netPnL)).font(.system(size: 12, weight: .heavy, design: .rounded)).monospacedDigit().foregroundColor(tint)
                            Text("\(d.trades) trade\(d.trades == 1 ? "" : "s")").font(.system(size: 8.5, design: .rounded)).foregroundColor(BLTheme.sub)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(tint.opacity(0.10 + intensity * 0.32)).clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.4), lineWidth: 1))
                    }
                }
            }
        }
    }
}

struct TimeOfDayCard: View {
    let stats: [TradeStat]
    var body: some View {
        let hours = Analytics.byHour(stats).filter { $0.trades > 0 }
        Panel(title: "By hour of day", icon: "clock") {
            if hours.isEmpty { Text("No data.").font(.system(size: 12, design: .rounded)).foregroundColor(BLTheme.sub) }
            else {
                Chart(hours) { h in
                    BarMark(x: .value("Hour", "\(h.hour):00"), y: .value("P&L", h.netPnL))
                        .foregroundStyle(h.netPnL >= 0 ? BLTheme.green : BLTheme.red).cornerRadius(3)
                }
                .frame(height: 150)
                .chartXAxis { AxisMarks { v in AxisValueLabel { if let s = v.as(String.self) { Text(s).font(.system(size: 8)).foregroundStyle(BLTheme.sub) } } } }
                .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(BLTheme.stroke.opacity(0.4)); AxisValueLabel().foregroundStyle(BLTheme.sub) } }
            }
        }.frame(maxWidth: .infinity)
    }
}

struct WeekdayCard: View {
    let stats: [TradeStat]
    var body: some View {
        let days = Analytics.byWeekday(stats).filter { $0.trades > 0 }
        Panel(title: "By weekday", icon: "calendar.day.timeline.left") {
            if days.isEmpty { Text("No data.").font(.system(size: 12, design: .rounded)).foregroundColor(BLTheme.sub) }
            else {
                Chart(days) { d in
                    BarMark(x: .value("Day", d.name), y: .value("P&L", d.netPnL))
                        .foregroundStyle(d.netPnL >= 0 ? BLTheme.green : BLTheme.red).cornerRadius(3)
                }
                .frame(height: 150)
                .chartXAxis { AxisMarks { v in AxisValueLabel { if let s = v.as(String.self) { Text(s).font(.system(size: 9)).foregroundStyle(BLTheme.sub) } } } }
                .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(BLTheme.stroke.opacity(0.4)); AxisValueLabel().foregroundStyle(BLTheme.sub) } }
            }
        }.frame(maxWidth: .infinity)
    }
}

struct BySymbolCard: View {
    let stats: [TradeStat]
    var body: some View {
        let syms = Analytics.bySymbol(stats)
        Panel(title: "By symbol", icon: "character.cursor.ibeam") {
            ForEach(syms.prefix(8)) { s in
                HStack(spacing: 10) {
                    Text(s.symbol).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text).frame(width: 70, alignment: .leading)
                    Text("\(s.trades) · \(TradeMath.pct(s.winRate)) WR").font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub)
                    Spacer()
                    Text((s.netPnL >= 0 ? "+" : "") + TradeMath.money(s.netPnL)).font(.system(size: 13, weight: .heavy, design: .rounded)).monospacedDigit().foregroundColor(s.netPnL >= 0 ? BLTheme.green : BLTheme.red)
                }.padding(.vertical, 5)
            }
        }.frame(maxWidth: .infinity)
    }
}

struct ByTagCard: View {
    let stats: [TradeStat]
    var body: some View {
        let tags = Analytics.byTag(stats)
        Panel(title: "By tag (#hashtags in notes)", icon: "tag.fill") {
            if tags.isEmpty {
                Text("Add #tags in your trade notes (e.g. #breakout #fomo) to see setup and mistake performance here.")
                    .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(tags.prefix(10)) { t in
                    HStack(spacing: 10) {
                        Text("#\(t.tag)").font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.gold).frame(width: 100, alignment: .leading)
                        Text("\(t.trades) · \(TradeMath.pct(t.winRate)) · \(TradeMath.num(t.expectancyR))R").font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
                        Spacer()
                        Text((t.netPnL >= 0 ? "+" : "") + TradeMath.money(t.netPnL)).font(.system(size: 13, weight: .heavy, design: .rounded)).monospacedDigit().foregroundColor(t.netPnL >= 0 ? BLTheme.green : BLTheme.red)
                    }.padding(.vertical, 5)
                }
            }
        }.frame(maxWidth: .infinity)
    }
}

// Monthly seasonality — net P&L per calendar month over the user's own trades.
struct SeasonalityCard: View {
    let stats: [TradeStat]
    var body: some View {
        let months = Seasonality.byMonth(stats)
        let active = months.filter { $0.trades > 0 }
        Panel(title: "Seasonality (by month)", icon: "calendar.badge.clock", accent: BLTheme.gold) {
            if active.isEmpty {
                Text("Trades across more of the year will reveal monthly seasonality here.").font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub)
            } else {
                Chart(months) { m in
                    BarMark(x: .value("Month", m.name), y: .value("Net", m.netPnL))
                        .foregroundStyle(m.netPnL >= 0 ? BLTheme.green : BLTheme.red).cornerRadius(3)
                }
                .frame(height: 150)
                .chartXAxis { AxisMarks { v in AxisValueLabel { if let s = v.as(String.self) { Text(s).font(.system(size: 8.5)).foregroundStyle(BLTheme.sub) } } } }
                .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(BLTheme.stroke.opacity(0.4)); AxisValueLabel().foregroundStyle(BLTheme.sub) } }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                    ForEach(active) { m in
                        HStack(spacing: 6) {
                            Text(m.name).font(.system(size: 10.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.gold).frame(width: 30, alignment: .leading)
                            Text("\(m.trades) · \(TradeMath.pct(m.winRate))").font(.system(size: 9.5, design: .rounded)).foregroundColor(BLTheme.sub)
                            Spacer()
                            Text((m.netPnL >= 0 ? "+" : "") + TradeMath.money(m.netPnL)).font(.system(size: 11, weight: .heavy, design: .rounded)).monospacedDigit().foregroundColor(m.netPnL >= 0 ? BLTheme.green : BLTheme.red)
                        }.padding(.vertical, 5).padding(.horizontal, 9).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }
}

// Hold-time edge — are quick or slow trades more profitable? Needs close timestamps.
struct HoldTimeCard: View {
    let stats: [TradeStat]
    var body: some View {
        let buckets = Seasonality.byHoldTime(stats).filter { $0.trades > 0 }
        Panel(title: "Hold-time edge", icon: "timer", accent: BLTheme.blue) {
            if buckets.isEmpty {
                Text("Record close times on your trades (or import a broker CSV with open/close times) to see how hold duration affects your edge.")
                    .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            } else {
                Chart(buckets) { b in
                    BarMark(x: .value("Hold", b.label), y: .value("Net", b.netPnL))
                        .foregroundStyle(b.netPnL >= 0 ? BLTheme.green : BLTheme.red).cornerRadius(3)
                }
                .frame(height: 130)
                .chartXAxis { AxisMarks { v in AxisValueLabel { if let s = v.as(String.self) { Text(s).font(.system(size: 8.5)).foregroundStyle(BLTheme.sub) } } } }
                .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(BLTheme.stroke.opacity(0.4)); AxisValueLabel().foregroundStyle(BLTheme.sub) } }
                ForEach(buckets) { b in
                    HStack(spacing: 10) {
                        Text(b.label).font(.system(size: 11.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text).frame(width: 70, alignment: .leading)
                        Text("\(b.trades) · \(TradeMath.pct(b.winRate))").font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
                        Spacer()
                        Text((b.netPnL >= 0 ? "+" : "") + TradeMath.money(b.netPnL)).font(.system(size: 12, weight: .heavy, design: .rounded)).monospacedDigit().foregroundColor(b.netPnL >= 0 ? BLTheme.green : BLTheme.red)
                    }.padding(.vertical, 5).padding(.horizontal, 11).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

// Symbol correlation matrix — daily-P&L Pearson correlation across the user's symbols.
struct CorrelationCard: View {
    let stats: [TradeStat]
    var body: some View {
        let m = Correlation.symbolDailyMatrix(stats)
        Panel(title: "Symbol correlation (daily P&L)", icon: "square.grid.3x3.fill", accent: BLTheme.blue) {
            if m.symbols.count < 2 {
                Text("Trade at least two symbols on overlapping days to see how their daily P&L correlates — useful for spotting hidden concentration risk.")
                    .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Pearson correlation of per-day net P&L. +1 = move together (concentration risk), -1 = hedge, 0 = independent.")
                    .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                let n = m.symbols.count
                let cell: CGFloat = 54
                VStack(spacing: 3) {
                    HStack(spacing: 3) {
                        Text("").frame(width: cell, height: 22)
                        ForEach(m.symbols, id: \.self) { s in
                            Text(s).font(.system(size: 9.5, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.gold).frame(width: cell, height: 22)
                        }
                    }
                    ForEach(0..<n, id: \.self) { i in
                        HStack(spacing: 3) {
                            Text(m.symbols[i]).font(.system(size: 9.5, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.gold).frame(width: cell, height: cell, alignment: .center)
                            ForEach(0..<n, id: \.self) { j in
                                let v = m.values[i][j]
                                Text(String(format: "%.2f", v)).font(.system(size: 10.5, weight: .bold, design: .rounded)).monospacedDigit()
                                    .foregroundColor(abs(v) > 0.6 ? Color(hex: 0x1A1305) : BLTheme.text)
                                    .frame(width: cell, height: cell)
                                    .background(corrColor(v)).clipShape(RoundedRectangle(cornerRadius: 7))
                            }
                        }
                    }
                }
            }
        }
    }
    private func corrColor(_ v: Double) -> Color {
        if v >= 0 { return BLTheme.green.opacity(0.12 + min(0.6, v) * 0.6) }
        return BLTheme.red.opacity(0.12 + min(0.6, -v) * 0.6)
    }
}
