// EngineFireMarkers.swift — PURE mapping of the buyer's REAL recorded edge-gated fires
// (FireRow, straight from the product's own `fires` table) onto chart candles, as per-engine
// markers + a naming/status legend. NO SwiftUI, NO network — same file compiles into the app,
// the test target, and the headless render-proof.
//
// HONEST BY CONSTRUCTION:
//   • A marker is drawn ONLY at a real fire whose timestamp lands inside the plotted candle
//     window. A fire outside the window is counted in the legend but never marked.
//   • An engine with no fires for the displayed symbol shows QUIET in the legend (no marker,
//     no fabricated count). e.g. context_a/context_b fired mostly on ES through 06-26; research
//     is the recent one on MNQ — so on an MNQ window the context engines read "quiet" truthfully.
//   • Nothing here invents a fire, a price, a direction, a count, or a timestamp. Empty in →
//     empty markers + an all-quiet legend.
import Foundation

// Visual identity for one engine on the chart (distinct color + clean label + one-line "what it is").
struct EngineStyle {
    let id: String           // raw engine id as stored ("research" / "context_a" / "context_b" / …)
    let label: String        // clean display name
    let short: String        // 3–4 char marker code
    let blurb: String        // one-line description of what the engine does
    let rgba: (Double, Double, Double, Double)   // distinct premium-palette color
}

enum EngineFireMarkers {
    // The three BACKEND engines that actually record fires in the store. Each gets a distinct
    // premium color so a glance at the chart tells you which engine fired. Blurbs match the real
    // backend logic (bltd_store.py prove_research / _context_a/_b_dir / _consensus_dir).
    static let registry: [String: EngineStyle] = [
        "research":  EngineStyle(id: "research",  label: "Research",   short: "RSCH",
            blurb: "Breakout — long > 20-bar high, short < 20-bar low (stop = opposite extreme, 2:1)",
            rgba: (0.890, 0.745, 0.380, 1)),                                   // gold
        "context_a": EngineStyle(id: "context_a", label: "Context A",  short: "CTXA",
            blurb: "Trend consensus, loose — StepGMA 8/21 + EMA ribbon not-opposite + Kaufman ER ≥ 0.30",
            rgba: (0.357, 0.667, 0.984, 1)),                                   // blue
        "context_b": EngineStyle(id: "context_b", label: "Context B",  short: "CTXB",
            blurb: "Trend consensus, strict — fully-stacked ribbon + Kaufman ER ≥ 0.45",
            rgba: (0.706, 0.510, 0.960, 1)),                                   // violet
    ]
    // Legend display order (known engines first; any buyer-added engine id appended after).
    static let order = ["research", "context_a", "context_b"]

    // Style for an engine id — a known one, else a humanized fallback (never dropped, never given
    // an invented meaning; unknown ids get a neutral grey + a generic blurb).
    static func style(for id: String) -> EngineStyle {
        if let s = registry[id] { return s }
        let words = id.split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let label = words.joined(separator: " ")
        let short = String(id.filter { $0.isLetter }.prefix(4)).uppercased()
        return EngineStyle(id: id, label: label.isEmpty ? id : label,
                           short: short.isEmpty ? "ENG" : short,
                           blurb: "Recorded engine (no built-in description)",
                           rgba: (0.66, 0.66, 0.72, 1))
    }

    // Parse a fire's real timestamp. Prefers the raw epoch; falls back to the GMT string the
    // backend also emits ("yyyy-MM-dd HH:mm:ss"). nil when neither is present/parseable.
    static func fireDate(_ f: FireRow) -> Date? {
        if let e = f.tsEpoch, e > 0 { return Date(timeIntervalSince1970: e) }
        guard let s = f.ts, !s.isEmpty else { return nil }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let d = df.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    }

    // Map every real fire for `symbol` onto the plotted candles → markers (in-window fires only)
    // + a legend that names each engine, its color, its real fire count, and its last fire.
    // `fires` may carry other symbols; they're filtered out here. `candles` are exactly what the
    // chart plots (date-ordered, gap-free indices).
    static func build(fires: [FireRow], candles: [Candle], symbol: String)
        -> (markers: [EngineMarker], legend: [EngineLegendRow]) {

        let sym = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        // Keep fires for this symbol (a nil symbol on a fire is treated as a match — defensive).
        let mine = fires.filter { f in
            guard let s = f.symbol else { return true }
            return s.uppercased() == sym
        }
        guard !candles.isEmpty else {
            // No candles → no markers; still emit an all-quiet legend so the engines are named.
            return ([], legendOnly(mine))
        }

        let dates = candles.map(\.date)
        // Median positive spacing of the candle dates (tolerance for the off-window cutoff).
        var deltas: [TimeInterval] = []
        for i in 1..<dates.count { let d = dates[i].timeIntervalSince(dates[i-1]); if d > 0 { deltas.append(d) } }
        let spacing = deltas.isEmpty ? 60 : max(deltas.sorted()[deltas.count / 2], 1)
        let tol = max(spacing * 1.5, 120)              // a fire within this of a candle maps to it
        let first = dates.first!, last = dates.last!

        // Nearest candle index to a date (binary search on sorted dates), or nil if off-window.
        func nearestIndex(_ t: Date) -> Int? {
            if t < first.addingTimeInterval(-tol) || t > last.addingTimeInterval(tol) { return nil }
            var lo = 0, hi = dates.count - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if dates[mid] < t { lo = mid + 1 } else { hi = mid }
            }
            // `lo` is the first candle with date >= t; compare it and its predecessor.
            var best = lo
            if lo > 0 && abs(dates[lo - 1].timeIntervalSince(t)) <= abs(dates[lo].timeIntervalSince(t)) {
                best = lo - 1
            }
            return abs(dates[best].timeIntervalSince(t)) <= tol ? best : nil
        }

        var markers: [EngineMarker] = []
        for f in mine {
            guard let t = fireDate(f), let idx = nearestIndex(t) else { continue }
            let st = style(for: f.engine)
            markers.append(EngineMarker(barIndex: idx, price: f.entry,
                                        isLong: f.direction.lowercased().hasPrefix("l"),
                                        engine: f.engine, short: st.short, rgba: st.rgba))
        }
        markers.sort { $0.barIndex < $1.barIndex }

        // Legend: the known engines always (named even when quiet), then any extra ids present.
        var ids = order
        for f in mine where !ids.contains(f.engine) { ids.append(f.engine) }
        let inWindowByEngine = Dictionary(grouping: markers, by: { $0.engine }).mapValues { $0.count }
        let legend = ids.map { id -> EngineLegendRow in
            let st = style(for: id)
            let ef = mine.filter { $0.engine == id }
            let cnt = ef.count
            let last = ef.compactMap { f -> (Date, Double, String)? in
                guard let d = fireDate(f) else { return nil }
                return (d, f.entry, f.direction.lowercased().hasPrefix("l") ? "long" : "short")
            }.max(by: { $0.0 < $1.0 })
            let lastStr: String
            if let l = last {
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = TimeZone(identifier: "UTC")
                df.dateFormat = "MMM d HH:mm"
                lastStr = "\(l.2 == "long" ? "▲" : "▼") \(df.string(from: l.0))Z @ \(fmtPrice(l.1))"
            } else {
                lastStr = "no fires on \(sym)"
            }
            return EngineLegendRow(engine: id, label: st.label, short: st.short, blurb: st.blurb,
                                   rgba: st.rgba, count: cnt, inWindow: inWindowByEngine[id] ?? 0,
                                   lastFire: lastStr, quiet: cnt == 0)
        }
        return (markers, legend)
    }

    // Legend when there are no candles to map onto (still names all engines honestly).
    private static func legendOnly(_ mine: [FireRow]) -> [EngineLegendRow] {
        var ids = order
        for f in mine where !ids.contains(f.engine) { ids.append(f.engine) }
        return ids.map { id in
            let st = style(for: id)
            let cnt = mine.filter { $0.engine == id }.count
            return EngineLegendRow(engine: id, label: st.label, short: st.short, blurb: st.blurb,
                                   rgba: st.rgba, count: cnt, inWindow: 0,
                                   lastFire: cnt > 0 ? "\(cnt) fires" : "quiet", quiet: cnt == 0)
        }
    }

    private static func fmtPrice(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.2f", v)
    }
}
