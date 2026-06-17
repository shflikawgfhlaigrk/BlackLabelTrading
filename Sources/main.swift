import SwiftUI
import AppKit

enum Section: String, CaseIterable, Identifiable {
    case signals = "Signals", journal = "Journal", calculators = "Calculators", firms = "Prop Firms", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self { case .signals: return "dot.radiowaves.left.and.right"; case .journal: return "list.bullet.rectangle.fill"
        case .calculators: return "function"; case .firms: return "building.columns.fill"; case .settings: return "gearshape.fill" }
    }
}

struct SidebarRow: View {
    let section: Section; let selected: Bool
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: section.icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(selected ? Color(hex: 0x1A1305) : BLTheme.gold)
                .frame(width: 26, height: 26)
                .background(selected ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.gold.opacity(0.12)))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(section.rawValue)
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .foregroundColor(selected ? BLTheme.text : BLTheme.sub)
            Spacer()
        }
        .padding(.vertical, 3)
    }
}

struct MainView: View {
    @State private var sel: Section? = .signals
    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $sel) { s in
                SidebarRow(section: s, selected: sel == s).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 225, max: 270)
            .scrollContentBackground(.hidden)
            .background(BLTheme.bg2)
            .safeAreaInset(edge: .top) {
                HStack(spacing: 11) { Logo(size: 36)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Black Label").font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundStyle(BLTheme.goldGrad)
                        Text("Trading").font(.system(size: 10.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                .background(BLTheme.bg2)
            }
            .tint(BLTheme.gold)
        } detail: {
            ZStack {
                LinearGradient(colors: [Color(hex: 0x101012), BLTheme.bg], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
                Group {
                    switch sel ?? .signals {
                    case .signals: SignalsScreen()
                    case .journal: JournalScreen()
                    case .calculators: CalculatorsScreen()
                    case .firms: FirmsScreen()
                    case .settings: SettingsScreen()
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
                .id(sel)
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: sel)
        }
        .frame(minWidth: 980, minHeight: 680)
    }
}

struct RootView: View {
    @StateObject var session = Session()
    @StateObject var model = AppModel()
    var body: some View {
        Group { if session.signedIn { MainView() } else { AuthView() } }
            .environmentObject(session).environmentObject(model).preferredColorScheme(.dark)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        if let img = BLTheme.icon() { NSApp.applicationIconImage = img }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Black Label Trading"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(BLTheme.bg)
        window.contentView = NSHostingView(rootView: RootView())
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
