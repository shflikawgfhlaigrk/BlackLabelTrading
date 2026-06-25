import SwiftUI
import AppKit

enum Section: String, CaseIterable, Identifiable {
    case signals = "Signals", chart = "Chart", grid = "Grid", watchlists = "Watchlists", screener = "Screener", alerts = "Alerts"
    case backtest = "Backtest", builder = "Strategy Builder", patterns = "Patterns", replay = "Replay", paper = "Paper Trade"
    case journal = "Journal", analytics = "Analytics"
    case calculators = "Calculators", firms = "Prop Firms", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .signals:     return "dot.radiowaves.left.and.right"
        case .chart:       return "chart.xyaxis.line"
        case .grid:        return "square.grid.2x2.fill"
        case .watchlists:  return "star.fill"
        case .screener:    return "line.3.horizontal.decrease.circle.fill"
        case .alerts:      return "bell.badge.fill"
        case .backtest:    return "clock.arrow.circlepath"
        case .builder:     return "wand.and.stars"
        case .patterns:    return "waveform.path.ecg.rectangle.fill"
        case .replay:      return "play.rectangle.on.rectangle.fill"
        case .paper:       return "doc.text.magnifyingglass"
        case .journal:     return "list.bullet.rectangle.fill"
        case .analytics:   return "chart.bar.xaxis"
        case .calculators: return "function"
        case .firms:       return "building.columns.fill"
        case .settings:    return "gearshape.fill"
        }
    }
    // Sidebar grouping for a cleaner information architecture.
    var group: String {
        switch self {
        case .signals, .chart, .grid, .watchlists, .screener, .alerts:  return "Markets"
        case .backtest, .builder, .patterns, .replay, .paper, .journal, .analytics: return "Research"
        case .calculators, .firms, .settings:                           return "Tools"
        }
    }
    static let groups = ["Markets", "Research", "Tools"]
}

struct SidebarRow: View {
    let section: Section; let selected: Bool; var badge: Int? = nil
    @Environment(\.holoTheme) private var theme
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: section.icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(selected ? Color(hex: 0x1A1305) : theme.accent)
                .frame(width: 26, height: 26)
                .background(selected ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(theme.accent.opacity(0.12)))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(section.rawValue)
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .foregroundColor(selected ? BLTheme.text : BLTheme.sub)
            Spacer()
            if let b = badge {
                Text("\(b)").font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundColor(Color(hex: 0x1A1305))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(BLTheme.goldGrad).clipShape(Capsule())
            }
        }
        .padding(.vertical, 3)
        // Selected row gets an iridescent rim + soft glow — the holographic nav feel.
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? theme.accent.opacity(0.07) : .clear)
        )
        .overlay(selected ? AnyView(RoundedRectangle(cornerRadius: 9, style: .continuous).iridescentBorder(radius: 9, lineWidth: 1.2)) : AnyView(EmptyView()))
        .listRowBackground(Color.clear)
    }
}

// App-wide navigation state so the command palette + deep actions can switch screens.
final class Nav: ObservableObject {
    @Published var section: Section = .signals
    @Published var showPalette = false
}

struct MainView: View {
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var alerts: AlertStore
    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { nav.section }, set: { if let v = $0 { nav.section = v } })) {
                ForEach(Section.groups, id: \.self) { grp in
                    SwiftUI.Section {
                        ForEach(Section.allCases.filter { $0.group == grp }) { s in
                            SidebarRow(section: s, selected: nav.section == s,
                                       badge: s == .alerts && alerts.activeCount > 0 ? alerts.activeCount : nil).tag(s)
                        }
                    } header: {
                        Text(grp.uppercased()).font(.system(size: 9.5, weight: .heavy, design: .rounded))
                            .foregroundColor(BLTheme.sub).tracking(1.2)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
            .scrollContentBackground(.hidden)
            .background(BLTheme.bg2)
            .safeAreaInset(edge: .top) {
                VStack(spacing: 10) {
                    HStack(spacing: 11) { Logo(size: 36).holoSheen()
                        VStack(alignment: .leading, spacing: 0) {
                            FoilText("Black Label", size: 15, weight: .heavy, serif: false)
                            Text("Trading").font(.system(size: 10.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(2)
                        }
                        Spacer()
                    }
                    // Command palette launcher (⌘K).
                    Button { nav.showPalette = true } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .bold))
                            Text("Search…").font(.system(size: 12, weight: .medium, design: .rounded))
                            Spacer()
                            Text("⌘K").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                        }
                        .foregroundColor(BLTheme.sub).padding(.vertical, 8).padding(.horizontal, 11)
                        .background(BLTheme.bg).clipShape(RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.stroke, lineWidth: 1))
                    }.buttonStyle(.plain)
                }
                .padding(14).background(BLTheme.bg2)
            }
            .tint(BLTheme.gold)
        } detail: {
            ZStack {
                // Living holographic background, app-wide (Aurora / Starfield / Solid per theme).
                AuroraBackdrop()
                Group {
                    switch nav.section {
                    case .signals:     SignalsScreen()
                    case .chart:       ChartScreen()
                    case .grid:        GridScreen()
                    case .watchlists:  WatchlistsScreen()
                    case .screener:    ScreenerScreen()
                    case .alerts:      AlertsScreen()
                    case .backtest:    BacktestScreen()
                    case .builder:     StrategyBuilderScreen()
                    case .patterns:    PatternsScreen()
                    case .replay:      ReplayScreen()
                    case .paper:       PaperTradeScreen()
                    case .journal:     JournalScreen()
                    case .analytics:   AnalyticsScreen()
                    case .calculators: CalculatorsScreen()
                    case .firms:       FirmsScreen()
                    case .settings:    SettingsScreen()
                    }
                }
                .transition(.holoScreen)
                .id(nav.section)
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: nav.section)
        }
        .frame(minWidth: 1040, minHeight: 700)
        // ⌘K command palette overlay.
        .overlay { if nav.showPalette { CommandPalette().transition(.opacity) } }
        .background(KeyCatcher { ev in
            if ev.modifierFlags.contains(.command), ev.charactersIgnoringModifiers == "k" {
                nav.showPalette.toggle(); return nil
            }
            if ev.keyCode == 53, nav.showPalette { nav.showPalette = false; return nil }  // Esc
            return ev
        })
    }
}

struct RootView: View {
    @StateObject var session = Session()
    @StateObject var model = AppModel()
    @StateObject var wc = WealthChartsStore()
    @StateObject var watch = WatchlistStore()
    @StateObject var alerts = AlertStore()
    @StateObject var nav = Nav()
    @StateObject var drawings = DrawingStore()
    @StateObject var strategies = StrategyStore()
    @StateObject var paper = PaperBook()
    @StateObject var holo = HoloThemeController()
    @StateObject var feed = FeedClient()
    var body: some View {
        Group { if session.signedIn { MainView() } else { AuthView() } }
            .environmentObject(session).environmentObject(model).environmentObject(wc)
            .environmentObject(watch).environmentObject(alerts).environmentObject(nav).environmentObject(drawings)
            .environmentObject(strategies).environmentObject(paper).environmentObject(holo).environmentObject(feed)
            // Inject the live HoloTheme + the effective motion gate (toggle AND not Reduce Motion)
            // so every FX component app-wide re-skins instantly when the Theme Studio changes.
            .holoEnvironment(holo)
            .preferredColorScheme(.dark)
            .onAppear { NotificationCenterBridge.configure(alerts) }
            // On sign-in, hand the buyer's session email to the own backend so the live feed
            // banner reflects REAL capture state (never a fabricated "connected").
            .onChange(of: session.signedIn) { signedIn in
                if signedIn { Task { await feed.connect(email: session.email) } }
            }
    }
}

// Local key monitor so ⌘K / Esc work app-wide without a menu. Returns the event to pass it
// through, or nil to swallow it.
struct KeyCatcher: NSViewRepresentable {
    let handler: (NSEvent) -> NSEvent?
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in handler(ev) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let m = coordinator.monitor { NSEvent.removeMonitor(m) }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var monitor: Any? }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        if let img = BLTheme.icon() { NSApp.applicationIconImage = img }
        // Height 860 so the login panel (logo + title + social + email/pw + guest, ~760pt tall)
        // fits fully WITHOUT the bottom "Continue as guest" control spilling past the window's
        // hittable bounds (the dead-button bug). The AuthView also wraps the panel in a ScrollView
        // as a belt-and-suspenders safety net for very short screens.
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 860),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Black Label Trading"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(BLTheme.bg)
        window.contentView = NSHostingView(rootView: RootView())
        // Open LARGE and reliably ON-SCREEN: set the frame to the screen's visibleFrame (fills the
        // usable screen like a real trading terminal). Using visibleFrame directly avoids the
        // off-bottom positioning the centered-92% math produced on the built-in display.
        if let vis = NSScreen.main?.visibleFrame {
            window.setFrame(vis, display: true)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
