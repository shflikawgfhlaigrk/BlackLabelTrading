// Archived b26 autonomous-execution control panel. Not compiled or shipped by b27.
//
// HONEST FRAMING: this is the UI over the backend's dedicated /api/exec/* control plane. The app
// never places an order itself — it tells the backend ExecutionEngine to arm/disarm, choose paper
// vs live, trip the kill switch, and confirm orders. A LIVE order is structurally impossible unless
// the backend's fail-closed precheck passes (armed + live + your own broker creds + your firm's ToS
// permits automation + risk gates + a re-proven edge + kill clear + per-order confirm). Enabling
// LIVE requires a fresh on-device authentication (Touch ID / password) — not just being signed in.
import SwiftUI
import AppKit
import LocalAuthentication

struct ExecStatus: Equatable {
    var armed = false
    var mode = "paper"               // "paper" | "live"
    var kill = false
    var firm = ""
    var firmAck = false
    var broker = ""
    var brokerUser = ""
    var brokerAccount = ""
    var confirmEachOrder = true
    var liveAuthorized = false
    var openContractsES = 0
    var tradesToday = 0
    var dayRealizedLoss = 0.0
    var maxContracts = 0
    var accountSize = 0.0

    var isLive: Bool { mode == "live" }

    static func decode(_ o: [String: Any]) -> ExecStatus {
        var s = ExecStatus()
        s.armed = (o["armed"] as? Bool) ?? false
        s.mode = (o["mode"] as? String) ?? "paper"
        s.kill = (o["kill"] as? Bool) ?? false
        s.firm = (o["firm"] as? String) ?? ""
        s.firmAck = (o["firmAck"] as? Bool) ?? false
        s.broker = (o["broker"] as? String) ?? ""
        s.brokerUser = (o["brokerUser"] as? String) ?? ""
        s.brokerAccount = (o["brokerAccount"] as? String) ?? ""
        s.confirmEachOrder = (o["confirmEachOrder"] as? Bool) ?? true
        s.liveAuthorized = (o["liveAuthorized"] as? Bool) ?? false
        s.openContractsES = (o["openContractsES"] as? Int) ?? 0
        s.tradesToday = (o["tradesToday"] as? Int) ?? 0
        s.dayRealizedLoss = FeedBars.num(o["dayRealizedLoss"] as Any) ?? 0
        s.maxContracts = (o["maxContracts"] as? Int) ?? 0
        s.accountSize = FeedBars.num(o["accountSize"] as Any) ?? 0
        return s
    }
}

// Firms whose ToS permits supervised automation (mirrors backend bltd_exec.FIRM_AUTOMATION).
private let kAllowedFirms = ["topstep", "tradeify"]

struct ExecutionScreen: View {
    @EnvironmentObject var feed: FeedClient
    @State private var orders: [[String: Any]] = []
    @State private var note: String? = nil
    @State private var firmField = ""

    private var s: ExecStatus { feed.exec }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenTitle(title: "Execution",
                            subtitle: "Optional autonomous order execution — DEFAULT OFF, paper-first. A live order is placed only when you arm live + connect your own broker + your firm permits automation + every risk/edge/kill gate passes. The app routes to your own broker; nothing is bundled.",
                            icon: "bolt.shield.fill")

                killBanner
                armCard
                modeCard
                firmCard
                statusCard
                ordersCard
            }
            .padding(24).frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .task {
            await feed.refreshExec()
            firmField = feed.exec.firm
            if let o = await feedExecOrders() { orders = o }
        }
    }

    // KILL — always visible, the master halt.
    private var killBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: s.kill ? "exclamationmark.octagon.fill" : "bolt.shield")
                .foregroundColor(s.kill ? BLTheme.red : BLTheme.gold)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.kill ? "KILL ENGAGED — execution halted" : "Kill switch")
                    .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Text(s.kill ? "All execution is blocked and open positions are being flattened. Clear to resume."
                            : "One tap halts ALL execution and flattens open positions.")
                    .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
            }
            Spacer()
            if s.kill {
                GhostButton(label: "Clear kill", icon: "arrow.clockwise") {
                    Task { await feed.execCommand("clearkill"); note = "Kill cleared." }
                }
            } else {
                GoldButton(label: "KILL", icon: "octagon.fill") {
                    Task { await feed.execCommand("kill"); note = "Kill engaged — everything halted." }
                }
            }
        }
        .padding(14)
        .background((s.kill ? BLTheme.red : BLTheme.gold).opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke((s.kill ? BLTheme.red : BLTheme.gold).opacity(0.4)))
    }

    private var armCard: some View {
        Panel(title: "Arm", icon: s.armed ? "checkmark.seal.fill" : "seal") {
            HStack {
                Text(s.armed ? "ARMED — the engine may act (paper unless you switch to live)."
                             : "Disarmed (default). The engine does nothing; this is pure signals-only.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(s.armed ? BLTheme.green : BLTheme.sub)
                Spacer()
                GhostButton(label: s.armed ? "Disarm" : "Arm",
                            icon: s.armed ? "pause.fill" : "play.fill",
                            tint: s.armed ? BLTheme.red : BLTheme.green) {
                    Task { await feed.execCommand(s.armed ? "disarm" : "arm") }
                }
            }
        }
    }

    private var modeCard: some View {
        Panel(title: "Mode", icon: s.isLive ? "dollarsign.circle.fill" : "doc.text.magnifyingglass",
              accent: s.isLive ? BLTheme.red : BLTheme.gold) {
            Text(s.isLive ? "LIVE — real broker orders move real money."
                          : "PAPER — simulated fills, no broker contact, no money at risk (default).")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(s.isLive ? BLTheme.red : BLTheme.green)
            HStack(spacing: 8) {
                GhostButton(label: "Paper", icon: "doc.text") {
                    Task { await feed.execCommand("mode", ["mode": "paper"]) }
                }
                GoldButton(label: "Go LIVE…", icon: "lock.open.fill") { enableLive() }
            }
            Text("Going live requires a fresh device authentication (Touch ID / password), your own broker credentials, and a firm that permits automation. Validate on a DEMO/eval account first.")
                .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var firmCard: some View {
        Panel(title: "Prop firm (automation permission)", icon: "building.columns.fill") {
            Text(s.firmAck && kAllowedFirms.contains(s.firm)
                 ? "Firm '\(s.firm)' — automation acknowledged."
                 : "Set the firm whose account you'll trade. Only firms whose ToS permits supervised automation can ever go live.")
                .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Field(title: "Firm (e.g. topstep)", text: $firmField)
                GhostButton(label: "Acknowledge & set", icon: "checkmark") {
                    let f = firmField.trimmingCharacters(in: .whitespaces).lowercased()
                    Task { await feed.execCommand("firm", ["firm": f, "ack": true]) }
                }
            }
            if !firmField.isEmpty && !kAllowedFirms.contains(firmField.trimmingCharacters(in: .whitespaces).lowercased()) {
                Text("‘\(firmField)’ is not on the automation-permitted list — it can never reach live execution (firms that ban bots are blocked).")
                    .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.red)
            }
        }
    }

    private var statusCard: some View {
        Panel(title: "Status & risk", icon: "gauge.with.dots.needle.67percent") {
            HStack(spacing: 14) {
                stat("State", s.kill ? "KILL" : (s.armed ? (s.isLive ? "ARMED·LIVE" : "ARMED·PAPER") : "OFF"),
                     s.kill ? BLTheme.red : (s.armed ? (s.isLive ? BLTheme.red : BLTheme.green) : BLTheme.sub))
                stat("Device auth", s.liveAuthorized ? "fresh" : "none", s.liveAuthorized ? BLTheme.green : BLTheme.sub)
                stat("Open (ES)", "\(s.openContractsES)\(s.maxContracts > 0 ? "/\(s.maxContracts)" : "")", BLTheme.text)
                stat("Trades today", "\(s.tradesToday)", BLTheme.text)
                stat("Day loss", TradeMath.money(s.dayRealizedLoss), s.dayRealizedLoss > 0 ? BLTheme.red : BLTheme.sub)
            }
            if let n = note {
                Text(n).font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.gold)
            }
        }
    }

    private var ordersCard: some View {
        Panel(title: "Execution log", icon: "list.bullet.rectangle") {
            if orders.isEmpty {
                EmptyState(icon: "tray", title: "No execution activity",
                           hint: "When armed, every decision (placed or blocked, with the reason) is logged here. Paper fills are labeled simulated.")
            } else {
                ForEach(Array(orders.prefix(20).enumerated()), id: \.offset) { _, o in
                    HStack {
                        Text("\(o["symbol"] as? String ?? "—") \(o["direction"] as? String ?? "")")
                            .font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                        Text((o["route"] as? String ?? "").uppercased())
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor((o["route"] as? String) == "live" ? BLTheme.red : ((o["route"] as? String) == "paper" ? BLTheme.green : BLTheme.sub))
                        Spacer()
                        Text(o["reason"] as? String ?? o["status"] as? String ?? "")
                            .font(.system(size: 10, design: .rounded)).foregroundColor(BLTheme.sub)
                            .lineLimit(1).truncationMode(.tail)
                    }.padding(.vertical, 1)
                }
            }
        }
    }

    private func stat(_ l: String, _ v: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(l).font(.system(size: 9, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.4)
            Text(v).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(tint)
        }
    }

    // Going live: require a FRESH on-device authentication, then tell the backend (osAuth:true). The
    // backend records a short capability window; without this the backend refuses live mode.
    private func enableLive() {
        let f = s.firm.isEmpty ? firmField.trimmingCharacters(in: .whitespaces).lowercased() : s.firm
        guard kAllowedFirms.contains(f), s.firmAck else {
            note = "Set an automation-permitted firm and acknowledge it before going live."
            return
        }
        let ctx = LAContext()
        var err: NSError?
        let reason = "Enable LIVE autonomous execution (real money) for Black Label Trading"
        if ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) {
            ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
                DispatchQueue.main.async {
                    guard ok else { note = "Live enable cancelled — device authentication failed."; return }
                    Task { await feed.execCommand("mode", ["mode": "live", "osAuth": true])
                           note = "LIVE armed. Per-order confirmation is on; validate on a demo account first." }
                }
            }
        } else {
            note = "This Mac can't perform device authentication; live execution stays disabled."
        }
    }

    private func feedExecOrders() async -> [[String: Any]]? {
        await feed.execOrders()
    }
}
