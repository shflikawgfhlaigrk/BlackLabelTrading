// Black Label Trading — live feed decode layer. PURE LOGIC (no SwiftUI, no network calls).
//
// HONEST FRAMING: this is the wire-format <-> domain-model translation for the product's OWN
// self-contained backend (bltd_api.py on 127.0.0.1). The backend serves ONLY what the buyer's
// own WealthCharts session captured into the buyer's own local store — nothing is downloaded
// from us, sampled, or invented. When the store is cold / the WC session is logged out, the
// payloads are empty and decode to empty results (a real "feed offline" state upstream), NEVER
// to fabricated bars. The networking + @MainActor wiring lives in FeedClient.swift; the math
// here is verifiable headlessly so the decode contract is test-locked.
import Foundation

// MARK: - Feed connection state (drives the honest banner in the chart screen).
// Every state maps to a real, observed condition of the buyer's own capture pipeline — there is
// no "pretend live". `.live` requires the backend to report feedAvailable AND fresh ticks.
enum FeedState: Equatable {
    case offline            // backend unreachable (product backend not running)
    case notSignedIn        // backend up, no session token yet
    case loggedOut          // backend up + signed in, but the buyer's WC session is logged out
                            // (CDP not reachable / no logged-in WC page) -> no live capture
    case connecting         // launched capture chrome, waiting for the WC feed to come up
    case live               // WC feed reachable and ticks are flowing into the buyer's store
    case idle               // signed in, feed reachable, but no fresh ticks right now (market closed / quiet)

    var label: String {
        switch self {
        case .offline:     return "Backend offline"
        case .notSignedIn: return "Not connected"
        case .loggedOut:   return "WealthCharts logged out"
        case .connecting:  return "Connecting feed…"
        case .live:        return "Live feed"
        case .idle:        return "Feed connected · quiet"
        }
    }
    // Whether bars shown came from a genuinely live, flowing feed (for the pulse indicator).
    var isFlowing: Bool { self == .live }
    // Whether the user can expect real bars from the feed in this state.
    var hasData: Bool { self == .live || self == .idle }
}

// MARK: - Capture status as reported by GET /api/capture.
// Mirrors the backend's REAL pipeline probe: is the buyer's WC reachable on CDP, is the feed
// available, and which symbols have fresh ticks. Nothing here is assumed — it is observed.
struct CaptureStatus: Equatable {
    var cdpReachable = false
    var feedAvailable = false
    var feedLive = false
    var liveTicks: [String] = []

    // Reduce the observed capture probe to a single honest FeedState.
    func state(signedIn: Bool) -> FeedState {
        guard signedIn else { return .notSignedIn }
        if feedAvailable && (feedLive || !liveTicks.isEmpty) { return .live }
        if feedAvailable { return .idle }
        if cdpReachable { return .connecting }
        return .loggedOut
    }

    static func decode(_ obj: [String: Any]) -> CaptureStatus {
        var c = CaptureStatus()
        c.cdpReachable = (obj["cdpReachable"] as? Bool) ?? false
        c.feedAvailable = (obj["feedAvailable"] as? Bool) ?? false
        c.feedLive = (obj["feedLive"] as? Bool) ?? false
        c.liveTicks = (obj["liveTicks"] as? [String]) ?? []
        return c
    }
}

// MARK: - Symbol catalogue from GET /api/symbols.
struct FeedSymbols: Equatable {
    var backtestable: [String] = []   // symbols with >=40 stored bars (enough to test)
    var live: [String] = []           // symbols with bars recorded recently
    var liveTicks: [String] = []      // symbols with a fresh last-tick
    var busiest: String? = nil        // symbol with the most stored bars (good default)

    // A de-duplicated, ordered union for the symbol picker (live first, then busiest, then rest).
    var pickerList: [String] {
        var seen = Set<String>(); var out: [String] = []
        func push(_ xs: [String]) { for s in xs where !seen.contains(s) { seen.insert(s); out.append(s) } }
        push(liveTicks); push(live)
        if let b = busiest { push([b]) }
        push(backtestable)
        return out
    }

    static func decode(_ obj: [String: Any]) -> FeedSymbols {
        var s = FeedSymbols()
        s.backtestable = (obj["backtestable"] as? [String]) ?? []
        s.live = (obj["live"] as? [String]) ?? []
        s.liveTicks = (obj["liveTicks"] as? [String]) ?? []
        s.busiest = obj["busiest"] as? String
        return s
    }
}

// MARK: - Bar decode from GET /api/recent | /api/bars.
// Wire shape: {"symbol": "X", "bars": [[o,h,l,c,ts_epoch], ...]} oldest->newest.
// A malformed/short row is skipped (never coerced into a fake bar).
enum FeedBars {
    static func decode(_ obj: [String: Any]) -> [Bar] {
        guard let rows = obj["bars"] as? [[Any]] else { return [] }
        var out: [Bar] = []
        out.reserveCapacity(rows.count)
        for r in rows {
            guard r.count >= 5,
                  let o = num(r[0]), let h = num(r[1]), let l = num(r[2]),
                  let c = num(r[3]), let ts = num(r[4]) else { continue }
            // Defensive geometry: high must be the max, low the min — the store already
            // guarantees this, but we never trust a row enough to draw an impossible candle.
            let hi = max(h, max(o, c)), lo = min(l, min(o, c))
            out.append(Bar(date: Date(timeIntervalSince1970: ts), open: o, high: hi, low: lo, close: c, volume: 0))
        }
        return out.sorted { $0.date < $1.date }
    }

    static func num(_ v: Any) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
}

// MARK: - Live last-price tick from GET /api/live.
// {"symbol":"X","price":P,"ts":epoch} when a tick exists, or {"gated":true} when none.
struct LiveTick: Equatable {
    var symbol: String
    var price: Double
    var ts: Date

    static func decode(_ obj: [String: Any]) -> LiveTick? {
        if (obj["gated"] as? Bool) == true { return nil }
        guard let sym = obj["symbol"] as? String,
              let p = FeedBars.num(obj["price"] as Any),
              let t = FeedBars.num(obj["ts"] as Any) else { return nil }
        return LiveTick(symbol: sym, price: p, ts: Date(timeIntervalSince1970: t))
    }
}

// MARK: - Folding a live tick into the latest bar.
// A live last-price either (a) extends the in-progress (last) bar's high/low and moves its
// close, or (b) — when the tick is newer than the bar interval — does nothing here (a new bar
// is only printed by the backend's real aggregation, never invented client-side). This keeps
// the chart honest: the live dot moves the most-recent candle's close, it does not manufacture
// future candles.
enum LiveFold {
    /// Apply a tick to the last bar in `bars`, returning a new array. If the tick price is
    /// outside the bar's range it widens high/low; close becomes the tick price. Returns the
    /// input unchanged if there are no bars or the tick is for a different/older instant.
    static func apply(_ tick: LiveTick, to bars: [Bar]) -> [Bar] {
        guard var last = bars.last else { return bars }
        // Only fold a tick that is at or after the last bar's timestamp (never rewrite history).
        guard tick.ts >= last.date else { return bars }
        last.high = max(last.high, tick.price)
        last.low = min(last.low, tick.price)
        last.close = tick.price
        var out = bars
        out[out.count - 1] = last
        return out
    }
}

// MARK: - Self-contained backend bootstrap policy (PURE LOGIC, test-locked).
// HONEST self-containment: the product SHIPS its own backend inside the .app bundle, but whether
// the app can AUTO-SPAWN it in-process depends on the codesign/sandbox posture of the build:
//
//   * App Sandbox (com.apple.security.app-sandbox) DENIES process-exec of a non-bundled tool like
//     /bin/bash by default — verified empirically: `execvp() ... Operation not permitted`. So a
//     sandboxed build (the only kind that launches ad-hoc-signed, and the kind required for the
//     Mac App Store) CANNOT spawn launch-backend.sh. In that posture the app relies on the
//     externally-managed backend (a launchd LaunchAgent the installer registers) and otherwise
//     degrades to the honest .offline state — it NEVER fabricates a feed.
//   * A NON-sandboxed Developer-ID-signed build CAN spawn the bundled script. (No Developer ID
//     Application cert is present on this machine, so that build is not currently producible —
//     documented, not claimed.)
//
// `BackendBootstrap` makes this decision explicit + testable instead of attempting a doomed spawn
// and swallowing the failure. `_APP_SANDBOX_CONTAINER_ID` is exported into every sandboxed
// process by macOS; its presence is a reliable runtime sandbox signal.
enum BackendBootstrap: Equatable {
    /// Attempt an in-process spawn of the bundled backend (only valid for non-sandboxed builds).
    case spawnBundled
    /// Sandboxed: cannot spawn; rely on the externally-managed (launchd) backend + offline fallback.
    case relyExternal
    /// Backend URL is a custom/remote host the buyer chose — never auto-spawn anything.
    case external

    /// Pure decision. `sandboxed` = process is App-Sandboxed; `isLocalDefault` = baseURL points at
    /// the product's own localhost backend (vs a buyer-configured remote host).
    static func decide(sandboxed: Bool, isLocalDefault: Bool) -> BackendBootstrap {
        guard isLocalDefault else { return .external }
        return sandboxed ? .relyExternal : .spawnBundled
    }

    /// True only when a build can actually auto-spawn its bundled backend. Honest: false under
    /// the App Sandbox, where exec of /bin/bash is denied.
    static func canSpawn(sandboxed: Bool) -> Bool { !sandboxed }

    /// Runtime sandbox detection (macOS exports this into every sandboxed process).
    static func runtimeSandboxed(env: [String: String]) -> Bool {
        env["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// A localhost/default backend URL (the only kind the app may auto-manage).
    static func isLocalDefaultURL(_ u: String, defaultURL: String) -> Bool {
        let t = u.trimmingCharacters(in: .whitespaces)
        return t == defaultURL || t.hasPrefix("http://127.0.0.1") || t.hasPrefix("http://localhost")
    }
}
