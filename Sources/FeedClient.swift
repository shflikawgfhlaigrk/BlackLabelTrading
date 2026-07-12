// Black Label Trading — live feed client (SwiftUI @MainActor ObservableObject).
//
// HONEST FRAMING: this talks ONLY to the product's OWN self-contained backend (bltd_api.py,
// default http://127.0.0.1:8787). That backend serves ONLY what the buyer's own webhook sender
// pushed into the buyer's own local store. NOTHING is fetched from Black Label / Utah /
// any third party here. The shipped Topstep setup is ES-family only; non-ES symbols are filtered so
// stale local rows cannot populate the picker. Signals fire only where the edge-gate proves an edge.
// When the backend is down, or no webhook data has arrived, the
// client reports an honest FeedState (.offline / .loggedOut / .idle) and shows NO bars — it never
// fabricates prices. This client reads bars/ticks/fires and relays the user's OWN execution
// commands to the backend's /api/exec/* control plane; it never places an order on its own and
// execution is OFF by default (a live order needs arm+live+own-creds+firm-ToS+risk+edge+kill-clear).
//
// The backend URL is buyer-configurable (Settings) so a buyer can run the backend on another
// host/port on their own machine. The decode contract lives in FeedTypes.swift (test-locked).
import Foundation
import Combine

@MainActor
final class FeedClient: ObservableObject {
    // Observed, honest state — every field reflects a real backend response.
    @Published var state: FeedState = .offline
    @Published var capture = CaptureStatus()   // full honest probe (source + evaluator liveness)
    @Published var symbols = FeedSymbols()
    @Published var lastError: String? = nil
    @Published var lastSync: Date? = nil
    @Published private(set) var connecting = false
    // Honest prerequisite (e.g. "a Python 3 runtime is required") when the bundled backend can't
    // start because the host is missing a dependency. nil unless the launcher wrote a sentinel.
    @Published var prereq: PrereqInfo? = nil

    // Buyer-configurable backend location (own machine / own network only).
    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: Self.urlKey) }
    }
    private var token: String? = nil
    private var signedIn: Bool { token != nil }
    // Public read of the session state for view gating (the token itself stays private).
    var isSignedIn: Bool { signedIn }

    private static let urlKey = "com.blacklabel.trading.feedURL"
    static let defaultURL = "http://127.0.0.1:8787"

    init() {
        baseURL = UserDefaults.standard.string(forKey: Self.urlKey) ?? Self.defaultURL
    }

    private var session: URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }

    private func url(_ path: String) -> URL? { URL(string: baseURL.trimmingCharacters(in: .whitespaces) + path) }

    // MARK: - Sign-in handshake (mints the backend token; the local backend accepts any non-empty
    // creds and mints a per-deployment token — a real deployment would issue per-user tokens).
    func connect(email: String) async {
        connecting = true; defer { connecting = false }
        // Self-contained: start the bundled backend if the local one isn't already up.
        await ensureBackendRunning()
        guard let u = url("/auth/signin") else { state = .offline; return }
        var req = URLRequest(url: u); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The buyer's app sign-in email is reused as the backend identity (local, single-user).
        let creds = ["email": email.isEmpty ? "local@blacklabel" : email, "password": "local-session"]
        req.httpBody = try? JSONSerialization.data(withJSONObject: creds)
        do {
            let (data, resp) = try await session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tok = obj["token"] as? String else {
                token = nil; state = .offline; lastError = "Sign-in rejected"; return
            }
            token = tok; lastError = nil
            await refreshStatus()
        } catch {
            token = nil; state = .offline
            lastError = friendly(error)
        }
    }

    private func authed(_ path: String) -> URLRequest? {
        guard let u = url(path), let tok = token else { return nil }
        var req = URLRequest(url: u)
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        return req
    }

    private func getJSON(_ path: String) async -> [String: Any]? {
        guard let req = authed(path) else { return nil }
        do {
            let (data, resp) = try await session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            lastError = friendly(error)
            return nil
        }
    }

    // Unauthenticated GET for PUBLIC routes only (the reference artifact). No Bearer token — a cold
    // buyer who has not signed in can still read Black Label's reference OOS verdicts.
    private func getJSONPublic(_ path: String) async -> [String: Any]? {
        guard let u = url(path) else { return nil }
        do {
            let (data, resp) = try await session.data(for: URLRequest(url: u))
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }

    // Authed POST returning the decoded JSON body (nil on transport/HTTP failure).
    private func postJSON(_ path: String, _ body: [String: Any]) async -> [String: Any]? {
        guard let req0 = authed(path) else { return nil }
        var req = req0; req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            lastError = friendly(error)
            return nil
        }
    }

    // MARK: - TR-06 honest edge-gate alerts. Posts the gate VERDICT (incl. "no edge") to an endpoint
    // the buyer OWNS. OFF by default; no endpoint => the backend makes zero network calls. A push can
    // NEVER become an order (the alert path imports nothing from the execution engine).

    /// Token-free view of the alert config for the settings UI.
    func alertStatus() async -> AlertStatus {
        guard signedIn, let o = await getJSON("/api/alerts/status") else { return .empty }
        return AlertStatus.decode(o)
    }

    /// Persist the buyer's alert settings (through /api/config; alert keys only).
    @discardableResult
    func saveAlertConfig(enabled: Bool, endpoint: String, provider: String,
                         pushoverToken: String, pushoverUser: String) async -> Bool {
        let patch: [String: Any] = [
            "alertEnabled": enabled,
            "alertEndpoint": endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            "alertProvider": provider,
            "alertPushoverToken": pushoverToken.trimmingCharacters(in: .whitespacesAndNewlines),
            "alertPushoverUser": pushoverUser.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        return await postJSON("/api/config", patch) != nil
    }

    /// Fire a TEST alert to the configured endpoint. Returns the honest result (posted / not-sent).
    func testAlert() async -> AlertSendResult {
        guard signedIn, let o = await postJSON("/api/alerts/test", [:]) else { return .unreachable }
        return AlertSendResult.decode(o)
    }

    /// Post the current edge-gate verdict for the buyer's bars to their endpoint now.
    func sendGateAlert() async -> AlertSendResult {
        guard signedIn, let o = await postJSON("/api/alerts/send", [:]) else { return .unreachable }
        return AlertSendResult.decode(o)
    }

    // MARK: - Reference OOS verdicts (GET /api/reference): Black Label's edge-gate result on OUR OWN
    // historical ES bars, so a cold buyer sees a real, earned verdict before they've captured a
    // single bar. REFERENCE ONLY — historical ES, not the buyer's account, not a promise. Public
    // route (no sign-in needed). Ensures the bundled backend is up first, then decodes; an absent
    // artifact returns .empty (honest pending state), never a fabricated verdict.
    func referenceReport() async -> ReferenceReport {
        await ensureBackendRunning()
        guard let obj = await getJSONPublic("/api/reference") else { return .empty }
        return ReferenceReport.decode(obj)
    }

    // MARK: - Execution control plane (default OFF). Thin pass-through to the backend's dedicated,
    // auth-gated /api/exec/* routes. A live order is impossible unless armed+live+own-creds+firm-ToS
    // +risk+edge+kill-clear all hold in the backend engine — the UI cannot bypass that.
    @Published var exec = ExecStatus()

    func refreshExec() async {
        if let o = await getJSON("/api/exec/status") { exec = ExecStatus.decode(o) }
    }

    func execOrders() async -> [[String: Any]]? {
        guard let o = await getJSON("/api/exec/orders") else { return nil }
        return o["orders"] as? [[String: Any]]
    }

    @discardableResult
    func execCommand(_ cmd: String, _ body: [String: Any] = [:]) async -> Bool {
        guard let req0 = authed("/api/exec/\(cmd)") else { return false }
        var req = req0; req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        defer { Task { await refreshExec() } }
        do {
            let (data, resp) = try await session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return (obj?["ok"] as? Bool) ?? true
        } catch { lastError = friendly(error); return false }
    }

    // MARK: - Self-contained backend bootstrap. The product SHIPS its own data backend inside the
    // app bundle (Contents/Resources/backend/launch-backend.sh, stdlib-only Python). When the local
    // backend on the default URL isn't reachable, the app starts the BUNDLED one so the buyer gets
    // a working, self-contained feed/store with no manual setup. Only attempted for a localhost
    // default URL — never auto-spawns anything for a buyer-configured remote host. Idempotent.
    private var triedBootstrap = false
    @discardableResult
    func ensureBackendRunning() async -> Bool {
        // Only for the default localhost backend; a custom baseURL is the buyer's own choice.
        let u = baseURL.trimmingCharacters(in: .whitespaces)
        guard u == Self.defaultURL || u.hasPrefix("http://127.0.0.1") || u.hasPrefix("http://localhost") else { return false }
        if await healthOK() { return true }
        guard !triedBootstrap else { return await healthOK() }
        triedBootstrap = true
        guard let script = Bundle.main.url(forResource: "launch-backend", withExtension: "sh", subdirectory: "backend")
                ?? bundledBackendScript() else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [script.path, "--bg"]
        do { try proc.run() } catch { lastError = "Couldn't start bundled backend"; return false }
        // Poll briefly for the backend to come up (it binds fast; SQLite store is created empty).
        for _ in 0..<20 {
            if await healthOK() { prereq = nil; return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        let ok = await healthOK()
        // If it still isn't up, the launcher may have written an honest prerequisite sentinel
        // (e.g. no working python3 on this Mac). Surface it instead of an opaque "offline".
        if ok { prereq = nil } else { prereq = PrereqInfo.read() }
        return ok
    }
    private func bundledBackendScript() -> URL? {
        // Fallback lookup (subdirectory resource APIs can vary): Resources/backend/launch-backend.sh.
        let res = Bundle.main.resourceURL?.appendingPathComponent("backend/launch-backend.sh")
        if let r = res, FileManager.default.fileExists(atPath: r.path) { return r }
        return nil
    }
    private func healthOK() async -> Bool {
        guard let u = url("/health") else { return false }
        do {
            let (_, resp) = try await session.data(from: u)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    // MARK: - Capture status + symbol catalogue (the honest feed banner).
    func refreshStatus() async {
        guard signedIn else { state = .notSignedIn; capture = CaptureStatus(); return }
        guard let cap = await getJSON("/api/capture") else { state = .offline; capture = CaptureStatus(); return }
        let cs = CaptureStatus.decode(cap)
        capture = cs
        state = cs.state(signedIn: true)
        if let syms = await getJSON("/api/symbols") { symbols = FeedSymbols.decode(syms) }
        lastSync = Date()
    }

    // MARK: - Bars for a symbol (recent history for the chart). Empty store -> [] (honest).
    func recentBars(symbol: String, limit: Int = 400) async -> [Bar] {
        let s = symbol.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, signedIn,
              let obj = await getJSON("/api/recent?symbol=\(enc(s))&limit=\(limit)") else { return [] }
        return FeedBars.decode(obj)
    }

    // Full history (for backtest depth). Oldest -> newest.
    func allBars(symbol: String, limit: Int = 5000) async -> [Bar] {
        let s = symbol.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, signedIn,
              let obj = await getJSON("/api/bars?symbol=\(enc(s))&limit=\(limit)") else { return [] }
        return FeedBars.decode(obj)
    }

    // MARK: - Live last-price tick. nil when gated (no fresh tick) — never a fabricated price.
    func liveTick(symbol: String) async -> LiveTick? {
        let s = symbol.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, signedIn,
              let obj = await getJSON("/api/live?symbol=\(enc(s))") else { return nil }
        return LiveTick.decode(obj)
    }

    // MARK: - Backend engine fleet (GET /api/screen): every engine's REAL per-symbol OOS verdict
    // on the buyer's own captured bars. Empty store -> [] (honest; engines render "warming").
    // Nothing fabricated — the rows are exactly what the gate proved (or couldn't) on real bars.
    func engineScreen() async -> [EngineRow] {
        guard signedIn, let obj = await getJSON("/api/screen") else { return [] }
        return EngineRoster.decode(obj)
    }

    // MARK: - Buyer-triggered gate re-run (GET /api/gate/rerun): re-runs the SHIPPED edge-gate
    // provers over the buyer's OWN captured bars on demand and returns the full reproducible
    // statistics (n / W / L / max-drawdown-R / p-value per engine + prover_sha). Empty store or a
    // signed-out session -> honest empty report (available == false), never a fabricated verdict.
    func rerunGate() async -> GateRerunReport {
        guard signedIn, let obj = await getJSON("/api/gate/rerun") else { return .empty }
        return GateRerunReport.decode(obj)
    }

    // MARK: - Instrument catalog (GET /api/instruments): the first-class multi-asset picker source.
    // Enumerates the instruments actually in the buyer's OWN captured bars (never a hardcoded list),
    // each classified + labeled for which ES-tuned modules apply. Honest onlyES / empty states.
    func instrumentCatalog() async -> InstrumentCatalog {
        guard signedIn, let obj = await getJSON("/api/instruments") else { return .empty }
        return InstrumentCatalog.decode(obj)
    }

    // MARK: - No-code backtest lab (GET /api/backtest/run): runs the SHIPPED prover on ONE
    // (engine, symbol) over the buyer's OWN captured bars, optionally date-scoped, split into folds.
    // Returns per-fold n / W / L / max-drawdown-R / p + prover_sha — never a fabricated headline.
    // Signed-out or unreachable backend -> honest empty report (available == false).
    func runBacktestLab(engine: String, symbol: String,
                        startTs: Int? = nil, endTs: Int? = nil, folds: Int = 1) async -> BacktestLabReport {
        let s = symbol.trimmingCharacters(in: .whitespaces)
        guard signedIn, !s.isEmpty, !engine.isEmpty else { return .empty }
        var path = "/api/backtest/run?engine=\(enc(engine))&symbol=\(enc(s))&folds=\(max(1, folds))"
        if let a = startTs { path += "&start=\(a)" }
        if let b = endTs { path += "&end=\(b)" }
        guard let obj = await getJSON(path) else { return .empty }
        return BacktestLabReport.decode(obj)
    }

    // First/last captured epoch + count for a symbol (GET /api/backtest/bounds) — the lab's honest
    // date-range default (the real span of the buyer's OWN data). Empty store -> zeros.
    func barBounds(symbol: String) async -> (count: Int, firstTs: Int?, lastTs: Int?) {
        let s = symbol.trimmingCharacters(in: .whitespaces)
        guard signedIn, !s.isEmpty, let obj = await getJSON("/api/backtest/bounds?symbol=\(enc(s))") else {
            return (0, nil, nil)
        }
        let first = FeedBars.num(obj["firstTs"] as Any).map { Int($0) }
        let last = FeedBars.num(obj["lastTs"] as Any).map { Int($0) }
        return (Int(FeedBars.num(obj["count"] as Any) ?? 0), first, last)
    }

    // MARK: - Signal journal (GET /api/fires): real edge-gated fires recorded from the live feed.
    func recentFires(limit: Int = 50) async -> [FireRow] {
        guard signedIn, let obj = await getJSON("/api/fires?limit=\(limit)") else { return [] }
        return FireFeed.decode(obj)
    }

    // MARK: - Connect the buyer's own browser trading session (launches the product-owned debug
    // Chrome at supported platform sign-ins; reports REAL reachability). Signals-only — opens
    // login tabs, reads market-data frames after the buyer signs in, never uses broker APIs.
    func launchCapture(source: String? = nil) async {
        guard let req0 = authed("/api/connect") else { return }
        var req = req0; req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let source, !source.isEmpty {
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["source": source])
        } else {
            req.httpBody = "{}".data(using: .utf8)
        }
        connecting = true; defer { connecting = false }
        // Surface the honest no-Chrome prerequisite (RC4): browser capture needs a Chromium browser.
        // If none is installed the backend reports chromePresent:false instead of looping silently.
        if let (data, _) = try? await session.data(for: req),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if (obj["chromePresent"] as? Bool) == false {
                prereq = PrereqInfo(
                    reason: (obj["chromeReason"] as? String)
                        ?? "Google Chrome is required for browser capture.",
                    fix: "",
                    detail: (obj["chromeDetail"] as? String)
                        ?? "Install Google Chrome (or Chromium, Brave, or Edge), then reopen and connect your platform.")
            } else if obj["chromePresent"] != nil {
                prereq = nil
            }
        }
        await refreshStatus()
    }

    // MARK: - Feed sources. The surfaced path is webhook ingestion: the buyer's sender/bridge posts
    // observed ticks or OHLC bars into the local backend, which normalizes them into the SAME store.

    /// The catalogue of connectable feed sources + their credential fields (for the picker).
    func feedSources() async -> [FeedSourceInfo] {
        guard signedIn, let obj = await getJSON("/api/feed/sources") else { return [] }
        return FeedSourceInfo.decodeList(obj)
    }

    /// The currently connected webhook feed's honest status, or nil.
    func feedStatus() async -> ApiFeedStatus? {
        guard signedIn, let obj = await getJSON("/api/feed/status") else { return nil }
        return ApiFeedStatus.decode(obj)
    }

    /// Local webhook receiver details for the buyer's sender/bridge. The token is a local backend
    /// write token, not a prop-firm credential.
    func webhookInfo() async -> WebhookInfo? {
        guard signedIn, let obj = await getJSON("/api/webhook/info") else { return nil }
        return WebhookInfo.decode(obj)
    }

    /// Legacy internal hook. The visible product uses webhook ingestion and does not request API keys.
    @discardableResult
    func connectFeed(source: String, creds: [String: String]) async -> ApiFeedStatus? {
        guard let req0 = authed("/api/feed/connect") else { return nil }
        var req = req0; req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["source": source, "creds": creds])
        connecting = true; defer { connecting = false }
        do {
            let (data, resp) = try await session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return ApiFeedStatus.decode(obj)
        } catch { lastError = friendly(error); return nil }
    }

    /// Disconnect the active managed feed, if any.
    @discardableResult
    func disconnectFeed() async -> Bool {
        guard let req0 = authed("/api/feed/disconnect") else { return false }
        var req = req0; req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = "{}".data(using: .utf8)
        return (try? await session.data(for: req)) != nil
    }

    private func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }
    private func friendly(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost: return "Backend not running"
            case NSURLErrorTimedOut: return "Backend timed out"
            default: return "Connection error"
            }
        }
        return ns.localizedDescription
    }
}
