// Black Label Trading — no-creds webhook feed connection ("Connect a feed" UI).
//
// WHY: a buyer on a prop account should not need a broker API key or stored platform credentials.
// The bundled browser bridge posts observed ticks or OHLC bars into the local webhook receiver.
// The local backend stores only pushed real bars/ticks. Signals-only: a feed is read-only market
// data; nothing here can place an order or move money. Every status shown is the backend's REAL,
// observed state — never a fake "connected".
import SwiftUI
import Foundation
import AppKit

// MARK: - Prerequisite sentinel (written by launch-backend.sh when a host dependency is missing,
// e.g. no working python3). The app reads it to show an honest, actionable state instead of a
// silent "offline" — never a dead-end. Ship-no-data: this is created at runtime on the buyer's Mac.
struct PrereqInfo: Equatable {
    let reason: String
    let fix: String
    let detail: String

    static func read() -> PrereqInfo? {
        let base = NSString(string: "~/Library/Application Support/Black Label Trading/prereq.json").expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: base),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (o["ok"] as? Bool) == false else { return nil }
        return PrereqInfo(reason: (o["reason"] as? String) ?? "A required runtime is missing.",
                          fix: (o["fix"] as? String) ?? "",
                          detail: (o["detail"] as? String) ?? "")
    }
}

// MARK: - Catalogue models (decoded from GET /api/feed/sources)

struct FeedCredField: Identifiable, Equatable {
    let name: String
    let label: String
    let secret: Bool
    let optional: Bool
    let defaultValue: String
    let placeholder: String
    var id: String { name }

    static func decode(_ o: [String: Any]) -> FeedCredField? {
        guard let name = o["name"] as? String, !name.isEmpty else { return nil }
        return FeedCredField(
            name: name,
            label: (o["label"] as? String) ?? name,
            secret: (o["secret"] as? Bool) ?? false,
            optional: (o["optional"] as? Bool) ?? false,
            defaultValue: (o["default"] as? String) ?? "",
            placeholder: (o["placeholder"] as? String) ?? "")
    }
}

struct FeedSourceInfo: Identifiable, Equatable {
    let key: String
    let label: String
    let kind: String            // surfaced build uses "webhook"
    let credFields: [FeedCredField]
    let note: String
    var id: String { key }
    var isWebhook: Bool { kind == "webhook" }
    var isBrowser: Bool { kind == "browser" }
    var isUnavailable: Bool { kind == "unavailable" }

    static func decode(_ o: [String: Any]) -> FeedSourceInfo? {
        guard let key = o["key"] as? String, !key.isEmpty else { return nil }
        let fields = ((o["credFields"] as? [[String: Any]]) ?? []).compactMap(FeedCredField.decode)
        return FeedSourceInfo(key: key, label: (o["label"] as? String) ?? key,
                              kind: (o["kind"] as? String) ?? "api",
                              credFields: fields, note: (o["note"] as? String) ?? "")
    }

    static func decodeList(_ obj: [String: Any]) -> [FeedSourceInfo] {
        ((obj["sources"] as? [[String: Any]]) ?? []).compactMap(FeedSourceInfo.decode)
    }
}

// MARK: - Connection status (decoded from /api/feed/status & /api/feed/connect)

struct ApiFeedStatus: Equatable {
    var source: String? = nil
    var label: String? = nil
    var state: String = "disconnected"   // disconnected|live|idle|webhook|error|browser|unavailable
    var detail: String = ""
    var symbol: String? = nil
    var lastTickAge: Double? = nil

    static func decode(_ o: [String: Any]) -> ApiFeedStatus {
        var s = ApiFeedStatus()
        s.source = o["source"] as? String
        s.label = o["label"] as? String
        s.state = (o["state"] as? String) ?? "disconnected"
        s.detail = (o["detail"] as? String) ?? ""
        s.symbol = o["symbol"] as? String
        s.lastTickAge = (o["lastTickAge"] as? Double) ?? (o["lastTickAge"] as? NSNumber)?.doubleValue
        return s
    }

    var isLive: Bool { state == "live" }
    var tint: Color {
        switch state {
        case "live": return BLTheme.green
        case "idle", "connecting", "authenticating": return BLTheme.gold
        case "needs_setup", "browser", "webhook": return BLTheme.gold
        case "unavailable": return BLTheme.red
        case "auth_error", "error": return BLTheme.red
        default: return BLTheme.sub
        }
    }
    var headline: String {
        switch state {
        case "live": return "Live feed"
        case "idle": return "Connected · quiet"
        case "connecting": return "Connecting…"
        case "authenticating": return "Authenticating…"
        case "auth_error": return "Credentials rejected"
        case "error": return "Connection error"
        case "needs_setup": return "Setup required"
        case "webhook": return "Webhook ready"
        case "browser": return "Use the capture window"
        case "unavailable": return "Unavailable"
        default: return "Not connected"
        }
    }
}

struct WebhookInfo: Equatable {
    var endpoint = ""
    var header = ""
    var curl = ""
    var example = ""
    var url: String { endpoint }
    var token: String {
        let prefix = "Authorization: Bearer "
        return header.hasPrefix(prefix) ? String(header.dropFirst(prefix.count)) : header
    }

    static func decode(_ o: [String: Any]) -> WebhookInfo {
        var w = WebhookInfo()
        w.endpoint = (o["endpoint"] as? String) ?? ""
        w.header = (o["header"] as? String) ?? ""
        w.curl = (o["curl"] as? String) ?? ""
        if let ex = o["example"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: ex, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            w.example = s
        }
        return w
    }
}

// MARK: - Per-source local state - macOS Keychain ONLY (this device).
// Webhook ingestion does not need prop-firm credentials. This store remains for migration/legacy
// cleanup and for remembering the non-secret last-selected source key so the picker opens where the buyer left it.
enum FeedCredStore {
    private static let service = "com.blacklabel.trading.feedcreds"
    static let lastSourceKey = "com.blacklabel.trading.feed.lastSource"

    // Base query (class + service + account) — TradingKeychain adds storage-location/return keys.
    private static func base(_ source: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: source
        ]
    }

    static func save(source: String, creds: [String: String]) {
        delete(source: source)
        guard let data = try? JSONSerialization.data(withJSONObject: creds) else { return }
        TradingKeychain.set(base(source), data: data)
        UserDefaults.standard.set(source, forKey: lastSourceKey)
    }

    static func load(source: String) -> [String: String] {
        guard let data = TradingKeychain.copy(base(source)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return obj
    }

    static func hasCreds(source: String) -> Bool { !load(source: source).isEmpty }

    static func delete(source: String) {
        TradingKeychain.delete(base(source))
    }

    static var lastSource: String? { UserDefaults.standard.string(forKey: lastSourceKey) }
}

// MARK: - Launch-time reconnect. Webhook ingestion has no credential replay path: the receiver
// waits for the buyer's sender/bridge to post ticks or bars.
@MainActor
enum FeedReconnect {
    static func reconnectSaved(_ feed: FeedClient) async {
        await feed.refreshStatus()
    }
}

// MARK: - "Connect a feed" screen

struct ConnectFeedScreen: View {
    @EnvironmentObject var feed: FeedClient
    @State private var sources: [FeedSourceInfo] = []
    @State private var selected: String = FeedCredStore.lastSource ?? "wealthcharts"
    @State private var inputs: [String: String] = [:]
    @State private var status = ApiFeedStatus()
    @State private var webhook = WebhookInfo()
    @State private var busy = false
    @State private var loaded = false

    private var current: FeedSourceInfo? { sources.first { $0.key == selected } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenTitle(title: "Connect a feed",
                            subtitle: "Use the bundled browser bridge and local webhook URL to capture your own TopstepX or WealthCharts chart data. No API key is requested; sign into your own session in the app-owned browser and the bridge posts observed bars into this Mac.",
                            icon: "antenna.radiowaves.left.and.right")

                if let pre = feed.prereq {
                    Panel(title: "One-time setup required", icon: "exclamationmark.triangle.fill", accent: BLTheme.gold) {
                        Text(pre.reason).font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(BLTheme.text).fixedSize(horizontal: false, vertical: true)
                        if !pre.detail.isEmpty {
                            Text(pre.detail).font(.system(size: 11.5, design: .rounded))
                                .foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                        }
                        if !pre.fix.isEmpty {
                            Stat(label: "Run in Terminal", value: pre.fix)
                            GhostButton(label: "Copy command", icon: "doc.on.doc") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(pre.fix, forType: .string)
                            }
                        }
                        GhostButton(label: "Retry", icon: "arrow.clockwise") {
                            Task { feed.prereq = nil; await initialLoad() }
                        }
                    }
                }
                if sources.isEmpty {
                    VStack(alignment: .center, spacing: 12) {
                        EmptyState(icon: "bolt.horizontal.circle",
                                   title: "Connecting to the local backend…",
                                   hint: "Black Label Trading runs its own data backend on this Mac. If this persists, retry the local connection.")
                        GoldButton(label: feed.connecting ? "Retrying…" : "Retry connection",
                                   icon: "arrow.clockwise") {
                            Task { await loadSources(forceSignIn: true) }
                        }
                        .disabled(feed.connecting)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    sourcePicker
                    if let src = current { credentialCard(src) }
                    statusCard
                }
            }
            .padding(24).frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .task { await initialLoad() }
    }

    // Source chips exposed by the backend catalogue.
    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DATA SOURCE").font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(BLTheme.sub).tracking(0.6)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(sources) { s in
                    SourceChip(info: s, selected: selected == s.key,
                               hasCreds: FeedCredStore.hasCreds(source: s.key)) {
                        selected = s.key
                        inputs = mergedInputs(for: s)
                        Task { await refresh() }
                    }
                }
            }
        }
    }

    private func credentialCard(_ src: FeedSourceInfo) -> some View {
        Panel(title: src.label, icon: src.isWebhook ? "arrow.down.doc.fill" : (src.isBrowser ? "globe" : (src.isUnavailable ? "nosign" : "key.fill")),
              accent: status.source == src.key ? status.tint : BLTheme.gold) {
            if !src.note.isEmpty {
                Text(src.note).font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }
            if src.isUnavailable {
                Text("No credentials are requested for this build.")
                    .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            } else if src.isWebhook {
                Text("The bundled browser bridge opens your selected platform in a product-owned browser profile and posts observed market data to the local webhook/store. The webhook URL and curl below are copyable for inspection or a custom sender; your platform password is never stored.")
                    .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                webhookLine("Webhook URL", webhook.url)
                webhookLine("Token", webhook.token.isEmpty ? "local backend has not reported a token yet" : webhook.token)
                HStack(spacing: 8) {
                    GoldButton(label: busy ? "Opening your platform…" : "Connect — open my platform", icon: "globe") {
                        Task {
                            busy = true
                            _ = await feed.ensureBackendRunning()
                            await feed.launchCapture(source: selected)
                            if let st = await feed.feedStatus() { status = st }
                            await feed.refreshStatus()
                            busy = false
                        }
                    }
                    GhostButton(label: "Copy curl", icon: "doc.on.doc") { Task { if let w = await feed.webhookInfo() { copy(w.curl) } } }
                    GhostButton(label: "Refresh", icon: "arrow.clockwise") { Task { await refresh() } }
                }
            } else if src.isBrowser {
                Text("Selecting \(src.label) opens it in the capture browser. Sign in and the app reads the same live market data feeding your charts and posts those bars into the local backend — no broker API key, no stored platform credentials.")
                    .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    GoldButton(label: busy ? "Opening…" : "Open \(src.label)", icon: "globe") {
                        Task { await connect(src) }
                    }
                    GhostButton(label: "Refresh", icon: "arrow.clockwise") { Task { await refresh() } }
                }
            } else {
                Text("This build uses webhook ingestion only.")
                    .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func webhookLine(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(BLTheme.sub).tracking(0.6)
            Text(value)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundColor(BLTheme.text)
                .textSelection(.enabled)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8).padding(.horizontal, 10)
                .background(BLTheme.bg2)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(BLTheme.stroke, lineWidth: 1))
        }
    }

    private var statusCard: some View {
        Panel(title: "Feed status", icon: "dot.radiowaves.left.and.right", accent: status.tint) {
            HStack(spacing: 10) {
                Circle().fill(status.tint).frame(width: 9, height: 9)
                    .shadow(color: status.tint.opacity(0.7), radius: status.isLive ? 5 : 0)
                Text(status.headline).font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(BLTheme.text)
                Spacer()
                StatusPill(text: status.state, tint: status.tint)
            }
            if let sym = status.symbol {
                Stat(label: "Instrument", value: sym)
            }
            if let age = status.lastTickAge {
                Stat(label: "Last tick", value: age < 1 ? "just now" : "\(Int(age))s ago")
            }
            if !status.detail.isEmpty {
                Text(status.detail).font(.system(size: 11.5, design: .rounded))
                    .foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                GhostButton(label: "Refresh", icon: "arrow.clockwise") { Task { await refresh() } }
                Spacer()
            }.padding(.top, 2)
        }
    }

    // MARK: - actions
    private func initialLoad() async {
        if loaded {
            if sources.isEmpty { await loadSources(forceSignIn: true) }
            await refresh()
            return
        }
        loaded = true
        await loadSources(forceSignIn: true)
        await refresh()
    }

    private func loadSources(forceSignIn: Bool = false) async {
        for attempt in 0..<5 {
            _ = await feed.ensureBackendRunning()
            if forceSignIn || feed.state == .offline || feed.state == .notSignedIn {
                await feed.connect(email: "local@blacklabel")
            }
            let loadedSources = await feed.feedSources()
            if !loadedSources.isEmpty {
                sources = loadedSources
                webhook = await feed.webhookInfo() ?? WebhookInfo()
                if !sources.contains(where: { $0.key == selected }) { selected = sources.first?.key ?? selected }
                if let src = current { inputs = mergedInputs(for: src) }
                return
            }
            let delay = UInt64(300_000_000 * (attempt + 1))
            try? await Task.sleep(nanoseconds: delay)
        }
        webhook = await feed.webhookInfo() ?? webhook
        if !sources.contains(where: { $0.key == selected }) { selected = sources.first?.key ?? selected }
        if let src = current { inputs = mergedInputs(for: src) }
    }

    private func mergedInputs(for src: FeedSourceInfo) -> [String: String] {
        var merged = FeedCredStore.load(source: src.key)
        for f in src.credFields where (merged[f.name] ?? "").isEmpty && !f.defaultValue.isEmpty {
            merged[f.name] = f.defaultValue
        }
        return merged
    }

    private func connect(_ src: FeedSourceInfo) async {
        busy = true; defer { busy = false }
        if src.isBrowser {
            // Browser platforms: open the selected capture browser login tab and surface the no-Chrome
            // prerequisite if needed. The buyer signs into THEIR platform there; bars then flow.
            if let st = await feed.connectFeed(source: src.key, creds: [:]) { status = st }
            await feed.launchCapture(source: src.key)
            if let st = await feed.feedStatus() { status = st }
            await feed.refreshStatus()
            return
        }
        // Webhook/other: persist to Keychain first (so a later backend restart can re-authenticate).
        let creds = inputs.filter { !$0.value.isEmpty }
        FeedCredStore.save(source: src.key, creds: creds)
        if let st = await feed.connectFeed(source: src.key, creds: creds) { status = st }
        await feed.refreshStatus()
    }

    private func disconnect(_ src: FeedSourceInfo) async {
        busy = true; defer { busy = false }
        await feed.disconnectFeed()
        FeedCredStore.delete(source: src.key)
        inputs = [:]
        await refresh()
    }

    private func refresh() async {
        if let st = await feed.feedStatus() { status = st }
    }

    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct SourceChip: View {
    let info: FeedSourceInfo
    let selected: Bool
    let hasCreds: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: info.isWebhook ? "arrow.down.doc.fill" : (info.isBrowser ? "globe" : (info.isUnavailable ? "nosign" : "key.fill")))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(selected ? Color(hex: 0x1A1305) : BLTheme.gold)
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.label).font(.system(size: 12.5, weight: .bold, design: .rounded))
                        .foregroundColor(selected ? Color(hex: 0x1A1305) : BLTheme.text)
                    Text(info.isUnavailable ? "Unavailable" : (hasCreds ? "Saved" : (info.isWebhook ? "Webhook" : (info.isBrowser ? "Browser" : "No creds"))))
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundColor(selected ? Color(hex: 0x1A1305).opacity(0.7) : BLTheme.sub)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10).padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AnyView(BLTheme.goldGrad) : AnyView(BLTheme.bg2))
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11)
                .stroke(selected ? Color.clear : BLTheme.stroke.opacity(hover ? 0.8 : 0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

// One credential input — SecureField for secrets, TextField otherwise. Honest label + optional hint.
private struct CredInput: View {
    let field: FeedCredField
    @Binding var text: String
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(field.label.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(BLTheme.sub).tracking(0.6)
                if field.optional {
                    Text("optional").font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundColor(BLTheme.sub.opacity(0.7))
                }
                if field.secret {
                    Image(systemName: "lock.fill").font(.system(size: 8)).foregroundColor(BLTheme.gold.opacity(0.8))
                }
            }
            Group {
                if field.secret {
                    SecureField(field.placeholder.isEmpty ? field.label : field.placeholder, text: $text)
                } else {
                    TextField(field.placeholder.isEmpty ? field.label : field.placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain).font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundColor(BLTheme.text).focused($focused)
            .padding(.vertical, 10).padding(.horizontal, 12)
            .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(focused ? BLTheme.gold.opacity(0.7) : BLTheme.stroke, lineWidth: focused ? 1.5 : 1))
            .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}
