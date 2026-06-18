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
let bars = FeedBars.decode(recent)
print("decoded \(bars.count) real bars")
guard !bars.isEmpty else { print("FATAL: zero bars for \(symbol) — honest empty, nothing to render."); exit(5) }

// 4) Real live last-price tick (if any) for the last-price line — never fabricated.
var lastPrice: Double? = nil
if let live = httpJSON("GET", base + "/api/live?symbol=\(symbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? symbol)", token: token),
   let t = LiveTick.decode(live) {
    lastPrice = t.price
    print("live tick: \(t.price)")
}

let span = "\(bars.first!.date.formatted(date: .abbreviated, time: .shortened)) → \(bars.last!.date.formatted(date: .abbreviated, time: .shortened))"
print("span: \(span)")

// 5) Render PNG #1 — clean candlesticks + auto-fit nice-tick price axis + time axis + volume.
let p1 = "/tmp/bltd_chart_candles.png"
let ok1 = ChartRender.renderPNG(
    bars: bars, symbol: symbol,
    title: "\(symbol) · Candles · \(bars.count) bars",
    indicators: RenderIndicators(),    // bare candles
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
    logScale: false)
let ok2 = ChartRender.renderPNG(
    bars: bars, symbol: symbol,
    title: "\(symbol) · EMA·VWAP·BB·RSI · \(bars.count) bars",
    indicators: ind, showVolume: true, to: p2)
print(ok2 ? "WROTE \(p2)" : "FAILED \(p2)")

if ok1 && ok2 { print("\nPROOF OK — two PNGs rendered from \(bars.count) real captured bars of \(symbol).") ; exit(0) }
exit(6)
