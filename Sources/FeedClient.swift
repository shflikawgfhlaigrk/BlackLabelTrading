// Black Label Trading — live feed client (SwiftUI @MainActor ObservableObject).
//
// HONEST FRAMING: this talks ONLY to the product's OWN self-contained backend (bltd_api.py,
// default http://127.0.0.1:8787). That backend serves ONLY what the buyer's own WealthCharts
// session captured into the buyer's own local store. NOTHING is fetched from Black Label / Utah /
// any third party here. When the backend is down, or the buyer's WC session is logged out, the
// client reports an honest FeedState (.offline / .loggedOut / .idle) and shows NO bars — it never
// fabricates prices. Signals-only: this client reads bars/ticks/fires; it can NEVER place a
// trade or move money.
//
// The backend URL is buyer-configurable (Settings) so a buyer can run the backend on another
// host/port on their own machine. The decode contract lives in FeedTypes.swift (test-locked).
import Foundation
import Combine

@MainActor
final class FeedClient: ObservableObject {
    // Observed, honest state — every field reflects a real backend response.
    @Published var state: FeedState = .offline
    @Published var symbols = FeedSymbols()
    @Published var lastError: String? = nil
    @Published var lastSync: Date? = nil
    @Published private(set) var connecting = false

    // Buyer-configurable backend location (own machine / own network only).
    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: Self.urlKey) }
    }
    private var token: String? = nil
    private var signedIn: Bool { token != nil }

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

    // MARK: - Capture status + symbol catalogue (the honest feed banner).
    func refreshStatus() async {
        guard signedIn else { state = .notSignedIn; return }
        guard let cap = await getJSON("/api/capture") else { state = .offline; return }
        let cs = CaptureStatus.decode(cap)
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

    // MARK: - Connect the buyer's own WealthCharts session (launches the product-owned debug
    // Chrome at WC sign-in; reports REAL reachability). Signals-only — opens a login, nothing else.
    func launchCapture() async {
        guard let req0 = authed("/api/connect") else { return }
        var req = req0; req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = "{}".data(using: .utf8)
        connecting = true; defer { connecting = false }
        _ = try? await session.data(for: req)
        await refreshStatus()
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
