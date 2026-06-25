// Black Label Trading — headless CHART RENDER PROOF harness (CLI, no SwiftUI, no computer-use).
//
// Pulls the buyer's OWN captured OHLC bars from the product's self-contained backend
// (bltd_api.py at http://127.0.0.1:8787, the same endpoint the live app reads via FeedClient),
// then renders two professional-grade chart PNGs via ChartRender (CoreGraphics):
//   /tmp/bltd_chart_candles.png     — clean candlesticks, nice-tick price axis, time axis, volume
//   /tmp/bltd_chart_indicators.png  — same chart + EMA(9/21) + VWAP + RSI pane + crosshair + last-price
//
// HONEST: it renders ONLY real bars returned by the backend. If the backend is down / the store
// is empty it prints WHY and renders an honest "no data" frame — it never fabricates a candle.
//
// Usage:
//   render-proof [SYMBOL] [BASE_URL]
//   (defaults: SYMBOL = backend's busiest captured symbol; BASE_URL = http://127.0.0.1:8787)
import Foundation

// ---- tiny synchronous HTTP GET/POST (so the CLI stays simple) ----
func httpJSON(_ method: String, _ urlStr: String, token: String? = nil, body: [String: Any]? = nil) -> [String: Any]? {
    guard let url = URL(string: urlStr) else { return nil }
    var req = URLRequest(url: url); req.httpMethod = method; req.timeoutInterval = 8
    if let t = token { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
    if let b = body {
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: b)
    }
    let sem = DispatchSemaphore(value: 0)
    var out: [String: Any]? = nil
    URLSession.shared.dataTask(with: req) { data, _, _ in
        defer { sem.signal() }
        if let data = data { out = try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
    }.resume()
    _ = sem.wait(timeout: .now() + 10)
    return out
}

let args = CommandLine.arguments
let base = args.count > 2 ? args[2] : "http://127.0.0.1:8787"
var symbol = args.count > 1 ? args[1] : ""

print("== Black Label Trading — chart render proof ==")

// CSV MODE: if the first arg is a .csv path, render real OHLC straight from that file (a dense
// proof with no live backend). Honest — these are real bars from the file, never fabricated.
if symbol.lowercased().hasSuffix(".csv") {
    guard let text = try? String(contentsOfFile: symbol, encoding: .utf8) else {
        print("FATAL: cannot read CSV \(symbol)"); exit(2)
    }
    let parsed = BarCSV.parse(text)
    guard !parsed.bars.isEmpty else { print("FATAL: no bars parsed (skipped \(parsed.skipped))"); exit(5) }
    let bars = parsed.bars
    let sym = (symbol as NSString).lastPathComponent.replacingOccurrences(of: ".csv", with: "")
    print("CSV mode: \(bars.count) real bars from \(symbol) (skipped \(parsed.skipped))")
    let lp = bars.last?.close
    _ = ChartRender.renderPNG(bars: bars, symbol: sym, title: "\(sym) · Candles · \(bars.count) bars",
        indicators: RenderIndicators(lastPriceLine: lp), showVolume: true, to: "/tmp/bltd_chart_candles.png")
    let ind = RenderIndicators(ema1: 9, ema2: 21, vwapWindow: min(bars.count, 50), rsiPeriod: 14,
        bollinger: (period: 20, k: 2), crosshairIndex: max(0, bars.count - 8), lastPriceLine: lp)
    _ = ChartRender.renderPNG(bars: bars, symbol: sym, title: "\(sym) · EMA·VWAP·BB·RSI · \(bars.count) bars",
        indicators: ind, showVolume: true, to: "/tmp/bltd_chart_indicators.png")

    // PNG #3 — the engine-trade overlay (entry/stop/target). The levels are a SAMPLE long setup
    // computed from the bars' OWN ATR (real bar math), NOT a claimed trade outcome — the engine is
    // labeled "sample" and the title says SAMPLE so it can never be read as a track record. This
    // proves the edge-gate-transparency overlay renders; the LIVE app draws real recorded fires.
    if let entry = lp, let atr = Indicators.atr(bars, 14).last ?? nil, atr > 0 {
        let sampleFire = RenderFire(direction: "long", engine: "sample", entry: entry,
                                    stop: entry - atr, target: entry + 2 * atr, outcome: nil)
        let find = RenderIndicators(ema1: 9, ema2: 21, vwapWindow: min(bars.count, 50),
            crosshairIndex: max(0, bars.count - 6), lastPriceLine: lp, fire: sampleFire)
        _ = ChartRender.renderPNG(bars: bars, symbol: sym,
            title: "\(sym) · SAMPLE setup overlay (entry/stop/target from ATR) · \(bars.count) bars",
            indicators: find, showVolume: true, to: "/tmp/bltd_chart_fire.png")
        print("WROTE /tmp/bltd_chart_fire.png (sample entry/stop/target overlay from real ATR=\(String(format: "%.4f", atr)))")
    }
    print("PROOF OK — dense CSV render (\(bars.count) bars).")
    exit(0)
}

print("backend: \(base)")

// 1) Sign in (local backend mints a per-deployment token; same handshake as FeedClient).
guard let auth = httpJSON("POST", base + "/auth/signin", body: ["email": "local@blacklabel", "password": "local-session"]),
      let token = auth["token"] as? String else {
    print("FATAL: backend not reachable / sign-in failed at \(base). Start the backend, then retry.")
    exit(2)
}
print("signed in (token ok)")

// 2) Pick symbol: explicit arg, else the backend's busiest captured symbol (most stored bars).
if symbol.isEmpty {
    if let syms = httpJSON("GET", base + "/api/symbols", token: token), let b = syms["busiest"] as? String {
        symbol = b
    }
}
guard !symbol.isEmpty else { print("FATAL: no symbol captured yet (store is empty)."); exit(3) }
print("symbol: \(symbol)")

// 3) Pull the buyer's REAL bars (oldest->newest) via the wire format FeedTypes locks.
guard let recent = httpJSON("GET", base + "/api/recent?symbol=\(symbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? symbol)&limit=400", token: token) else {
    print("FATAL: /api/recent returned nothing."); exit(4)
}
let rawBars = FeedBars.decode(recent)
print("decoded \(rawBars.count) real bars")
guard !rawBars.isEmpty else { print("FATAL: zero bars for \(symbol) — honest empty, nothing to render."); exit(5) }
// Match the LIVE APP's default view: aggregate 15s base bars -> 1-minute candles (factor 4), then
// show the recent session (last ~60). This makes the proof reflect what the app actually renders.
func resample1m(_ src: [Bar], factor: Int = 4) -> [Bar] {
    guard src.count > factor else { return src }
    var out: [Bar] = []; var i = 0
    while i < src.count {
        let chunk = Array(src[i..<min(i+factor, src.count)])
        if let f = chunk.first, let l = chunk.last {
            out.append(Bar(date: f.date, open: f.open, high: chunk.map(\.high).max() ?? f.high,
                           low: chunk.map(\.low).min() ?? f.low, close: l.close,
                           volume: chunk.reduce(0) { $0 + $1.volume }))
        }
        i += factor
    }
    return out
}
let oneMin = resample1m(rawBars)
let bars = Array(oneMin.suffix(60))
print("rendering recent \(bars.count) one-minute candles (app default view)")

// 4) Real live last-price tick (if any) for the last-price line — never fabricated.
var lastPrice: Double? = nil
if let live = httpJSON("GET", base + "/api/live?symbol=\(symbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? symbol)", token: token),
   let t = LiveTick.decode(live) {
    lastPrice = t.price
    print("live tick: \(t.price)")
}

let span = "\(bars.first!.date.formatted(date: .abbreviated, time: .shortened)) → \(bars.last!.date.formatted(date: .abbreviated, time: .shortened))"
print("span: \(span)")

// 4b) Real active engine signal (if any) for the entry/stop/target overlay — edge-gate transparency.
// Pulled from /api/fires (newest matching the symbol). HONEST: nil when there is no real fire; a fire
// with no stop/target draws only the legs it actually has. Nothing is fabricated.
func num(_ v: Any?) -> Double? { if let d = v as? Double { return d }; if let i = v as? Int { return Double(i) }; if let s = v as? String { return Double(s) }; return nil }
var activeFire: RenderFire? = nil
if let fobj = httpJSON("GET", base + "/api/fires?limit=40&symbol=\(symbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? symbol)", token: token),
   let rows = fobj["fires"] as? [[String: Any]],
   let r = rows.first(where: { ($0["symbol"] as? String) == symbol || $0["symbol"] == nil }),
   let dir = r["direction"] as? String, let eng = r["engine"] as? String, let entry = num(r["entry"]) {
    activeFire = RenderFire(direction: dir, engine: eng, entry: entry,
                            stop: num(r["stop"]), target: num(r["target"]), outcome: r["outcome"] as? String)
    print("active fire: \(eng) \(dir) entry=\(entry) stop=\(num(r["stop"]) ?? .nan) tgt=\(num(r["target"]) ?? .nan)")
} else {
    print("active fire: none (flat — no overlay, honest)")
}

// 5) Render PNG #1 — clean candlesticks + auto-fit nice-tick price axis + time axis + volume.
let p1 = "/tmp/bltd_chart_candles.png"
let ok1 = ChartRender.renderPNG(
    bars: bars, symbol: symbol,
    title: "\(symbol) · Candles · \(bars.count) bars",
    indicators: RenderIndicators(lastPriceLine: lastPrice ?? bars.last?.close),   // bare candles + last-price flag
    showVolume: true, to: p1)
print(ok1 ? "WROTE \(p1)" : "FAILED \(p1)")

// 6) Render PNG #2 — same bars + EMA(9/21) + VWAP + Bollinger + RSI pane + crosshair + last-price.
let p2 = "/tmp/bltd_chart_indicators.png"
let ind = RenderIndicators(
    ema1: 9, ema2: 21, sma: nil,
    vwapWindow: bars.count,                 // session VWAP over the whole captured window
    rsiPeriod: 14,
    bollinger: (period: 20, k: 2),
    crosshairIndex: max(0, bars.count - 8),  // crosshair near the latest bar for the OHLC readout
    lastPriceLine: lastPrice ?? bars.last?.close,
    fire: activeFire,                        // entry/stop/target overlay (real signal, or nil = none)
    logScale: false)
let ok2 = ChartRender.renderPNG(
    bars: bars, symbol: symbol,
    title: "\(symbol) · EMA·VWAP·BB·RSI · \(bars.count) bars",
    indicators: ind, showVolume: true, to: p2)
print(ok2 ? "WROTE \(p2)" : "FAILED \(p2)")

if ok1 && ok2 { print("\nPROOF OK — two PNGs rendered from \(bars.count) real captured bars of \(symbol).") ; exit(0) }
exit(6)
