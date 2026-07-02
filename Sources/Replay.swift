// Black Label Trading — trade replay / session review. PURE MATH (no SwiftUI/network).
//
// HONEST FRAMING: replays a session the user imported, bar by bar, surfacing what was knowable
// AT EACH BAR (no look-ahead): the running OHLC, detected candlestick/structure patterns that
// had completed by that bar, and any entry signals from a chosen visual strategy. It is a
// coaching/review tool over the user's OWN data — it fabricates no prices, no fills, and no
// outcomes. The "what happened next" is only ever the user's real subsequent bars.
import Foundation

// A single frame of the replay: state as of bar `index` (inclusive), no future leakage.
struct ReplayFrame: Identifiable {
    var id: Int { index }
    let index: Int               // current bar pointer (0-based)
    let bar: Bar                  // the bar at this step
    let visibleBars: Int          // how many bars are revealed (index + 1)
    let newPatterns: [PatternHit] // patterns completing exactly at this bar
    let entryHere: Bool           // strategy entry fires at this bar
    let runningHigh: Double        // session high so far
    let runningLow: Double         // session low so far
    let changeFromOpenPct: Double  // % change of close vs first revealed bar's open
}

enum ReplaySession {
    // Build all frames for a session. Patterns are computed ONCE over the full series but each
    // hit is attached to the frame at its completion index — so a frame only ever shows patterns
    // that had completed by then (no future bars revealed). Entry signals likewise come from the
    // strategy evaluated at each index over only-past data (the engine itself is causal:
    // crosses/indicators look back, never forward).
    static func build(_ bars: [Bar], strategy: VisualStrategy? = nil,
                      candleParams: CandleScan.Params = CandleScan.Params(),
                      pivotLookback: Int = 3) -> [ReplayFrame] {
        guard !bars.isEmpty else { return [] }
        // Pattern hits by completion index. Triangle/flag are "as-of-last-bar" detectors, so we
        // only use the per-bar candlestick + double top/bottom hits (which are causal by index).
        var byIndex: [Int: [PatternHit]] = [:]
        for h in CandleScan.scan(bars, candleParams) { byIndex[h.index, default: []].append(h) }
        for h in StructureScan.doubleTopsBottoms(bars, lookback: pivotLookback) { byIndex[h.index, default: []].append(h) }

        // Entry bars (the visual engine is causal — it reads series[i] and series[i-1] only).
        var entrySet = Set<Int>()
        if let s = strategy { entrySet = Set(VisualStrategyEngine.entryBars(bars, s)) }

        var frames: [ReplayFrame] = []
        var hi = -Double.infinity, lo = Double.infinity
        let openPx = bars[0].open
        for i in bars.indices {
            let b = bars[i]
            hi = max(hi, b.high); lo = min(lo, b.low)
            let chg = openPx != 0 ? (b.close - openPx) / openPx * 100 : 0
            frames.append(ReplayFrame(index: i, bar: b, visibleBars: i + 1,
                                      newPatterns: byIndex[i] ?? [], entryHere: entrySet.contains(i),
                                      runningHigh: hi, runningLow: lo, changeFromOpenPct: chg))
        }
        return frames
    }

    // Convenience: only the frames where something coachable happened (a pattern or an entry).
    static func keyMoments(_ frames: [ReplayFrame]) -> [ReplayFrame] {
        frames.filter { !$0.newPatterns.isEmpty || $0.entryHere }
    }
}
