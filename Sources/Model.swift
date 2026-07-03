// Black Label Trading — backend: domain models, persistence, auth, and trading math.
// Standalone. No network, no external deps. App Sandbox-safe (writes to the app container).
import Foundation
import CryptoKit
import SwiftUI

// MARK: - Domain models
enum TradeDirection: String, Codable, CaseIterable, Identifiable {
    case long, short
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var tint: Color { self == .long ? BLTheme.green : BLTheme.red }
    var icon: String { self == .long ? "arrow.up.right" : "arrow.down.right" }
}

enum TradeResult: String, Codable, CaseIterable, Identifiable {
    case open, win, loss
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var tint: Color {
        switch self { case .open: return BLTheme.gold; case .win: return BLTheme.green; case .loss: return BLTheme.red }
    }
}

struct Trade: Identifiable, Codable, Hashable {
    var id = UUID()
    var symbol: String = ""
    var direction: TradeDirection = .long
    var entry: Double = 0
    var stop: Double = 0
    var target: Double = 0
    var size: Double = 0
    var result: TradeResult = .open
    var pnl: Double = 0
    var notes: String = ""
    var created = Date()
    // Journal depth fields (optional — default 0/[] so older saved data still decodes).
    var exit: Double = 0                 // realized exit/fill price (0 = unset)
    var closed: Date? = nil              // exit timestamp (for hold-time)
    var maeR: Double = 0                 // max adverse excursion in R (>= 0; 0 = unknown)
    var mfeR: Double = 0                 // max favorable excursion in R (>= 0; 0 = unknown)
    var tags: [String] = []             // explicit setup/mistake/emotion tags

    // Hold time in minutes (only when both timestamps exist).
    var holdMinutes: Double {
        guard let c = closed else { return 0 }
        return max(0, c.timeIntervalSince(created) / 60)
    }
    // All tags: explicit field + #hashtags parsed from notes (de-duplicated, lowercased).
    var allTags: [String] {
        let hash = notes.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "," })
            .compactMap { $0.hasPrefix("#") ? String($0.dropFirst()).lowercased() : nil }
            .filter { !$0.isEmpty }
        var seen = Set<String>(); var out: [String] = []
        for t in (tags.map { $0.lowercased() } + hash) where !t.isEmpty && !seen.contains(t) { seen.insert(t); out.append(t) }
        return out
    }

    // Risk per unit (absolute distance entry -> stop)
    var riskPerUnit: Double { abs(entry - stop) }
    // Reward per unit (absolute distance entry -> target)
    var rewardPerUnit: Double { abs(target - entry) }
    // Total dollar risk at stop
    var riskDollars: Double { riskPerUnit * size }
    // Planned reward:risk ratio
    var rrRatio: Double { riskPerUnit > 0 ? rewardPerUnit / riskPerUnit : 0 }
    // Realized R-multiple once closed (pnl measured in units of initial risk)
    var rMultiple: Double {
        guard result != .open, riskDollars > 0 else { return 0 }
        return pnl / riskDollars
    }
}

// MARK: - Signal scoring engine (user-driven / scenario model — NOT a live broker feed)
// Mirrors the website's composite-scoring model: each factor produces a raw score in [-1, 1],
// is multiplied by a weight, summed into a composite, then mapped to a LONG/SHORT/FLAT signal.
// Signal modules — mirrors the website's named stack (StepGMA · CVD · VWAP · VPIN · HMM regime · alpha monitor …).
struct GateCheck: Identifiable {
    let gate: RiskGate
    let passed: Bool
    let detail: String
    var id: String { gate.rawValue }
}

// MARK: - Multi-timeframe consensus (mirrors "2-of-8 TF consensus, direction lock")
struct TimeframeVote: Identifiable {
    let label: String
    let direction: SignalDirection
    var id: String { label }
}

enum ConsensusEngine {
    static let timeframes = ["1m", "5m", "15m", "30m", "1h", "4h", "1D", "1W"]
    static let requiredAgree = 2   // 2-of-8 minimum, website's stated threshold

    // Derive a per-timeframe vote from the composite + trend factor (deterministic, no fake feed).
    static func votes(_ inp: SignalInputs) -> [TimeframeVote] {
        let comp = SignalEngine.composite(inp) / 100        // -1…1
        let trend = inp.raw(.trend)
        let momentum = inp.raw(.momentum)
        // Lower timeframes lean on momentum, higher timeframes lean on trend; composite is the base.
        let weights: [Double] = [momentum*0.6, momentum*0.4 + comp*0.2, comp*0.4, comp*0.5,
                                 comp*0.6, comp*0.4 + trend*0.3, trend*0.6, trend*0.8]
        return zip(timeframes, weights).map { (tf, w) in
            let v = comp + w
            let d: SignalDirection = v >= 0.18 ? .long : (v <= -0.18 ? .short : .flat)
            return TimeframeVote(label: tf, direction: d)
        }
    }
    static func agreeing(_ votes: [TimeframeVote], with dir: SignalDirection) -> Int {
        dir == .flat ? 0 : votes.filter { $0.direction == dir }.count
    }
}

enum GateEngine {
    // Evaluate all 13 gates against the current inputs + computed result.
    static func evaluate(_ inp: SignalInputs, _ r: SignalResult) -> [GateCheck] {
        let votes = ConsensusEngine.votes(inp)
        let agree = ConsensusEngine.agreeing(votes, with: r.direction)
        let cvdDiv = inp.raw(.cvdDivergence), cvdFlow = inp.raw(.cvdFlow)
        let dirSign = r.direction == .long ? 1.0 : (r.direction == .short ? -1.0 : 0.0)
        var checks: [GateCheck] = []
        func add(_ g: RiskGate, _ ok: Bool, _ d: String) { checks.append(GateCheck(gate: g, passed: ok, detail: d)) }

        add(.conviction, abs(r.score) >= 25, "score \(String(format: "%+.0f", r.score)) vs ±25")
        add(.consensus, agree >= ConsensusEngine.requiredAgree, "\(agree)/8 TFs agree (need \(ConsensusEngine.requiredAgree))")
        add(.directionLock, r.direction != .flat, r.direction == .flat ? "no locked direction" : "locked \(r.direction.rawValue)")
        add(.cvdAgreement, r.direction == .flat ? false : (cvdDiv * dirSign >= -0.1), "CVD div \(String(format: "%+.2f", cvdDiv))")
        add(.flowConfirm, r.direction == .flat ? false : (cvdFlow * dirSign >= 0.05), "flow \(String(format: "%+.2f", cvdFlow))")
        add(.volumeFloor, inp.raw(.volume) >= -0.2, "vol \(String(format: "%+.2f", inp.raw(.volume)))")
        add(.trendAlign, r.direction == .flat ? false : (inp.raw(.trend) * dirSign >= -0.15), "trend \(String(format: "%+.2f", inp.raw(.trend)))")
        add(.momentumQuality, r.direction == .flat ? false : (inp.raw(.momentum) * dirSign >= -0.15), "mom \(String(format: "%+.2f", inp.raw(.momentum)))")
        add(.sessionWindow, inp.raw(.session) >= -0.5, "session \(String(format: "%+.2f", inp.raw(.session)))")
        add(.smtClear, r.direction == .flat ? false : (inp.raw(.smt) * dirSign >= -0.4), "SMT \(String(format: "%+.2f", inp.raw(.smt)))")
        add(.riskReward, r.rr >= 1.5, "R:R \(String(format: "%.2f", r.rr)) vs 1.5")
        add(.atrSanity, inp.atr > 0 && inp.atr < inp.price * 0.5, "ATR \(TradeMath.numTrim(inp.atr))")
        add(.spreadCost, inp.pointValue > 0 && r.riskDollars > 0, "risk \(TradeMath.money(r.riskDollars))")
        return checks
    }
    static func passedCount(_ c: [GateCheck]) -> Int { c.filter { $0.passed }.count }
    static func allPass(_ c: [GateCheck]) -> Bool { c.allSatisfy { $0.passed } }
}

// A committed signal saved to the trade log (persisted) — the honestly-graded session ledger.
struct SignalLog: Identifiable, Codable, Hashable {
    var id = UUID()
    var symbol: String
    var direction: String
    var score: Double
    var entry: Double
    var stop: Double
    var target: Double
    var riskDollars: Double
    var rr: Double
    var created = Date()
    // Honest grading: a committed signal starts pending, then is graded win/loss by the user.
    var grade: String = "pending"          // pending | win | loss
    var pnl: Double = 0                     // MODELED P&L in dollars: a win banks the planned target
                                           // reward, a loss the 1R risk — NOT a broker-realized fill.
    var gatesPassed: Int = 13               // how many of the 13 gates passed at commit
    var tfAgree: Int = 0                    // multi-TF agreeing count at commit (x of 8)
    var dir: SignalDirection { SignalDirection(rawValue: direction) ?? .flat }
    var result: TradeResult {
        switch grade { case "win": return .win; case "loss": return .loss; default: return .open }
    }
}

// MARK: - Equity curve (real, computed from the honestly-graded session ledger)
// A single point on the session equity curve. index 0 is the zero baseline; each
// subsequent point is one graded signal, carrying the running cumulative P&L.
struct EquityPoint: Identifiable {
    let id = UUID()
    let index: Int
    let date: Date
    let equity: Double   // cumulative session P&L up to and including this signal
    let pnl: Double       // this signal's realized P&L (0 for the baseline point)
}

enum EquityCurve {
    // Build a cumulative session-P&L curve from graded signals ONLY. Pending
    // signals contribute nothing (honest grading). Returns [] when nothing is
    // graded yet, so the UI shows a proper empty state — never a fabricated line.
    static func points(_ signals: [SignalLog]) -> [EquityPoint] {
        let g = signals.filter { $0.grade == "win" || $0.grade == "loss" }
                       .sorted { $0.created < $1.created }
        guard let first = g.first else { return [] }
        var pts: [EquityPoint] = [EquityPoint(index: 0, date: first.created.addingTimeInterval(-1), equity: 0, pnl: 0)]
        var run = 0.0
        for (i, s) in g.enumerated() {
            run += s.pnl
            pts.append(EquityPoint(index: i + 1, date: s.created, equity: run, pnl: s.pnl))
        }
        return pts
    }
    static func peak(_ pts: [EquityPoint]) -> Double { pts.map(\.equity).max() ?? 0 }
    static func trough(_ pts: [EquityPoint]) -> Double { pts.map(\.equity).min() ?? 0 }
    // Max drawdown: largest peak-to-valley drop in cumulative equity (>= 0).
    static func maxDrawdown(_ pts: [EquityPoint]) -> Double {
        guard !pts.isEmpty else { return 0 }
        var peakSoFar = -Double.greatestFiniteMagnitude, mdd = 0.0
        for p in pts { peakSoFar = max(peakSoFar, p.equity); mdd = max(mdd, peakSoFar - p.equity) }
        return mdd
    }
}

// MARK: - Prop firm reference data (real futures prop firms)
struct PropFirm: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let note: String
}

enum FirmData {
    // 10 real futures prop firms with factual notes.
    static let all: [PropFirm] = [
        PropFirm(name: "Apex Trader Funding", note: "Futures evaluations across account sizes; 30% consistency rule on payouts."),
        PropFirm(name: "Topstep", note: "Trading Combine then Express Funded Account; daily loss limit and trailing max drawdown."),
        PropFirm(name: "Take Profit Trader", note: "One-step evaluation (Pro accounts); end-of-day trailing drawdown."),
        PropFirm(name: "Earn2Trade", note: "Gauntlet Mini program funded through partner FCM; profit target plus max drawdown."),
        PropFirm(name: "MyFundedFutures", note: "Multiple plans (Starter/Expert/Milestone); no daily loss limit on some plans."),
        PropFirm(name: "Bulenox", note: "Two account types; trailing drawdown and consistency requirements."),
        PropFirm(name: "Tradeify", note: "Straight-to-funded and evaluation paths; end-of-day drawdown options."),
        PropFirm(name: "Elite Trader Funding", note: "Many evaluation models including static drawdown options."),
        PropFirm(name: "Funded Futures Network", note: "Single-step evaluations; trailing drawdown and scaling rules."),
        PropFirm(name: "Legends Trading", note: "Futures evaluations with intraday and end-of-day drawdown choices.")
    ]
}

// MARK: - Persistence (real backend — Codable JSON in the sandbox container)
final class AppModel: ObservableObject {
    @Published var trades: [Trade] = [] { didSet { save() } }
    @Published var signals: [SignalLog] = [] { didSet { save() } }

    private struct Box: Codable { var trades: [Trade]; var signals: [SignalLog]? }
    private let url: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BlackLabelTrading", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("data.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let box = try? JSONDecoder().decode(Box.self, from: data) else { return }
        trades = box.trades
        signals = box.signals ?? []
    }
    private func save() {
        let box = Box(trades: trades, signals: signals)
        if let data = try? JSONEncoder().encode(box) { try? data.write(to: url, options: .atomic) }
    }

    // Trades CRUD
    func upsert(_ t: Trade) {
        if let i = trades.firstIndex(where: { $0.id == t.id }) { trades[i] = t } else { trades.insert(t, at: 0) }
    }
    func delete(_ t: Trade) { trades.removeAll { $0.id == t.id } }

    // Import broker-CSV rows (already parsed) into the journal. Each becomes a closed Trade
    // when it has a non-zero P&L (win/loss by sign). Returns the count actually imported.
    @discardableResult
    func importTrades(_ rows: [ImportedTrade]) -> Int {
        var added: [Trade] = []
        for r in rows {
            var t = Trade()
            t.symbol = r.symbol
            t.direction = r.isLong ? .long : .short
            t.entry = r.entry; t.exit = r.exit; t.size = max(0, r.qty)
            t.pnl = r.pnl
            t.result = r.pnl > 0 ? .win : (r.pnl < 0 ? .loss : .open)
            t.maeR = max(0, r.maeR); t.mfeR = max(0, r.mfeR)
            t.tags = r.tags
            if let o = r.opened { t.created = o }
            t.closed = r.closed
            added.append(t)
        }
        trades.insert(contentsOf: added, at: 0)
        return added.count
    }

    // Signal log (honestly-graded session ledger)
    func commit(_ s: SignalLog) { signals.insert(s, at: 0) }
    func deleteSignal(_ s: SignalLog) { signals.removeAll { $0.id == s.id } }

    // Vault-backed daily logs: write the GRADED session ledger, grouped by day with per-day totals,
    // to a CSV in the app's own local vault dir. Real data only (your graded signals); modeled P&L
    // is labeled as such. Returns the file path, or nil when there is nothing graded to log.
    func exportDailyLogs() -> String? {
        let graded = signals.filter { $0.grade == "win" || $0.grade == "loss" }
        guard !graded.isEmpty else { return nil }
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd"
        let entries = graded.sorted { $0.created < $1.created }.map {   // oldest-first daily log
            SessionLedger.Entry(day: df.string(from: $0.created), symbol: $0.symbol,
                                direction: $0.direction, grade: $0.grade, pnl: $0.pnl)
        }
        let csv = SessionLedger.dailyCSV(entries)
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Black Label Trading/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("session-daily-log.csv")
        do { try csv.write(to: url, atomically: true, encoding: .utf8); return url.path } catch { return nil }
    }
    // Grade a committed signal: a win banks the reward AT THE PLANNED TARGET, a loss the 1R risk,
    // pending resets. This is a MODELED outcome (target/stop), not a broker-realized fill — every
    // surface that shows it must say "at target / modeled", never "realized" (honesty binding).
    func grade(_ s: SignalLog, as grade: String) {
        guard let i = signals.firstIndex(where: { $0.id == s.id }) else { return }
        signals[i].grade = grade
        let risk = signals[i].riskDollars
        switch grade {
        case "win":  signals[i].pnl = risk * max(0.1, signals[i].rr)   // reward at planned R:R
        case "loss": signals[i].pnl = -risk                            // full 1R loss
        default:     signals[i].pnl = 0
        }
    }
    // Session ledger rollups (only graded signals count toward P&L / record).
    var gradedSignals: [SignalLog] { signals.filter { $0.grade != "pending" } }
    var signalWins: Int { signals.filter { $0.grade == "win" }.count }
    var signalLosses: Int { signals.filter { $0.grade == "loss" }.count }
    var sessionPnL: Double { signals.reduce(0) { $0 + ($1.grade == "pending" ? 0 : $1.pnl) } }
    var signalWinRate: Double {
        let n = gradedSignals.count
        return n > 0 ? Double(signalWins) / Double(n) * 100 : 0
    }
    // Real session equity curve, derived from graded signals only (empty until graded).
    var equityCurve: [EquityPoint] { EquityCurve.points(signals) }

    // SHIP NO DATA: no seed/sample/demo records. The store starts empty and only
    // ever holds the end user's own trades and graded signals (see EmptyState UI).

    // Journal rollups (real, computed from saved data)
    var closedTrades: [Trade] { trades.filter { $0.result != .open } }
    var wins: [Trade] { trades.filter { $0.result == .win } }
    var losses: [Trade] { trades.filter { $0.result == .loss } }
    var totalPnL: Double { trades.reduce(0) { $0 + ($1.result == .open ? 0 : $1.pnl) } }
    var winRate: Double {
        let n = closedTrades.count
        return n > 0 ? Double(wins.count) / Double(n) * 100 : 0
    }
    var avgRMultiple: Double {
        let closed = closedTrades.filter { $0.riskDollars > 0 }
        guard !closed.isEmpty else { return 0 }
        return closed.reduce(0) { $0 + $1.rMultiple } / Double(closed.count)
    }
    var profitFactor: Double {
        let grossWin = wins.reduce(0) { $0 + max(0, $1.pnl) }
        let grossLoss = losses.reduce(0) { $0 + abs(min(0, $1.pnl)) }
        return grossLoss > 0 ? grossWin / grossLoss : (grossWin > 0 ? .infinity : 0)
    }
    func count(_ r: TradeResult) -> Int { trades.filter { $0.result == r }.count }
}

// MARK: - Trading math

// MARK: - Local accounts (on-device, App Store 5.1.1(v) deletion supported)
enum AuthError: String, Error {
    case badEmail = "Enter a valid email address."
    case weakPw = "Password must be at least 6 characters."
    case exists = "An account with that email already exists — sign in instead."
    case noAccount = "No account found for that email — create one first."
    case wrongPw = "Incorrect password. Try again."
}
enum AccountStore {
    static let key = "com.blacklabel.trading.accounts"
    static func load() -> [String: String] { (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:] }
    static func save(_ d: [String: String]) { UserDefaults.standard.set(d, forKey: key) }
    static func hash(_ e: String, _ p: String) -> String {
        SHA256.hash(data: Data((e.lowercased() + "::" + p).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func create(_ email: String, _ pw: String) -> Result<Void, AuthError> {
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard e.contains("@"), e.contains(".") else { return .failure(.badEmail) }
        guard pw.count >= 6 else { return .failure(.weakPw) }
        var a = load(); if a[e] != nil { return .failure(.exists) }
        a[e] = hash(e, pw); save(a); return .success(())
    }
    static func signIn(_ email: String, _ pw: String) -> Result<Void, AuthError> {
        let e = email.trimmingCharacters(in: .whitespaces).lowercased(); let a = load()
        guard let h = a[e] else { return .failure(.noAccount) }
        return h == hash(e, pw) ? .success(()) : .failure(.wrongPw)
    }
    static func delete(_ email: String) { var a = load(); a[email.trimmingCharacters(in: .whitespaces).lowercased()] = nil; save(a) }
}

final class Session: ObservableObject {
    @Published var signedIn = false
    @Published var email = ""
}

// MARK: - Local app settings (Google client ID) — on-device only.
// The Google OAuth button is only shown once a client ID exists. The buyer can paste
// their own client ID here (UserDefaults) so the option is never silently hidden — we
// surface the field instead. Falls back to a build-time Info.plist value if present.
enum AppSettingsStore {
    static let googleClientIDKey = "com.blacklabel.trading.googleClientID"

    /// The effective Google client ID: the user-entered value (UserDefaults) wins,
    /// otherwise the build-time Info.plist value (normally empty).
    static var googleClientID: String {
        let user = (UserDefaults.standard.string(forKey: googleClientIDKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !user.isEmpty { return user }
        return ((Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func setGoogleClientID(_ id: String) {
        let v = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { UserDefaults.standard.removeObject(forKey: googleClientIDKey) }
        else { UserDefaults.standard.set(v, forKey: googleClientIDKey) }
    }
}

// MARK: - Local platform account reference (on-device only — signals-only, manual execution)
// HONEST FRAMING: This stores the buyer's OWN platform account reference on THIS Mac.
// It is NOT a live broker feed and it does NOT auto-trade or move money. The username and
// connection note live in UserDefaults; the password (if entered) lives in the macOS
// Keychain — never in plaintext, never bundled, never sent anywhere by this app.
struct WealthChartsAccount: Codable, Equatable {
    var username: String = ""
    var note: String = ""          // optional free-text label (e.g. "Topstep 50K eval feed")
    var connectedAt: Date?          // when the user last saved a connection (local only)

    var isConfigured: Bool { !username.trimmingCharacters(in: .whitespaces).isEmpty }
}

// Keychain helper — generic password item scoped to this app + the saved username.
enum WCKeychain {
    private static let service = "com.blacklabel.trading.wealthcharts"

    // Base query (class + service + account) — TradingKeychain adds storage-location/return keys.
    private static func base(_ acct: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acct
        ]
    }
    static func setSecret(_ secret: String, account: String) {
        let acct = account.isEmpty ? "_default" : account
        delete(account: acct)
        guard !secret.isEmpty else { return }
        TradingKeychain.set(base(acct), data: Data(secret.utf8))
    }
    static func hasSecret(account: String) -> Bool {
        let acct = account.isEmpty ? "_default" : account
        return TradingKeychain.copy(base(acct)) != nil
    }
    static func delete(account: String) {
        let acct = account.isEmpty ? "_default" : account
        TradingKeychain.delete(base(acct))
    }
}

// Observable store for the local platform account reference. Username/note in UserDefaults,
// password in Keychain. No network calls — purely local persistence.
final class WealthChartsStore: ObservableObject {
    @Published var account: WealthChartsAccount { didSet { persist() } }
    @Published private(set) var hasSecret: Bool = false

    private static let key = "com.blacklabel.trading.wealthcharts.account"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let acct = try? JSONDecoder().decode(WealthChartsAccount.self, from: data) {
            account = acct
        } else {
            account = WealthChartsAccount()
        }
        hasSecret = WCKeychain.hasSecret(account: account.username)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(account) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Save the connection locally. Username/note persist to UserDefaults; the password,
    /// if provided, goes to the Keychain (this device only). Stamps connectedAt.
    func save(username: String, password: String, note: String) {
        let u = username.trimmingCharacters(in: .whitespacesAndNewlines)
        account.username = u
        account.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        account.connectedAt = Date()
        if !password.isEmpty { WCKeychain.setSecret(password, account: u) }
        hasSecret = WCKeychain.hasSecret(account: u)
    }

    /// Forget the connection entirely — wipes UserDefaults entry and Keychain secret.
    func disconnect() {
        WCKeychain.delete(account: account.username)
        account = WealthChartsAccount()
        UserDefaults.standard.removeObject(forKey: Self.key)
        hasSecret = false
    }
}

// SwiftUI color for the pure SignalDirection (kept here so SignalCore stays SwiftUI-free).
extension SignalDirection {
    var tint: Color {
        switch self { case .long: return BLTheme.green; case .short: return BLTheme.red; case .flat: return BLTheme.sub }
    }
}
