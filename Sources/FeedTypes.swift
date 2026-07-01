// Black Label Trading — live feed decode layer. PURE LOGIC (no SwiftUI, no network calls).
//
// HONEST FRAMING: this is the wire-format <-> domain-model translation for the product's OWN
// self-contained backend (bltd_api.py on 127.0.0.1). The backend serves ONLY what the buyer's
// own Topstep webhook sender wrote into the buyer's own local store - nothing is downloaded from us,
// sampled, or invented. When the store is cold / no Topstep data has arrived, the
// payloads are empty and decode to empty results (a real "feed offline" state upstream), NEVER
// to fabricated bars. The networking + @MainActor wiring lives in FeedClient.swift; the math
// here is verifiable headlessly so the decode contract is test-locked.
import Foundation

enum TradingSymbolScope {
    private static let monthCodes = Set("FGHJKMNQUVXZ")

    static func normalized(_ raw: String?) -> String {
        var s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let dot = s.lastIndex(of: ".") {
            s = String(s[s.index(after: dot)...])
        }
        while s.first == "/" || s.first == "@" {
            s.removeFirst()
        }
        return String(s.filter { $0.isLetter || $0.isNumber })
    }

    static func isES(_ raw: String?) -> Bool {
        let s = normalized(raw)
        if s == "ES" { return true }
        guard s.count >= 4, s.hasPrefix("ES") else { return false }
        let rest = String(s.dropFirst(2))
        guard let month = rest.first, monthCodes.contains(month) else { return false }
        let year = rest.dropFirst()
        return (1...2).contains(year.count) && year.allSatisfy(\.isNumber)
    }

    static func filterES(_ symbols: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for s in symbols where isES(s) && !seen.contains(s) {
            seen.insert(s)
            out.append(s)
        }
        return out
    }

    // Shipped Topstep setup is ES-family only. Keep this filter in the client too so stale rows from
    // older local stores cannot appear in the picker if a backend response is cached or mixed.
    static func inScope(_ raw: String?) -> Bool {
        isES(raw)
    }

    static func filterScoped(_ symbols: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for s in symbols where inScope(s) && !seen.contains(s) {
            seen.insert(s)
            out.append(s)
        }
        return out
    }

    // Futures root of a contract symbol: "CM.ESU6"->"ES", "MNQU6"->"MNQ", "CLF26"->"CL". A
    // non-futures symbol (no trailing <monthCode><1-2 digits>) passes through ("EURUSD"->"EURUSD").
    static func futuresRoot(_ raw: String?) -> String {
        let chars = Array(normalized(raw))
        guard chars.count >= 3 else { return String(chars) }
        var i = chars.count - 1
        var digits = 0
        while i >= 0 && chars[i].isNumber { i -= 1; digits += 1 }
        if (1...2).contains(digits), i >= 1, monthCodes.contains(chars[i]) {
            return String(chars[0..<i])
        }
        return String(chars)
    }

    // $ per 1.00 point, by futures root. Only roots whose contract spec is KNOWN are mapped; an
    // unmapped instrument returns nil so the UI shows points only and labels dollar figures
    // "n/a for this instrument" — NEVER computes dollars with a wrong (e.g. ES $50) multiplier.
    private static let pointValues: [String: Double] = [
        "ES": 50, "MES": 5, "NQ": 20, "MNQ": 2, "YM": 5, "MYM": 0.5,
        "RTY": 50, "M2K": 5, "CL": 1000, "MCL": 100, "GC": 100, "MGC": 10, "SI": 5000,
    ]

    static func pointValue(for raw: String?) -> Double? { pointValues[futuresRoot(raw)] }

    // Clean display label for the buyer's live instrument (strips the venue prefix): "CM.ESU6"->"ESU6".
    static func displaySymbol(_ raw: String?) -> String { normalized(raw) }
}

// MARK: - Feed connection state (drives the honest banner in the chart screen).
// Every state maps to a real, observed condition of the buyer's own capture pipeline — there is
// no "pretend live". `.live` requires the backend to report feedAvailable AND fresh ticks.
enum FeedState: Equatable {
    case offline            // backend unreachable (product backend not running)
    case notSignedIn        // backend up, no session token yet
    case loggedOut          // backend up + signed in, but no webhook tick/bar has arrived
    case connecting         // webhook receiver ready, waiting for pushed market data
    case live               // webhook data reachable and ticks are flowing into the buyer's store
    case idle               // signed in, feed reachable, but no fresh ticks right now (market closed / quiet)

    var label: String {
        switch self {
        case .offline:     return "Backend offline"
        case .notSignedIn: return "Not connected"
        case .loggedOut:   return "No webhook data"
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
// Mirrors the backend's REAL pipeline probe: has the local webhook receiver seen pushed data, is
// the feed available, and which symbols have fresh ticks. Nothing here is assumed - it is observed.
struct CaptureStatus: Equatable {
    var cdpReachable = false
    var feedAvailable = false
    var feedLive = false
    var liveTicks: [String] = []
    var feedSource: String? = nil        // observed feed source key, usually webhook
    var evaluatorAlive = true            // capture-daemon evaluator heartbeat; default true so a
                                         // backend that doesn't report it never shows a false alarm

    // Reduce the observed capture probe to a single honest FeedState.
    func state(signedIn: Bool) -> FeedState {
        guard signedIn else { return .notSignedIn }
        if feedAvailable && (feedLive || !liveTicks.isEmpty) { return .live }
        if feedAvailable { return .idle }
        if cdpReachable { return .connecting }
        return .loggedOut
    }

    // Human label for the active pushed/captured source.
    var sourceLabel: String {
        switch (feedSource ?? "").lowercased() {
        case "webhook", "topstepx-bridge": return "your Topstep webhook feed"
        case "topstepx": return "your TopstepX browser feed"
        case "browser", "": return "your Topstep webhook feed"
        default: return "your Topstep feed"
        }
    }
    // Browser capture is not the surfaced feed path; retained for older call sites/tests.
    var isApiFeed: Bool {
        false
    }
    // Bars can land while the SEPARATE evaluator process is down -> signals silently stop. Surface it.
    var evaluatorDownWhileConnected: Bool { feedAvailable && !evaluatorAlive }

    static func decode(_ obj: [String: Any]) -> CaptureStatus {
        var c = CaptureStatus()
        c.cdpReachable = (obj["cdpReachable"] as? Bool) ?? false
        c.feedAvailable = (obj["feedAvailable"] as? Bool) ?? false
        c.feedLive = (obj["feedLive"] as? Bool) ?? false
        c.liveTicks = (obj["liveTicks"] as? [String]) ?? []
        c.feedSource = obj["feedSource"] as? String
        c.evaluatorAlive = (obj["evaluatorAlive"] as? Bool) ?? true
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
        s.backtestable = TradingSymbolScope.filterScoped((obj["backtestable"] as? [String]) ?? [])
        s.live = TradingSymbolScope.filterScoped((obj["live"] as? [String]) ?? [])
        s.liveTicks = TradingSymbolScope.filterScoped((obj["liveTicks"] as? [String]) ?? [])
        let busiest = obj["busiest"] as? String
        s.busiest = TradingSymbolScope.inScope(busiest) ? busiest : nil
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
            let vol = r.count >= 6 ? (num(r[5]) ?? 0) : 0   // real WC bar volume (0 on legacy rows)
            let dlt = r.count >= 7 ? (num(r[6]) ?? 0) : 0   // order-flow delta (0 on legacy rows)
            out.append(Bar(date: Date(timeIntervalSince1970: ts), open: o, high: hi, low: lo, close: c, volume: vol, delta: dlt))
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
              TradingSymbolScope.inScope(sym),
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

// MARK: - Engine roster from GET /api/screen.
// Wire: {"rows":[{engine,symbol,edge,warming,winRate,netPts,expectancyR,trades,bars,reason}]}.
// Every field is the backend's REAL per-(engine,symbol) OOS verdict on the buyer's own captured
// bars. `edge` is true ONLY when that engine proved held-out edge on real bars; `warming` is true
// when there aren't enough bars yet. Nothing here is fabricated — an empty/cold store yields [].
// The UI must NEVER hardcode a win%/net; it shows exactly these decoded values or an empty state.
struct EngineRow: Equatable, Identifiable {
    var engine: String
    var symbol: String
    var edge: Bool
    var warming: Bool
    var winRate: Double
    var netPts: Double
    var expectancyR: Double
    var trades: Int
    var bars: Int
    var reason: String
    var id: String { engine + "|" + symbol }
}

enum EngineRoster {
    // Display order for the engine fleet (generic, customer-facing ids — never internal codenames).
    static let order = ["meanrev", "breakout", "research", "momentum", "structure", "regime",
                        "channel", "context_a", "context_b"]

    // Clean human label for an engine id. Pure formatting — maps a known id to its display name
    // and title-cases any unknown id (e.g. a buyer-added engine). NEVER invents data, only labels.
    static let labels: [String: String] = [
        "meanrev": "Mean Reversion", "breakout": "Breakout", "research": "Research",
        "momentum": "Momentum", "structure": "Structure", "regime": "Regime",
        "channel": "Channel", "context_a": "Context A", "context_b": "Context B",
    ]

    static func label(for engine: String) -> String {
        if let l = labels[engine] { return l }
        // Unknown id: humanize ("foo_bar" -> "Foo Bar") rather than show a raw token.
        return engine.split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    static func decode(_ obj: [String: Any]) -> [EngineRow] {
        guard let rows = obj["rows"] as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard let e = r["engine"] as? String, let s = r["symbol"] as? String else { return nil }
            guard TradingSymbolScope.inScope(s) else { return nil }
            return EngineRow(
                engine: e, symbol: s,
                edge: (r["edge"] as? Bool) ?? false,
                warming: (r["warming"] as? Bool) ?? false,
                winRate: FeedBars.num(r["winRate"] as Any) ?? 0,
                netPts: FeedBars.num(r["netPts"] as Any) ?? 0,
                expectancyR: FeedBars.num(r["expectancyR"] as Any) ?? 0,
                trades: Int(FeedBars.num(r["trades"] as Any) ?? 0),
                bars: Int(FeedBars.num(r["bars"] as Any) ?? 0),
                reason: (r["reason"] as? String) ?? "")
        }
    }
}

// MARK: - Signal journal from GET /api/fires.
// Real recorded (non-synthetic) edge-gated fires, newest first. outcome/pnl are nil until the
// daemon grades the signal (honest — never an invented result for an open signal). A row with no
// engine/direction/entry is skipped rather than coerced into a fake fire.
struct FireRow: Equatable, Identifiable {
    var id: Int
    var engine: String
    var direction: String
    var entry: Double
    var symbol: String?
    var stop: Double?
    var target: Double?
    var rationale: String?
    var outcome: String?
    var pnl: Double?
    var ts: String?
    var tsEpoch: Double?     // raw unix epoch (seconds) — robust time anchor for chart markers
}

enum FireFeed {
    static func decode(_ obj: [String: Any]) -> [FireRow] {
        guard let rows = obj["fires"] as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard let e = r["engine"] as? String, let d = r["direction"] as? String,
                  let entry = FeedBars.num(r["entry"] as Any),
                  let sym = r["symbol"] as? String,
                  TradingSymbolScope.inScope(sym) else { return nil }
            return FireRow(
                id: Int(FeedBars.num(r["id"] as Any) ?? 0),
                engine: e, direction: d, entry: entry,
                symbol: sym,
                stop: FeedBars.num(r["stop"] as Any),
                target: FeedBars.num(r["target"] as Any),
                rationale: r["rationale"] as? String,
                outcome: r["outcome"] as? String,
                pnl: FeedBars.num(r["pnl"] as Any),
                ts: r["ts"] as? String,
                tsEpoch: FeedBars.num(r["tsEpoch"] as Any))
        }
    }
}
