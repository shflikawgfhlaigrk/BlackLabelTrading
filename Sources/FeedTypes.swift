// Black Label Trading — live feed decode layer. PURE LOGIC (no SwiftUI, no network calls).
//
// HONEST FRAMING: this is the wire-format <-> domain-model translation for the product's OWN
// self-contained backend (bltd_api.py on 127.0.0.1). The backend serves ONLY what the buyer's
// own browser bridge or webhook sender wrote into the buyer's own local store - nothing is downloaded from us,
// sampled, or invented. When the store is cold / no browser feed data has arrived, the
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

    // WealthCharts can stream multiple real instruments. Keep only sane non-empty symbols in the
    // client; ES-family checks remain available for factors that are genuinely ES-specific.
    static func inScope(_ raw: String?) -> Bool {
        !normalized(raw).isEmpty
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
        case "wealthcharts-bridge": return "your WealthCharts webhook feed"
        case "topstepx": return "your TopstepX browser feed"
        case "wealthcharts": return "your WealthCharts browser feed"
        case "browser", "": return "your browser feed"
        default: return "your captured feed"
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
// bars. `edge` means the row cleared this screening gate; it is research evidence, not adoption.
// `warming` is true when there aren't enough bars yet. Nothing here is fabricated — an empty/cold
// store yields [].
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
    // Seven distinct implementations are selectable. The two retired ids remain decodable so old
    // journals/reference artifacts still render, but they never create duplicate picker entries.
    static let order = ["meanrev", "breakout", "momentum", "structure", "regime", "channel",
                        "context_b"]
    static let historicalAliases = ["research": "breakout", "context_a": "momentum"]

    // Clean human label for an engine id. Pure formatting — maps a known id to its display name
    // and title-cases any unknown id (e.g. a buyer-added engine). NEVER invents data, only labels.
    static let labels: [String: String] = [
        "meanrev": "Mean Reversion", "breakout": "Breakout", "momentum": "Momentum",
        "structure": "Structure", "regime": "Regime", "channel": "Channel",
        "context_b": "Context B",
    ]

    static func canonicalID(for engine: String) -> String {
        historicalAliases[engine] ?? engine
    }

    static func label(for engine: String) -> String {
        let canonical = canonicalID(for: engine)
        if let l = labels[canonical] { return l }
        // Unknown id: humanize ("foo_bar" -> "Foo Bar") rather than show a raw token.
        return canonical.split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    static func decode(_ obj: [String: Any]) -> [EngineRow] {
        guard let rows = obj["rows"] as? [[String: Any]] else { return [] }
        var decoded: [EngineRow] = []
        var indexByID: [String: Int] = [:]
        var sourceWasCanonical: [Bool] = []
        for r in rows {
            guard let rawEngine = r["engine"] as? String, let s = r["symbol"] as? String,
                  TradingSymbolScope.inScope(s) else { continue }
            let engine = canonicalID(for: rawEngine)
            let row = EngineRow(
                engine: engine, symbol: s,
                edge: (r["edge"] as? Bool) ?? false,
                warming: (r["warming"] as? Bool) ?? false,
                winRate: FeedBars.num(r["winRate"] as Any) ?? 0,
                netPts: FeedBars.num(r["netPts"] as Any) ?? 0,
                expectancyR: FeedBars.num(r["expectancyR"] as Any) ?? 0,
                trades: Int(FeedBars.num(r["trades"] as Any) ?? 0),
                bars: Int(FeedBars.num(r["bars"] as Any) ?? 0),
                reason: (r["reason"] as? String) ?? "")
            let isCanonical = rawEngine == engine
            if let index = indexByID[row.id] {
                // If both an old alias and its canonical id arrive, keep one honest row and prefer
                // the canonical source regardless of wire order.
                if isCanonical && !sourceWasCanonical[index] {
                    decoded[index] = row
                    sourceWasCanonical[index] = true
                }
            } else {
                indexByID[row.id] = decoded.count
                decoded.append(row)
                sourceWasCanonical.append(isCanonical)
            }
        }
        return decoded
    }
}

// MARK: - Live gate verdict for the buyer's OWN bars (the "NO EDGE TODAY" hero).
// A pure roll-up of the engine fleet (decoded EngineRows from GET /api/screen) into the single
// honest headline a buyer needs first: how many of their engines have NO edge on their captured
// bars today, how many are still warming, and how many (if any) cleared this research screen. It
// NEVER fabricates — an empty fleet (no captured bars) is `hasData == false`, and the counts are
// grouped straight from the real per-engine rows. No aggregate win-rate, no P&L, no promise.
struct GateReject: Equatable, Identifiable {
    var engine: String       // engine id (label via EngineRoster.label)
    var reason: String       // the engine's honest reject/why-no-edge line
    var id: String { engine }
}

struct GateVerdict: Equatable {
    var hasData: Bool        // false when no bars captured yet (fleet empty)
    var evaluated: Int       // engines actually evaluated on the buyer's bars
    var candidates: Int      // legacy count: engines with >=1 row that cleared this screen
    var warming: Int         // engines still warming (insufficient bars)
    var noEdge: Int          // engines evaluated with a sufficient sample but no edge
    var rejects: [GateReject]   // per no-edge/warming engine, the honest reason (passes excluded)

    // A screen pass is deliberately not described as proof, promotion, or live adoption.
    var headline: String {
        if !hasData { return "No bars captured yet" }
        if candidates > 0 {
            return "\(candidates) of \(evaluated) engine\(evaluated == 1 ? "" : "s"): research screen pass on your bars"
        }
        return "\(noEdge + warming) of \(evaluated) engine\(evaluated == 1 ? "" : "s"): no edge on your bars today"
    }

    var subline: String {
        if !hasData {
            return "Connect your feed and let bars accumulate — the gate verdict is computed only from your own captured bars."
        }
        var parts: [String] = []
        if candidates > 0 {
            parts.append("\(candidates) screen pass\(candidates == 1 ? "" : "es") — nested confirmation required; never live-adopted by this screen")
        }
        if noEdge > 0 { parts.append("\(noEdge) no edge") }
        if warming > 0 { parts.append("\(warming) still warming") }
        return parts.joined(separator: " · ")
    }

    // True when the honest verdict is "no engine has an edge on your bars right now".
    var isNoEdge: Bool { hasData && candidates == 0 }

    // Group the fleet by engine and roll each up to a single honest status. `fleet` is the decoded
    // /api/screen rows for the buyer's own bars; an engine "has edge" if ANY of its symbol rows
    // cleared the gate, is "warming" if all its rows are warming, else "no edge".
    static func compute(_ fleet: [EngineRow]) -> GateVerdict {
        if fleet.isEmpty {
            return GateVerdict(hasData: false, evaluated: 0, candidates: 0, warming: 0, noEdge: 0, rejects: [])
        }
        // Preserve roster order for a stable, non-arbitrary reject list.
        var order: [String] = []
        var byEngine: [String: [EngineRow]] = [:]
        for r in fleet {
            if byEngine[r.engine] == nil { order.append(r.engine) }
            byEngine[r.engine, default: []].append(r)
        }
        let ordered = EngineRoster.order.filter { byEngine[$0] != nil }
            + order.filter { !EngineRoster.order.contains($0) }
        var candidates = 0, warming = 0, noEdge = 0
        var rejects: [GateReject] = []
        for eng in ordered {
            let rows = byEngine[eng] ?? []
            let hasEdge = rows.contains { $0.edge }
            let allWarming = !rows.isEmpty && rows.allSatisfy { $0.warming }
            if hasEdge {
                candidates += 1
                continue                       // screen passes are surfaced elsewhere, not as rejects
            } else if allWarming {
                warming += 1
            } else {
                noEdge += 1
            }
            // Best reason to show: the row with the largest OOS sample (most trades) is the most
            // informative "why no edge"; fall back to the first row's reason.
            let best = rows.max(by: { $0.trades < $1.trades }) ?? rows.first
            let reason = best?.reason.isEmpty == false ? best!.reason
                : (allWarming ? "warming — not enough of your bars yet" : "no edge on your captured bars")
            rejects.append(GateReject(engine: eng, reason: reason))
        }
        return GateVerdict(hasData: true, evaluated: ordered.count,
                           candidates: candidates, warming: warming, noEdge: noEdge, rejects: rejects)
    }
}

// MARK: - Reference OOS verdicts from GET /api/reference.
// Black Label's edge-gate result computed on OUR OWN historical ES bars by the shipped provers —
// so a cold buyer (no captured bars yet) can see the gate produce a real, earned verdict. This is
// REFERENCE ONLY: historical ES, NOT the buyer's account, NOT a promise. There is NO aggregate
// win-rate / blended equity curve / "verified-live" claim — an engine with no edge decodes as
// status "no_edge". Every field is decoded straight from the artifact; nothing is invented.
struct ReferenceContract: Equatable {
    var symbol: String
    var bars: Int
    var from: String?
    var to: String?
    var proven: Bool
    var trades: Int
    var winRate: Double
    var expectancyR: Double
    var netPts: Double
    var verdict: String
    var reason: String
}

struct ReferenceEngine: Equatable, Identifiable {
    var engine: String
    var status: String            // "candidate" (cleared significance on >=1 contract) | "no_edge"
    var contracts: [ReferenceContract]
    var id: String { engine }
    var isCandidate: Bool { status == "candidate" }
}

struct ReferenceReport: Equatable {
    var available: Bool
    var label: String
    var disclaimer: String
    var source: String
    var generatedUTC: String
    var proverSHA: String
    var candidateCount: Int
    var engineCount: Int
    var engines: [ReferenceEngine]
    var reason: String?           // set when available == false (honest pending/empty state)

    static let empty = ReferenceReport(available: false,
        label: "Reference only — computed on historical ES data, NOT your account, NOT a promise, no performance guaranteed.",
        disclaimer: "", source: "", generatedUTC: "", proverSHA: "",
        candidateCount: 0, engineCount: 0, engines: [], reason: "reference verdicts unavailable")

    static func decode(_ obj: [String: Any]) -> ReferenceReport {
        let available = (obj["available"] as? Bool) ?? false
        let label = (obj["label"] as? String) ?? ReferenceReport.empty.label
        if !available {
            return ReferenceReport(available: false, label: label,
                disclaimer: (obj["disclaimer"] as? String) ?? "", source: "", generatedUTC: "",
                proverSHA: "", candidateCount: 0, engineCount: 0, engines: [],
                reason: (obj["reason"] as? String) ?? "reference verdicts unavailable")
        }
        let engines: [ReferenceEngine] = ((obj["engines"] as? [[String: Any]]) ?? []).compactMap { e in
            guard let id = e["engine"] as? String else { return nil }
            let contracts: [ReferenceContract] = ((e["contracts"] as? [[String: Any]]) ?? []).compactMap { c in
                guard let sym = c["symbol"] as? String else { return nil }
                return ReferenceContract(
                    symbol: sym,
                    bars: Int(FeedBars.num(c["bars"] as Any) ?? 0),
                    from: c["from"] as? String, to: c["to"] as? String,
                    proven: (c["proven"] as? Bool) ?? false,
                    trades: Int(FeedBars.num(c["trades"] as Any) ?? 0),
                    winRate: FeedBars.num(c["winRate"] as Any) ?? 0,
                    expectancyR: FeedBars.num(c["expectancyR"] as Any) ?? 0,
                    netPts: FeedBars.num(c["netPts"] as Any) ?? 0,
                    verdict: (c["verdict"] as? String) ?? "",
                    reason: (c["reason"] as? String) ?? "")
            }
            return ReferenceEngine(engine: id,
                                   status: (e["status"] as? String) ?? "no_edge",
                                   contracts: contracts)
        }
        return ReferenceReport(
            available: true, label: label,
            disclaimer: (obj["disclaimer"] as? String) ?? "",
            source: (obj["source"] as? String) ?? "",
            generatedUTC: (obj["generated_utc"] as? String) ?? "",
            proverSHA: (obj["prover_sha"] as? String) ?? "",
            candidateCount: Int(FeedBars.num(obj["candidateCount"] as Any) ?? 0),
            engineCount: Int(FeedBars.num(obj["engineCount"] as Any) ?? 0),
            engines: engines, reason: nil)
    }
}

// MARK: - Buyer-triggered gate re-run from GET /api/gate/rerun.
// The one-click "re-run the edge gate on MY bars" result: the SAME shipped provers (SIG_MIN_N=30,
// one-sided realized-mean-R p<0.05 with serial-dependence penalty, grid-wide FDR) run live over
// the buyer's OWN captured bars, stamped
// with the prover-source sha256 so it is reproducible (`shasum -a 256 bltd_store.py`). Every field
// is decoded straight from the artifact — no aggregate win-rate, no equity, no $ claim, no promise.
// A thin sample decodes as `insufficient` (n < minTrades); an empty store as `available == false`.
struct GateRerunContract: Equatable, Identifiable {
    var symbol: String
    var bars: Int
    var trades: Int          // n — OOS trades
    var wins: Int
    var losses: Int
    var winRate: Double
    var netPts: Double
    var expectancyR: Double
    var maxDrawdownR: Double
    var pEdge: Double
    var proven: Bool
    var insufficient: Bool
    var fdrRejected: Bool
    var reason: String
    var id: String { symbol }

    // Reproducible one-line stat block for the UI — the raw numbers, no interpretation.
    // e.g. "n=51 · 33W/18L · net +12.30 pts · maxDD 4.00R · p=0.001". When insufficient, n is shown
    // honestly with the "< min" note instead of a p-value that can't be trusted.
    func statLine(minTrades: Int) -> String {
        if trades == 0 { return "n=0 · no trades triggered on your bars" }
        let base = "n=\(trades) · \(wins)W/\(losses)L · net \(String(format: "%+.2f", netPts)) pts · maxDD \(String(format: "%.2f", maxDrawdownR))R"
        if insufficient { return base + " · p n/a (n<\(minTrades))" }
        return base + " · p=\(String(format: "%.3f", pEdge))"
    }
}

struct GateRerunEngine: Equatable, Identifiable {
    var engine: String
    var status: String       // "candidate" | "no_edge" | "insufficient"
    var contracts: [GateRerunContract]
    var id: String { engine }
    var isCandidate: Bool { status == "candidate" }
    var isInsufficient: Bool { status == "insufficient" }
    // The contract to headline: the proven one if any, else the largest real sample, else the first.
    var best: GateRerunContract? {
        contracts.first(where: { $0.proven })
            ?? contracts.max(by: { $0.trades < $1.trades })
            ?? contracts.first
    }
}

struct GateRerunReport: Equatable {
    var available: Bool
    var label: String
    var source: String
    var proverSHA: String
    var minTrades: Int
    var alpha: Double
    var test: String
    var generatedUTC: String
    var symbols: [String]
    var engineCount: Int
    var candidateCount: Int
    var noEdgeCount: Int
    var insufficientCount: Int
    var engines: [GateRerunEngine]
    var reason: String?

    static let empty = GateRerunReport(
        available: false,
        label: "Re-run of the edge-gate on YOUR captured bars — reproducible, not a promise, no performance guaranteed.",
        source: "", proverSHA: "", minTrades: 30, alpha: 0.05, test: "", generatedUTC: "",
        symbols: [], engineCount: 0, candidateCount: 0, noEdgeCount: 0, insufficientCount: 0,
        engines: [], reason: nil)

    // Provenance line — the whole run is reproducible from this.
    var proverLine: String {
        "prover \(proverSHA.isEmpty ? "—" : proverSHA) · mean-R p<\(String(format: "%.2f", alpha)) · serial-aware · min n \(minTrades)"
    }

    static func decode(_ obj: [String: Any]) -> GateRerunReport {
        let available = (obj["available"] as? Bool) ?? false
        var out = GateRerunReport.empty
        out.available = available
        out.label = (obj["label"] as? String) ?? out.label
        out.source = (obj["source"] as? String) ?? ""
        out.proverSHA = (obj["prover_sha"] as? String) ?? ""
        out.minTrades = Int(FeedBars.num(obj["sigMinN"] as Any) ?? 30)
        out.alpha = FeedBars.num(obj["alpha"] as Any) ?? 0.05
        out.test = (obj["test"] as? String) ?? ""
        out.generatedUTC = (obj["generatedUTC"] as? String) ?? ""
        out.symbols = (obj["symbols"] as? [String]) ?? []
        out.engineCount = Int(FeedBars.num(obj["engineCount"] as Any) ?? 0)
        out.candidateCount = Int(FeedBars.num(obj["candidateCount"] as Any) ?? 0)
        out.noEdgeCount = Int(FeedBars.num(obj["noEdgeCount"] as Any) ?? 0)
        out.insufficientCount = Int(FeedBars.num(obj["insufficientCount"] as Any) ?? 0)
        out.reason = obj["reason"] as? String
        out.engines = ((obj["engines"] as? [[String: Any]]) ?? []).compactMap { e in
            guard let id = e["engine"] as? String else { return nil }
            let contracts: [GateRerunContract] = ((e["contracts"] as? [[String: Any]]) ?? []).compactMap { c in
                guard let sym = c["symbol"] as? String, TradingSymbolScope.inScope(sym) else { return nil }
                return GateRerunContract(
                    symbol: sym,
                    bars: Int(FeedBars.num(c["bars"] as Any) ?? 0),
                    trades: Int(FeedBars.num(c["trades"] as Any) ?? 0),
                    wins: Int(FeedBars.num(c["wins"] as Any) ?? 0),
                    losses: Int(FeedBars.num(c["losses"] as Any) ?? 0),
                    winRate: FeedBars.num(c["winRate"] as Any) ?? 0,
                    netPts: FeedBars.num(c["netPts"] as Any) ?? 0,
                    expectancyR: FeedBars.num(c["expectancyR"] as Any) ?? 0,
                    maxDrawdownR: FeedBars.num(c["maxDrawdownR"] as Any) ?? 0,
                    pEdge: FeedBars.num(c["pEdge"] as Any) ?? 1.0,
                    proven: (c["proven"] as? Bool) ?? false,
                    insufficient: (c["insufficient"] as? Bool) ?? false,
                    fdrRejected: (c["fdrRejected"] as? Bool) ?? false,
                    reason: (c["reason"] as? String) ?? "")
            }
            return GateRerunEngine(engine: id,
                                   status: (e["status"] as? String) ?? "no_edge",
                                   contracts: contracts)
        }
        return out
    }
}

// MARK: - Instrument catalog from GET /api/instruments (TR-05 multi-asset product layer).
// Enumerates the instruments actually present in the buyer's OWN captured bars, each classified by
// asset class + whether the ES-tuned modules apply. NEVER a hardcoded list — the backend derives it
// from the bars table, so it only ever names instruments the buyer really has. `onlyES` is the honest
// "only ES captured so far" state (not an empty promise of multi-asset coverage).
struct InstrumentInfo: Equatable, Identifiable {
    var symbol: String        // raw captured symbol (venue prefix preserved), e.g. "CM.MNQU6"
    var display: String       // clean token, e.g. "MNQU6"
    var root: String          // futures root / ticker, e.g. "MNQ"
    var assetClass: String    // us_index_future / energy_future / metal_future / equity_etf / other …
    var pointValue: Double?   // $ per 1.00 point when the contract spec is known, else nil (points only)
    var esFamily: Bool
    var esModules: Bool       // whether the ES-tuned Session/SMT modules apply (== esFamily)
    var bars: Int
    var live: Bool
    var backtestable: Bool
    var id: String { symbol }

    // Human asset-class label for the picker.
    var assetClassLabel: String {
        switch assetClass {
        case "us_index_future": return "US index future"
        case "energy_future":   return "Energy future"
        case "metal_future":    return "Metal future"
        case "rates_future":    return "Rates future"
        case "fx_future":       return "FX future"
        case "crypto_future":   return "Crypto future"
        case "other_future":    return "Future"
        case "equity_etf":      return "Equity / ETF"
        default:                return "Other"
        }
    }
    // Honest per-instrument module note (never silent wrong math).
    var moduleNote: String {
        esModules ? "All modules apply (ES-tuned Session + SMT active)"
                  : "Session + SMT are ES-only — absent here; all other modules apply"
    }
    var dollarNote: String {
        if let pv = pointValue {
            let s = pv == pv.rounded() ? String(Int(pv)) : String(format: "%.2f", pv)
            return "$\(s)/pt"
        }
        return "points only (no contract multiplier)"
    }
}

struct InstrumentCatalog: Equatable {
    var available: Bool
    var count: Int
    var esFamilyCount: Int
    var nonEsCount: Int
    var onlyES: Bool
    var label: String
    var esModulesNote: String
    var instruments: [InstrumentInfo]
    var reason: String?

    static let empty = InstrumentCatalog(
        available: false, count: 0, esFamilyCount: 0, nonEsCount: 0, onlyES: false,
        label: "", esModulesNote: "", instruments: [], reason: nil)

    // Honest headline for the picker header.
    var headline: String {
        if !available { return "No instruments captured yet — connect your feed and let bars accumulate." }
        if onlyES { return "Only ES captured so far — connect your feed and capture NQ/YM/CL/ETFs to analyze them here." }
        return "\(count) instrument\(count == 1 ? "" : "s") captured · \(nonEsCount) non-ES · each analyzed on its own bars."
    }

    static func decode(_ obj: [String: Any]) -> InstrumentCatalog {
        var out = InstrumentCatalog.empty
        out.available = (obj["available"] as? Bool) ?? false
        out.count = Int(FeedBars.num(obj["count"] as Any) ?? 0)
        out.esFamilyCount = Int(FeedBars.num(obj["esFamilyCount"] as Any) ?? 0)
        out.nonEsCount = Int(FeedBars.num(obj["nonEsCount"] as Any) ?? 0)
        out.onlyES = (obj["onlyES"] as? Bool) ?? false
        out.label = (obj["label"] as? String) ?? ""
        out.esModulesNote = (obj["esModulesNote"] as? String) ?? ""
        out.reason = obj["reason"] as? String
        out.instruments = ((obj["instruments"] as? [[String: Any]]) ?? []).compactMap { i in
            guard let sym = i["symbol"] as? String, TradingSymbolScope.inScope(sym) else { return nil }
            return InstrumentInfo(
                symbol: sym,
                display: (i["display"] as? String) ?? TradingSymbolScope.displaySymbol(sym),
                root: (i["root"] as? String) ?? "",
                assetClass: (i["assetClass"] as? String) ?? "other",
                pointValue: (i["pointValue"] as? NSNull) == nil ? FeedBars.num(i["pointValue"] as Any) : nil,
                esFamily: (i["esFamily"] as? Bool) ?? false,
                esModules: (i["esModules"] as? Bool) ?? false,
                bars: Int(FeedBars.num(i["bars"] as Any) ?? 0),
                live: (i["live"] as? Bool) ?? false,
                backtestable: (i["backtestable"] as? Bool) ?? false)
        }
        return out
    }
}

// MARK: - No-code backtest lab from GET /api/backtest/run.
// The buyer picks ONE engine + ONE instrument + an optional date range; the backend runs the SAME
// shipped prover (bltd_store.PROVERS) on their OWN captured bars, split into contiguous folds, and
// returns per-fold n / W / L / max-drawdown-R / p-value + the prover sha256. NO aggregate win-rate,
// NO equity, NO $ figure, NO promise — the buyer's own edge math on their own chosen slice. A fold
// with fewer than minTrades OOS trades decodes as `insufficient` (significance not assessed).
struct BacktestLabFold: Equatable, Identifiable {
    var fold: Int
    var bars: Int
    var trades: Int          // n — OOS trades
    var wins: Int
    var losses: Int
    var winRate: Double
    var netPts: Double
    var expectancyR: Double
    var maxDrawdownR: Double
    var pEdge: Double
    var proven: Bool
    var insufficient: Bool
    var reason: String
    var id: Int { fold }

    // Raw, reproducible stat line — no interpretation, no headline metric.
    func statLine(minTrades: Int) -> String {
        if trades == 0 { return "n=0 · no trades triggered on your bars" }
        let base = "n=\(trades) · \(wins)W/\(losses)L · net \(String(format: "%+.2f", netPts)) pts · maxDD \(String(format: "%.2f", maxDrawdownR))R"
        if insufficient { return base + " · p n/a (n<\(minTrades))" }
        return base + " · p=\(String(format: "%.3f", pEdge))"
    }
}

struct BacktestLabReport: Equatable {
    var available: Bool
    var engine: String
    var symbol: String
    var label: String
    var source: String
    var proverSHA: String
    var minTrades: Int
    var alpha: Double
    var test: String
    var generatedUTC: String
    var totalBars: Int
    var status: String       // "candidate" | "no_edge" | "insufficient"
    var whole: BacktestLabFold?
    var folds: [BacktestLabFold]
    var reason: String

    static let empty = BacktestLabReport(
        available: false, engine: "", symbol: "",
        label: "Run of the SHIPPED edge-gate prover on YOUR captured bars only — reproducible, not a promise, no performance guaranteed.",
        source: "", proverSHA: "", minTrades: 30, alpha: 0.05, test: "", generatedUTC: "",
        totalBars: 0, status: "insufficient", whole: nil, folds: [], reason: "")

    var proverLine: String {
        "prover \(proverSHA.isEmpty ? "—" : proverSHA) · mean-R p<\(String(format: "%.2f", alpha)) · serial-aware · min n \(minTrades)"
    }

    private static func decodeFold(_ f: [String: Any]) -> BacktestLabFold {
        BacktestLabFold(
            fold: Int(FeedBars.num(f["fold"] as Any) ?? 0),
            bars: Int(FeedBars.num(f["bars"] as Any) ?? 0),
            trades: Int(FeedBars.num(f["trades"] as Any) ?? 0),
            wins: Int(FeedBars.num(f["wins"] as Any) ?? 0),
            losses: Int(FeedBars.num(f["losses"] as Any) ?? 0),
            winRate: FeedBars.num(f["winRate"] as Any) ?? 0,
            netPts: FeedBars.num(f["netPts"] as Any) ?? 0,
            expectancyR: FeedBars.num(f["expectancyR"] as Any) ?? 0,
            maxDrawdownR: FeedBars.num(f["maxDrawdownR"] as Any) ?? 0,
            pEdge: FeedBars.num(f["pEdge"] as Any) ?? 1.0,
            proven: (f["proven"] as? Bool) ?? false,
            insufficient: (f["insufficient"] as? Bool) ?? false,
            reason: (f["reason"] as? String) ?? "")
    }

    static func decode(_ obj: [String: Any]) -> BacktestLabReport {
        var out = BacktestLabReport.empty
        out.available = (obj["available"] as? Bool) ?? false
        out.engine = (obj["engine"] as? String) ?? ""
        out.symbol = (obj["symbol"] as? String) ?? ""
        out.label = (obj["label"] as? String) ?? out.label
        out.source = (obj["source"] as? String) ?? ""
        out.proverSHA = (obj["prover_sha"] as? String) ?? ""
        out.minTrades = Int(FeedBars.num(obj["sigMinN"] as Any) ?? 30)
        out.alpha = FeedBars.num(obj["alpha"] as Any) ?? 0.05
        out.test = (obj["test"] as? String) ?? ""
        out.generatedUTC = (obj["generatedUTC"] as? String) ?? ""
        out.totalBars = Int(FeedBars.num(obj["totalBars"] as Any) ?? 0)
        out.status = (obj["status"] as? String) ?? "insufficient"
        out.reason = (obj["reason"] as? String) ?? ""
        if let w = obj["whole"] as? [String: Any] { out.whole = decodeFold(w) }
        out.folds = ((obj["folds"] as? [[String: Any]]) ?? []).map { decodeFold($0) }
        return out
    }
}

// MARK: - TR-19 local parameter research screen from GET /api/backtest/farm.
// The buyer picks ONE engine + ONE instrument; the backend fans the fixed research grid across this
// Mac's cores over their OWN captured bars — no cloud, no data fee, no egress. Every cell reports
// n / W / L / max-drawdown-R and a Benjamini–Hochberg FDR-corrected p across the WHOLE grid
// (`pEdgeAdj`). A raw best-cell p is NEVER surfaced. A passing cell is only selected for a separate
// nested confirmation protocol; this report never enables or live-adopts a strategy.
struct BacktestFarmCell: Equatable, Identifiable {
    var index: Int
    var params: String       // human-readable parameter set, e.g. "lookback=20 · mrZ=2.0"
    var trades: Int
    var wins: Int
    var losses: Int
    var netPts: Double
    var maxDrawdownR: Double
    var pEdgeAdj: Double      // BH-FDR-corrected — the ONLY p shown as significance
    // Decoded from the legacy wire key `proven`; semantically this is only a screen selection.
    var selectedForConfirmation: Bool
    var insufficient: Bool
    var reason: String
    var id: Int { index }

    // Raw, reproducible stat line — trade count + FDR-adjusted p, never a headline win-rate/$.
    var statLine: String {
        if trades == 0 { return "n=0 · no trades on your bars" }
        let base = "n=\(trades) · \(wins)W/\(losses)L · net \(String(format: "%+.2f", netPts)) pts · maxDD \(String(format: "%.2f", maxDrawdownR))R"
        if insufficient { return base + " · p n/a (n<min)" }
        return base + " · FDR-adj p=\(String(format: "%.3f", pEdgeAdj))"
    }
}

struct BacktestFarmReport: Equatable {
    var available: Bool
    var engine: String
    var symbol: String
    var label: String
    var overfitNote: String
    var proverSHA: String
    var minTrades: Int
    var alpha: Double
    var fdrQ: Double
    var compute: String       // "process-pool (N workers)" | "serial …" — honest, never faked
    var cores: Int
    var generatedUTC: String
    var totalBars: Int
    var cellsTried: Int
    // Decoded from the legacy wire key `provenCells`; no selected cell is enabled or adopted.
    var selectionCount: Int
    var cellsInsufficient: Int
    var cellsSufficient: Int
    var gridSize: Int
    var gridTruncated: Bool
    var status: String        // legacy wire: "candidate" means selection-only, never adoption
    var best: BacktestFarmCell?
    var cells: [BacktestFarmCell]
    var reason: String

    static let empty = BacktestFarmReport(
        available: false, engine: "", symbol: "",
        label: "Parameter research screen on YOUR captured bars only — reproducible research, never live-adopted by this screen.",
        overfitNote: "Best-of-N parameter screening inflates significance. Every p is Benjamini–Hochberg FDR-corrected across all cells tried; a raw best-cell p is never shown. A selection still requires separate nested confirmation.",
        proverSHA: "", minTrades: 30, alpha: 0.05, fdrQ: 0.10, compute: "", cores: 0,
        generatedUTC: "", totalBars: 0, cellsTried: 0, selectionCount: 0, cellsInsufficient: 0,
        cellsSufficient: 0, gridSize: 0, gridTruncated: false, status: "insufficient",
        best: nil, cells: [], reason: "")

    var proverLine: String {
        "prover \(proverSHA.isEmpty ? "—" : proverSHA) · BH-FDR q≤\(String(format: "%.2f", fdrQ)) · min n \(minTrades)"
    }

    private static func paramString(_ p: [String: Any]) -> String {
        p.keys.sorted().map { k -> String in
            let v = p[k]
            if let d = FeedBars.num(v as Any) {
                // integers without a trailing ".0"; floats to 2dp
                return d == d.rounded() ? "\(k)=\(Int(d))" : "\(k)=\(String(format: "%.2f", d))"
            }
            return "\(k)=\(v ?? "")"
        }.joined(separator: " · ")
    }

    private static func decodeCell(_ c: [String: Any], _ idx: Int) -> BacktestFarmCell {
        BacktestFarmCell(
            index: idx,
            params: paramString((c["params"] as? [String: Any]) ?? [:]),
            trades: Int(FeedBars.num(c["trades"] as Any) ?? 0),
            wins: Int(FeedBars.num(c["wins"] as Any) ?? 0),
            losses: Int(FeedBars.num(c["losses"] as Any) ?? 0),
            netPts: FeedBars.num(c["netPts"] as Any) ?? 0,
            maxDrawdownR: FeedBars.num(c["maxDrawdownR"] as Any) ?? 0,
            pEdgeAdj: FeedBars.num(c["pEdgeAdj"] as Any) ?? 1.0,
            selectedForConfirmation: (c["proven"] as? Bool) ?? false,
            insufficient: (c["insufficient"] as? Bool) ?? false,
            reason: (c["reason"] as? String) ?? "")
    }

    static func decode(_ obj: [String: Any]) -> BacktestFarmReport {
        var out = BacktestFarmReport.empty
        out.available = (obj["available"] as? Bool) ?? false
        out.engine = (obj["engine"] as? String) ?? ""
        out.symbol = (obj["symbol"] as? String) ?? ""
        out.label = (obj["label"] as? String) ?? out.label
        out.overfitNote = (obj["overfitNote"] as? String) ?? out.overfitNote
        out.proverSHA = (obj["prover_sha"] as? String) ?? ""
        out.minTrades = Int(FeedBars.num(obj["sigMinN"] as Any) ?? 30)
        out.alpha = FeedBars.num(obj["alpha"] as Any) ?? 0.05
        out.fdrQ = FeedBars.num(obj["fdrQ"] as Any) ?? 0.10
        out.compute = (obj["compute"] as? String) ?? ""
        out.cores = Int(FeedBars.num(obj["cores"] as Any) ?? 0)
        out.generatedUTC = (obj["generatedUTC"] as? String) ?? ""
        out.totalBars = Int(FeedBars.num(obj["totalBars"] as Any) ?? 0)
        out.cellsTried = Int(FeedBars.num(obj["cellsTried"] as Any) ?? 0)
        out.selectionCount = Int(FeedBars.num(obj["provenCells"] as Any) ?? 0)
        out.cellsInsufficient = Int(FeedBars.num(obj["cellsInsufficient"] as Any) ?? 0)
        out.cellsSufficient = Int(FeedBars.num(obj["cellsSufficient"] as Any) ?? 0)
        out.gridSize = Int(FeedBars.num(obj["gridSize"] as Any) ?? 0)
        out.gridTruncated = (obj["gridTruncated"] as? Bool) ?? false
        out.status = (obj["status"] as? String) ?? "insufficient"
        out.reason = (obj["reason"] as? String) ?? ""
        let rawCells = (obj["cells"] as? [[String: Any]]) ?? []
        out.cells = rawCells.enumerated().map { decodeCell($1, $0) }
        if let b = obj["best"] as? [String: Any] { out.best = decodeCell(b, -1) }
        return out
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

// MARK: - TR-06 honest alert models (decoded from /api/alerts/*).

/// Token-free view of the alert configuration (GET /api/alerts/status). Never carries the Pushover
/// token/user or a raw endpoint query — the backend redacts before it reaches here.
struct AlertStatus: Equatable {
    var enabled: Bool
    var provider: String
    var endpoint: String
    var configured: Bool
    var egressOk: Bool
    var pushoverConfigured: Bool
    var note: String

    static let empty = AlertStatus(enabled: false, provider: "ntfy", endpoint: "",
                                   configured: false, egressOk: false, pushoverConfigured: false,
                                   note: "")

    static func decode(_ obj: [String: Any]) -> AlertStatus {
        AlertStatus(
            enabled: (obj["enabled"] as? Bool) ?? false,
            provider: (obj["provider"] as? String) ?? "ntfy",
            endpoint: (obj["endpoint"] as? String) ?? "",
            configured: (obj["configured"] as? Bool) ?? false,
            egressOk: (obj["egressOk"] as? Bool) ?? false,
            pushoverConfigured: (obj["pushoverConfigured"] as? Bool) ?? false,
            note: (obj["note"] as? String) ?? "")
    }
}

/// The honest result of a test / send (POST /api/alerts/{test,send}). `sent` means the buyer's
/// endpoint accepted the POST — "posted", never "delivered". `networked` is false when the app made
/// no network call at all (off / no endpoint), which is the provable no-egress state.
struct AlertSendResult: Equatable {
    var sent: Bool
    var networked: Bool
    var reason: String
    var summary: String

    static let unreachable = AlertSendResult(sent: false, networked: false,
                                             reason: "backend unreachable", summary: "")

    static func decode(_ obj: [String: Any]) -> AlertSendResult {
        AlertSendResult(
            sent: (obj["sent"] as? Bool) ?? false,
            networked: (obj["networked"] as? Bool) ?? false,
            reason: (obj["reason"] as? String) ?? "",
            summary: (obj["summary"] as? String) ?? "")
    }
}
