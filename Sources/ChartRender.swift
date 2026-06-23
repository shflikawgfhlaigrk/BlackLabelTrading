// Black Label Trading — HEADLESS chart renderer (CoreGraphics, no SwiftUI/AppKit views).
//
// WHY THIS EXISTS: it draws the EXACT same candle/indicator math the live SwiftUI ChartScreen
// uses (CandleTransform / Indicators / ChartIndicators / ChartScale) straight to a bitmap, so a
// professional-grade chart can be rendered + inspected from a CLI with NO window server and NO
// computer-use. The PNGs it writes are the visual proof that the charting is correct.
//
// HONEST FRAMING: it renders ONLY the bars handed to it (the buyer's own captured OHLC, or an
// imported historical OHLC dataset). It downloads nothing, samples nothing, invents nothing.
// Empty bars -> an honest "no data" frame, never a fabricated candle.
//
// Pure CoreGraphics + ImageIO are available headlessly on macOS (unlike SwiftUI ImageRenderer,
// which needs an app/window context), which is exactly why the proof harness uses this path.
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// Palette aligned to BLTheme (Black Gold) so the proof looks like the shipping chart.
enum RenderPalette {
    static let bg      = CGColor(red: 0.031, green: 0.031, blue: 0.043, alpha: 1)   // #08080B
    static let bgTop   = CGColor(red: 0.055, green: 0.055, blue: 0.078, alpha: 1)   // #0E0E14
    static let bgBot   = CGColor(red: 0.020, green: 0.020, blue: 0.027, alpha: 1)   // #050507
    static let panel   = CGColor(red: 0.055, green: 0.055, blue: 0.071, alpha: 1)   // #0E0E12
    static let panelHi = CGColor(red: 0.071, green: 0.071, blue: 0.102, alpha: 1)   // #12121A
    static let stroke  = CGColor(red: 0.149, green: 0.149, blue: 0.169, alpha: 1)   // #26262B
    static let gridMinor = CGColor(red: 1, green: 1, blue: 1, alpha: 0.045)
    static let gridMajor = CGColor(red: 1, green: 1, blue: 1, alpha: 0.085)
    static let text    = CGColor(red: 0.93, green: 0.93, blue: 0.93, alpha: 1)      // #EDEDED
    static let sub     = CGColor(red: 0.549, green: 0.549, blue: 0.549, alpha: 1)   // #8C8C8C
    static let gold     = CGColor(red: 0.851, green: 0.714, blue: 0.361, alpha: 1)  // #D9B65C
    static let goldHi   = CGColor(red: 0.941, green: 0.831, blue: 0.533, alpha: 1)  // #F0D488
    static let green    = CGColor(red: 0.169, green: 0.831, blue: 0.608, alpha: 1)  // #2BD49B (up)
    static let red      = CGColor(red: 0.941, green: 0.380, blue: 0.427, alpha: 1)  // #F0616D (down)
    static let blue     = CGColor(red: 0.40, green: 0.66, blue: 0.98, alpha: 1)
    static func alpha(_ c: CGColor, _ a: CGFloat) -> CGColor { c.copy(alpha: a) ?? c }
    // Multiply rgb by `m` (clamped) — darken (<1) wicks, brighten (>1) borders.
    static func shade(_ c: CGColor, _ m: CGFloat) -> CGColor {
        guard let k = c.components, k.count >= 3 else { return c }
        func ch(_ v: CGFloat) -> CGFloat { min(1, max(0, v * m)) }
        return CGColor(red: ch(k[0]), green: ch(k[1]), blue: ch(k[2]), alpha: k.count >= 4 ? k[3] : 1)
    }
}

// An active (or just-closed) engine signal to overlay on the chart: entry / stop / target lines.
// Mirrors the live SwiftUI ChartScreen's `activeFire` overlay so the render proof shows the SAME
// edge-gate-transparency lines. HONEST: only ever built from a real recorded FireRow; a nil leg
// (no stop / no target) is simply not drawn — never invented.
struct RenderFire {
    var direction: String          // "long" / "short"
    var engine: String             // which engine fired (shown on the entry tag)
    var entry: Double
    var stop: Double? = nil
    var target: Double? = nil
    var outcome: String? = nil     // nil = open (label "ENTRY"); set = closed (label "EXIT <outcome>")
}

// What to draw on top of the candles. Mirrors ChartIndicatorSet (the SwiftUI toggles) so the
// render proof and the live chart show the same overlays from the same math.
struct RenderIndicators {
    var ema1: Int? = nil          // e.g. EMA(9)
    var ema2: Int? = nil          // e.g. EMA(21)
    var sma: Int? = nil
    var vwapWindow: Int? = nil    // session/rolling VWAP
    var rsiPeriod: Int? = nil     // draws an RSI sub-pane when set
    var bollinger: (period: Int, k: Double)? = nil
    var crosshairIndex: Int? = nil  // candle index to draw the crosshair + OHLC readout at
    var lastPriceLine: Double? = nil
    var fire: RenderFire? = nil   // active engine signal: entry/stop/target overlay (edge-gate transparency)
    var logScale = false
}

enum ChartRender {

    // MARK: Public entry — render `bars` to a PNG at `path`. Returns true on success.
    static func renderPNG(
        bars: [Bar],
        symbol: String,
        title: String,
        size: CGSize = CGSize(width: 1280, height: 820),
        scale: CGFloat = 2,                 // retina bitmap
        indicators: RenderIndicators = RenderIndicators(),
        showVolume: Bool = true,
        to path: String
    ) -> Bool {
        guard let ctx = makeContext(size: size, scale: scale) else { return false }
        ctx.scaleBy(x: scale, y: scale)
        draw(ctx: ctx, size: size, bars: bars, symbol: symbol, title: title,
             indicators: indicators, showVolume: showVolume)
        guard let img = ctx.makeImage() else { return false }
        return writePNG(img, to: path)
    }

    // MARK: - Layout + draw
    private static func draw(ctx: CGContext, size: CGSize, bars: [Bar], symbol: String, title: String,
                             indicators ind: RenderIndicators, showVolume: Bool) {
        let W = size.width, H = size.height
        // Background — vertical premium wash (lighter top → near-black bottom) for depth.
        ctx.setFillColor(RenderPalette.bg); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        fillVGradient(ctx, CGRect(x: 0, y: 0, width: W, height: H),
                      top: RenderPalette.bgTop, bottom: RenderPalette.bgBot)

        // Header band.
        let headerH: CGFloat = 64
        drawHeader(ctx: ctx, rect: CGRect(x: 0, y: H - headerH, width: W, height: headerH),
                   symbol: symbol, title: title, bars: bars)

        guard !bars.isEmpty else {
            drawCentered(ctx, "No bars — load your own captured / imported OHLC to chart.",
                         at: CGPoint(x: W/2, y: H/2), size: 15, color: RenderPalette.sub, align: .center)
            return
        }

        // Panes: price (top), optional RSI, optional volume (bottom).
        let marginL: CGFloat = 22, marginR: CGFloat = 78, gap: CGFloat = 10
        let bottomAxis: CGFloat = 26
        let contentTop = H - headerH - 12
        let contentBottom = bottomAxis + 12
        let contentH = contentTop - contentBottom

        var rsiH: CGFloat = 0, volH: CGFloat = 0
        if ind.rsiPeriod != nil { rsiH = contentH * 0.20 }
        if showVolume && bars.contains(where: { $0.volume > 0 }) { volH = contentH * 0.16 }
        let priceH = contentH - rsiH - volH - (rsiH > 0 ? gap : 0) - (volH > 0 ? gap : 0)

        let plotL = marginL, plotW = W - marginL - marginR
        let priceRect = CGRect(x: plotL, y: contentBottom + volH + (volH>0 ? gap:0) + rsiH + (rsiH>0 ? gap:0),
                               width: plotW, height: priceH)
        let rsiRect = rsiH > 0 ? CGRect(x: plotL, y: contentBottom + volH + (volH>0 ? gap:0),
                                        width: plotW, height: rsiH) : .zero
        let volRect = volH > 0 ? CGRect(x: plotL, y: contentBottom, width: plotW, height: volH) : .zero

        let candles = CandleTransform.candles(bars)
        let n = candles.count
        // Robust domain so one session-gap candle can't squash the rest of the chart.
        let dom = ChartScale.robustDomain(candles)
        let useLog = ind.logScale && dom.lo > 0

        // x mapping: candle index -> pixel center.
        let slot = plotW / CGFloat(max(1, n))
        func xCenter(_ i: Int) -> CGFloat { priceRect.minX + (CGFloat(i) + 0.5) * slot }
        func yPrice(_ p: Double, _ r: CGRect) -> CGFloat {
            CGFloat(ChartScale.yPixel(p, lo: dom.lo, hi: dom.hi,
                                      topY: Double(r.maxY), bottomY: Double(r.minY), log: useLog))
        }

        // ---- Price pane: panel, gridlines, right-aligned price ladder ----
        drawPanel(ctx, priceRect)
        // Dedicated ladder gutter plate so prices sit on a subtle column, not on candles.
        ctx.setFillColor(RenderPalette.panel)
        ctx.fill(CGRect(x: priceRect.maxX, y: priceRect.minY, width: marginR, height: priceRect.height))
        strokeLine(ctx, CGPoint(x: priceRect.maxX, y: priceRect.minY),
                   CGPoint(x: priceRect.maxX, y: priceRect.maxY), color: RenderPalette.stroke, width: 1)
        let ticks = ChartScale.ticks(lo: dom.lo, hi: dom.hi, target: 6)
        let step = ticks.count > 1 ? (ticks[1] - ticks[0]) : (dom.hi - dom.lo)
        let decimals = ChartScale.priceDecimals(step: step)
        let lastClose = candles.last?.close
        for t in ticks {
            let y = yPrice(t, priceRect)
            guard y >= priceRect.minY - 0.5 && y <= priceRect.maxY + 0.5 else { continue }
            strokeLine(ctx, CGPoint(x: priceRect.minX, y: y), CGPoint(x: priceRect.maxX, y: y),
                       color: RenderPalette.gridMinor, width: 0.5)
            // Suppress the tick nearest the last price — the last-price tag replaces it.
            if let lc = lastClose, abs(yPrice(lc, priceRect) - y) < 9 { continue }
            let s = fmt(t, decimals)
            let tw = textWidth(s, size: 10, bold: false)
            drawText(ctx, s, at: CGPoint(x: W - 10 - tw, y: y - 4), size: 10, color: RenderPalette.sub)
        }
        // Time-aware x-axis: round-clock labels + dotted session separators (not index stride).
        drawTimeAxis(ctx, candles: candles, rect: priceRect, bottomY: bottomAxis, slot: slot, xCenter: xCenter)

        // ---- Indicator overlays (under candles for VWAP/BB band, over for MAs reads fine) ----
        let closes = candles.map(\.close)
        if let bb = ind.bollinger {
            let b = ChartIndicators.bollinger(closes, period: bb.period, k: bb.k)
            drawSeries(ctx, b.upper, rect: priceRect, xCenter: xCenter, y: { yPrice($0, priceRect) }, color: RenderPalette.alpha(RenderPalette.blue, 0.55), width: 1.1, dash: [4,3])
            drawSeries(ctx, b.lower, rect: priceRect, xCenter: xCenter, y: { yPrice($0, priceRect) }, color: RenderPalette.alpha(RenderPalette.blue, 0.55), width: 1.1, dash: [4,3])
            drawSeries(ctx, b.mid,   rect: priceRect, xCenter: xCenter, y: { yPrice($0, priceRect) }, color: RenderPalette.alpha(RenderPalette.blue, 0.30), width: 0.9, dash: [2,3])
        }

        // ---- Candles ----
        let bodyW = max(2, min(slot * 0.72, slot - 2.0, 26))   // clamp gap + cap fat blocks
        let wickW = max(1.0, (slot * 0.14).rounded())
        let radius = min(1.5, bodyW * 0.18)
        let lastIdx = n - 1
        for c in candles {
            let x = xCenter(c.index).rounded() + 0.5             // pixel-snap for crisp wicks
            let col = c.up ? RenderPalette.green : RenderPalette.red
            let isCurrent = c.index == lastIdx
            // Wick — slightly darker than the body so the body reads as the focal mass.
            strokeLine(ctx, CGPoint(x: x, y: yPrice(c.high, priceRect)), CGPoint(x: x, y: yPrice(c.low, priceRect)),
                       color: RenderPalette.shade(col, 0.8), width: wickW)
            // Body — rounded, with a crisp brighter border; doji forced to a visible 1.5px bar.
            let yo = yPrice(c.open, priceRect), yc = yPrice(c.close, priceRect)
            let top = min(yo, yc), bot = max(yo, yc)
            let bodyH = max(1.5, bot - top)
            let bodyRect = CGRect(x: (x - bodyW/2).rounded(), y: top, width: bodyW, height: bodyH)
            let path = CGPath(roundedRect: bodyRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.setFillColor(RenderPalette.alpha(col, isCurrent ? 1.0 : 0.92))
            ctx.addPath(path); ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(RenderPalette.alpha(RenderPalette.shade(col, 1.15), 0.9)); ctx.setLineWidth(0.75); ctx.strokePath()
            if isCurrent {
                // live-bar emphasis: gold halo border + close anchor dot.
                ctx.addPath(CGPath(roundedRect: bodyRect.insetBy(dx: -1.5, dy: -1.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
                ctx.setStrokeColor(RenderPalette.alpha(RenderPalette.goldHi, 0.6)); ctx.setLineWidth(1); ctx.strokePath()
                ctx.setFillColor(col); ctx.fillEllipse(in: CGRect(x: x - 2.5, y: yc - 2.5, width: 5, height: 5))
            }
        }

        // Moving averages / VWAP (drawn over candles).
        if let p = ind.sma { drawSeries(ctx, Indicators.sma(closes, p), rect: priceRect, xCenter: xCenter, y: { yPrice($0, priceRect) }, color: RenderPalette.gold, width: 1.8) }
        if let p = ind.ema1 { drawSeries(ctx, Indicators.ema(closes, p), rect: priceRect, xCenter: xCenter, y: { yPrice($0, priceRect) }, color: RenderPalette.goldHi, width: 1.8) }
        if let p = ind.ema2 { drawSeries(ctx, Indicators.ema(closes, p), rect: priceRect, xCenter: xCenter, y: { yPrice($0, priceRect) }, color: RenderPalette.blue, width: 1.8) }
        if let w = ind.vwapWindow { drawSeries(ctx, ChartIndicators.vwap(bars, window: w), rect: priceRect, xCenter: xCenter, y: { yPrice($0, priceRect) }, color: RenderPalette.green, width: 1.8, dash: [6,3]) }

        // Last-price line + flag (real value only — never fabricated). Colored by last tick dir.
        if let lp = ind.lastPriceLine {
            let y = yPrice(lp, priceRect)
            let prevClose = candles.count >= 2 ? candles[candles.count - 2].close : lp
            let tagCol = lp >= prevClose ? RenderPalette.green : RenderPalette.red
            strokeLine(ctx, CGPoint(x: priceRect.minX, y: y), CGPoint(x: priceRect.maxX, y: y),
                       color: RenderPalette.alpha(tagCol, 0.85), width: 1, dash: [3,3])
            let lbl = fmt(lp, decimals)
            let tagW = textWidth(lbl, size: 10.5, bold: true) + 12, tagH: CGFloat = 17
            let ty = min(max(y - tagH/2, priceRect.minY + 1), priceRect.maxY - tagH - 1)
            let tagRect = CGRect(x: priceRect.maxX + 3, y: ty, width: tagW, height: tagH)
            ctx.setFillColor(tagCol)
            ctx.addPath(CGPath(roundedRect: tagRect, cornerWidth: 3, cornerHeight: 3, transform: nil)); ctx.fillPath()
            drawText(ctx, lbl, at: CGPoint(x: tagRect.minX + 6, y: tagRect.midY - 4), size: 10.5,
                     color: CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1), bold: true)
            // static "pulse" glow at the line's right end.
            for (r, a) in [(CGFloat(4), CGFloat(0.5)), (CGFloat(7), CGFloat(0.18))] {
                ctx.setStrokeColor(RenderPalette.alpha(tagCol, a)); ctx.setLineWidth(1)
                ctx.strokeEllipse(in: CGRect(x: priceRect.maxX - r, y: y - r, width: r*2, height: r*2))
            }
        }

        // ---- Engine trade overlay: entry / stop / target (edge-gate transparency) ----
        // Drawn ONLY from a real recorded fire; nil legs are skipped, never fabricated. This is the
        // headless twin of the live SwiftUI ChartScreen.activeFire overlay so the proof matches the app.
        if let f = ind.fire {
            drawFire(ctx, f, rect: priceRect, decimals: decimals, yPrice: { yPrice($0, priceRect) })
        }

        // ---- Crosshair + OHLC readout ----
        if let ci = ind.crosshairIndex, ci >= 0, ci < n {
            let c = candles[ci]
            let x = xCenter(ci)
            strokeLine(ctx, CGPoint(x: x, y: priceRect.minY), CGPoint(x: x, y: priceRect.maxY),
                       color: RenderPalette.alpha(RenderPalette.gold, 0.45), width: 1, dash: [2,2])
            let cy = yPrice(c.close, priceRect)
            strokeLine(ctx, CGPoint(x: priceRect.minX, y: cy), CGPoint(x: priceRect.maxX, y: cy),
                       color: RenderPalette.alpha(RenderPalette.gold, 0.30), width: 1, dash: [2,2])
            // OHLC readout chip top-left of price pane.
            drawOHLCReadout(ctx, c: c, decimals: decimals, at: CGPoint(x: priceRect.minX + 8, y: priceRect.maxY - 22))
        }

        // ---- RSI sub-pane ----
        if let rp = ind.rsiPeriod, rsiH > 0 {
            drawPanel(ctx, rsiRect)
            let rsi = Indicators.rsi(closes, rp)
            func yR(_ v: Double) -> CGFloat { rsiRect.minY + CGFloat(v/100) * rsiRect.height }
            for lvl in [30.0, 50, 70] {
                let y = yR(lvl)
                strokeLine(ctx, CGPoint(x: rsiRect.minX, y: y), CGPoint(x: rsiRect.maxX, y: y),
                           color: RenderPalette.alpha(lvl==50 ? RenderPalette.sub : (lvl<50 ? RenderPalette.green : RenderPalette.red), 0.30), width: 0.8, dash: [3,3])
                drawText(ctx, String(Int(lvl)), at: CGPoint(x: rsiRect.maxX + 6, y: y - 5), size: 9, color: RenderPalette.sub)
            }
            drawSeries(ctx, rsi, rect: rsiRect, xCenter: xCenter, y: yR, color: RenderPalette.blue, width: 1.6)
            drawText(ctx, "RSI \(rp)", at: CGPoint(x: rsiRect.minX + 8, y: rsiRect.maxY - 16), size: 10, color: RenderPalette.sub, bold: true)
        }

        // ---- Volume sub-pane (real volume only) ----
        if volH > 0 {
            drawPanel(ctx, volRect)
            let maxV = candles.map(\.volume).max() ?? 1
            for c in candles where c.volume > 0 {
                let x = xCenter(c.index).rounded()
                let h = CGFloat(c.volume / max(maxV, 1)) * (volRect.height - 4)
                let isCur = c.index == lastIdx
                ctx.setFillColor(RenderPalette.alpha(c.up ? RenderPalette.green : RenderPalette.red, isCur ? 0.55 : 0.30))
                ctx.fill(CGRect(x: (x - bodyW/2).rounded(), y: volRect.minY, width: bodyW, height: max(1, h)))
            }
            drawText(ctx, "VOL", at: CGPoint(x: volRect.minX + 8, y: volRect.maxY - 16), size: 10, color: RenderPalette.sub, bold: true)
        }

        // Legend chips (which overlays are on).
        drawLegend(ctx, ind: ind, at: CGPoint(x: priceRect.minX + 8, y: priceRect.minY + 8))
    }

    // MARK: header
    private static func drawHeader(ctx: CGContext, rect: CGRect, symbol: String, title: String, bars: [Bar]) {
        // gold underline
        strokeLine(ctx, CGPoint(x: 0, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                   color: RenderPalette.alpha(RenderPalette.gold, 0.25), width: 1)
        drawText(ctx, "BLACK LABEL TRADING", at: CGPoint(x: 22, y: rect.maxY - 22), size: 11, color: RenderPalette.gold, bold: true, tracking: 1.5)
        drawText(ctx, title, at: CGPoint(x: 22, y: rect.minY + 10), size: 16, color: RenderPalette.text, bold: true)
        // Right-aligned last close + change pill (measured widths, real values).
        if let last = bars.last {
            let up = last.close >= last.open
            let prev = bars.count >= 2 ? bars[bars.count - 2].close : last.open
            let chg = last.close - prev
            let pct = prev != 0 ? chg / prev * 100 : 0
            let col = up ? RenderPalette.green : RenderPalette.red
            let s = String(format: "%@ %.2f", up ? "▲" : "▼", last.close)
            let chgS = String(format: "%+.2f (%+.2f%%)", chg, pct)
            drawText(ctx, s, at: CGPoint(x: rect.maxX - 18 - textWidth(s, size: 17, bold: true), y: rect.minY + 16),
                     size: 17, color: col, bold: true)
            drawText(ctx, chgS, at: CGPoint(x: rect.maxX - 18 - textWidth(chgS, size: 11, bold: false), y: rect.minY + 1),
                     size: 11, color: RenderPalette.alpha(col, 0.85))
        }
    }

    private static func drawLegend(_ ctx: CGContext, ind: RenderIndicators, at p: CGPoint) {
        var x = p.x
        func chip(_ t: String, _ c: CGColor) {
            let w = CGFloat(t.count) * 6.4 + 16
            ctx.setFillColor(RenderPalette.alpha(c, 0.16)); ctx.fill(CGRect(x: x, y: p.y, width: w, height: 16))
            ctx.setFillColor(c); ctx.fillEllipse(in: CGRect(x: x+5, y: p.y+5.5, width: 5, height: 5))
            drawText(ctx, t, at: CGPoint(x: x+13, y: p.y+3.5), size: 9, color: RenderPalette.text)
            x += w + 6
        }
        if let p = ind.sma { chip("SMA \(p)", RenderPalette.gold) }
        if let p = ind.ema1 { chip("EMA \(p)", RenderPalette.goldHi) }
        if let p = ind.ema2 { chip("EMA \(p)", RenderPalette.blue) }
        if let w = ind.vwapWindow { chip("VWAP \(w)", RenderPalette.green) }
        if let bb = ind.bollinger { chip("BB \(bb.period)/\(fmt(bb.k,1))", RenderPalette.blue) }
    }

    private static func drawOHLCReadout(_ ctx: CGContext, c: Candle, decimals: Int, at p: CGPoint) {
        let date = c.date.formatted(date: .abbreviated, time: .shortened)
        let parts = [("", date, RenderPalette.gold),
                     ("O ", fmt(c.open, decimals), RenderPalette.text),
                     ("H ", fmt(c.high, decimals), RenderPalette.text),
                     ("L ", fmt(c.low, decimals), RenderPalette.text),
                     ("C ", fmt(c.close, decimals), c.up ? RenderPalette.green : RenderPalette.red)]
        var x = p.x + 6
        let totalW = parts.reduce(CGFloat(0)) { $0 + CGFloat(($1.0 + $1.1).count) * 6.6 + 10 }
        ctx.setFillColor(RenderPalette.alpha(RenderPalette.bg, 0.85))
        ctx.fill(CGRect(x: p.x, y: p.y - 4, width: totalW + 8, height: 22))
        ctx.setStrokeColor(RenderPalette.stroke); ctx.stroke(CGRect(x: p.x, y: p.y - 4, width: totalW + 8, height: 22))
        for (lbl, val, col) in parts {
            if !lbl.isEmpty { drawText(ctx, lbl, at: CGPoint(x: x, y: p.y), size: 10, color: RenderPalette.sub); x += CGFloat(lbl.count)*6.6 }
            drawText(ctx, val, at: CGPoint(x: x, y: p.y), size: 10.5, color: col, bold: true)
            x += CGFloat(val.count) * 6.8 + 8
        }
    }

    // Draw the active engine signal: entry (gold), stop (red), target (green) horizontal lines,
    // each with a price tag on the right gutter. Entry tag also carries direction + engine. Honest:
    // a nil stop/target is simply not drawn. Tags are vertically nudged apart so they never overlap.
    private static func drawFire(_ ctx: CGContext, _ f: RenderFire, rect: CGRect, decimals: Int,
                                 yPrice: (Double) -> CGFloat) {
        let isLong = f.direction.lowercased().hasPrefix("l")
        let arrow = isLong ? "▲" : "▼"
        let verb = f.outcome == nil ? "ENTRY" : "EXIT \(f.outcome!.uppercased())"
        // (price, leftLabel, color, lineWidth, dash) per leg — only the legs that exist.
        var legs: [(Double, String, CGColor, CGFloat, [CGFloat])] = [
            (f.entry, "\(arrow) \(f.direction.uppercased()) \(verb) · \(f.engine)", RenderPalette.gold, 1.4, [6,3])
        ]
        if let st = f.stop   { legs.append((st, "STOP", RenderPalette.red, 1.0, [4,3])) }
        if let tg = f.target { legs.append((tg, "TGT",  RenderPalette.green, 1.0, [4,3])) }

        ctx.saveGState(); ctx.clip(to: rect)
        for (price, _, col, w, dash) in legs {
            let y = yPrice(price)
            guard y >= rect.minY - 1 && y <= rect.maxY + 1 else { continue }
            strokeLine(ctx, CGPoint(x: rect.minX, y: y), CGPoint(x: rect.maxX, y: y),
                       color: RenderPalette.alpha(col, 0.9), width: w, dash: dash)
        }
        ctx.restoreGState()

        // Right-gutter price tags (outside the clip so they sit in the ladder gutter), de-overlapped.
        var placed: [CGFloat] = []
        func nudge(_ y: CGFloat) -> CGFloat {
            var yy = min(max(y, rect.minY + 8), rect.maxY - 8)
            while placed.contains(where: { abs($0 - yy) < 14 }) { yy -= 14 }
            placed.append(yy); return yy
        }
        for (price, _, col, _, _) in legs {
            let y0 = yPrice(price); guard y0 >= rect.minY - 1 && y0 <= rect.maxY + 1 else { continue }
            let y = nudge(y0)
            let lbl = fmt(price, decimals)
            let tagW = textWidth(lbl, size: 9.5, bold: true) + 10, tagH: CGFloat = 15
            let tagRect = CGRect(x: rect.maxX + 3, y: y - tagH/2, width: tagW, height: tagH)
            ctx.setFillColor(col)
            ctx.addPath(CGPath(roundedRect: tagRect, cornerWidth: 3, cornerHeight: 3, transform: nil)); ctx.fillPath()
            drawText(ctx, lbl, at: CGPoint(x: tagRect.minX + 5, y: tagRect.midY - 4), size: 9.5,
                     color: CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1), bold: true)
        }
        // Entry leg's descriptive tag (direction · verb · engine) at the LEFT of the price pane.
        let entryY = min(max(yPrice(f.entry), rect.minY + 8), rect.maxY - 8)
        let etag = legs[0].1
        let etw = textWidth(etag, size: 9, bold: true) + 12
        let er = CGRect(x: rect.minX + 6, y: entryY - 8, width: etw, height: 16)
        ctx.setFillColor(RenderPalette.alpha(RenderPalette.bg, 0.82))
        ctx.addPath(CGPath(roundedRect: er, cornerWidth: 3, cornerHeight: 3, transform: nil)); ctx.fillPath()
        ctx.addPath(CGPath(roundedRect: er, cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.setStrokeColor(RenderPalette.alpha(RenderPalette.gold, 0.5)); ctx.setLineWidth(0.75); ctx.strokePath()
        drawText(ctx, etag, at: CGPoint(x: er.minX + 6, y: er.midY - 4), size: 9, color: RenderPalette.gold, bold: true)
    }

    private static func drawTimeAxis(_ ctx: CGContext, candles: [Candle], rect: CGRect, bottomY: CGFloat,
                                     slot: CGFloat, xCenter: (Int) -> CGFloat) {
        guard candles.count > 1 else { return }
        // Value-based ticks: labels land on round clock times; gaps become session breaks.
        for t in ChartScale.timeTicks(candles.map(\.date), maxLabels: 7) {
            let x = xCenter(t.index)
            if t.isSessionBreak {
                // dotted gold separator between candle i-1 and i — explains the overnight hole.
                let sx = x - slot * 0.5
                strokeLine(ctx, CGPoint(x: sx, y: rect.minY), CGPoint(x: sx, y: rect.maxY),
                           color: RenderPalette.alpha(RenderPalette.gold, 0.18), width: 1, dash: [2, 4])
            } else {
                strokeLine(ctx, CGPoint(x: x, y: rect.minY), CGPoint(x: x, y: rect.maxY),
                           color: RenderPalette.gridMinor, width: 0.5)
            }
            let tw = textWidth(t.label, size: 9, bold: t.isSessionBreak)
            drawText(ctx, t.label, at: CGPoint(x: x - tw/2, y: bottomY - 6), size: 9,
                     color: t.isSessionBreak ? RenderPalette.gold : RenderPalette.sub, bold: t.isSessionBreak)
        }
    }

    // Draw an indicator series ([Double?]) as a connected polyline, skipping nil leading values.
    private static func drawSeries(_ ctx: CGContext, _ series: [Double?], rect: CGRect,
                                   xCenter: (Int) -> CGFloat, y: (Double) -> CGFloat,
                                   color: CGColor, width: CGFloat, dash: [CGFloat] = []) {
        ctx.saveGState()
        ctx.clip(to: rect)   // keep overlay lines inside the price pane (no bleed into header/panes)
        ctx.setStrokeColor(color); ctx.setLineWidth(width); ctx.setLineJoin(.round); ctx.setLineCap(.round)
        if !dash.isEmpty { ctx.setLineDash(phase: 0, lengths: dash) }
        var started = false
        for (i, v) in series.enumerated() {
            guard let v = v else { continue }
            let pt = CGPoint(x: xCenter(i), y: y(v))
            if started { ctx.addLine(to: pt) } else { ctx.move(to: pt); started = true }
        }
        ctx.strokePath(); ctx.restoreGState()
    }

    // MARK: low-level helpers
    private static func drawPanel(_ ctx: CGContext, _ r: CGRect) {
        let path = CGPath(roundedRect: r, cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        fillVGradient(ctx, r, top: RenderPalette.panelHi, bottom: RenderPalette.panel)
        ctx.restoreGState()
        ctx.addPath(path); ctx.setStrokeColor(RenderPalette.stroke); ctx.setLineWidth(1); ctx.strokePath()
    }
    private static func fillVGradient(_ ctx: CGContext, _ r: CGRect, top: CGColor, bottom: CGColor) {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let g = CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray, locations: [0, 1]) else {
            ctx.setFillColor(bottom); ctx.fill(r); return
        }
        ctx.saveGState(); ctx.clip(to: r)
        // context origin is bottom-left, so visual top = max y.
        ctx.drawLinearGradient(g, start: CGPoint(x: r.midX, y: r.maxY), end: CGPoint(x: r.midX, y: r.minY), options: [])
        ctx.restoreGState()
    }
    // Measured glyph width (Menlo) — replaces the count*N estimates so tags/labels align.
    private static func textWidth(_ s: String, size: CGFloat, bold: Bool) -> CGFloat {
        let font = CTFontCreateWithName((bold ? "Menlo-Bold" : "Menlo") as CFString, size, nil)
        let attrs = [kCTFontAttributeName: font] as CFDictionary
        guard let astr = CFAttributedStringCreate(kCFAllocatorDefault, s as CFString, attrs) else { return 0 }
        let line = CTLineCreateWithAttributedString(astr)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
    private static func strokeLine(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint, color: CGColor, width: CGFloat, dash: [CGFloat] = []) {
        ctx.saveGState()
        ctx.setStrokeColor(color); ctx.setLineWidth(width)
        if !dash.isEmpty { ctx.setLineDash(phase: 0, lengths: dash) }
        ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
        ctx.restoreGState()
    }
    private static func fmt(_ v: Double, _ decimals: Int) -> String { String(format: "%.\(decimals)f", v) }

    // CoreText glyph drawing (CGContext is flipped: origin bottom-left, which matches our y math).
    enum Align { case left, center }
    private static func drawText(_ ctx: CGContext, _ s: String, at p: CGPoint, size: CGFloat,
                                 color: CGColor, bold: Bool = false, tracking: CGFloat = 0) {
        let font = CTFontCreateWithName((bold ? "Menlo-Bold" : "Menlo") as CFString, size, nil)
        let attrs = NSMutableDictionary()
        attrs[kCTFontAttributeName] = font
        attrs[kCTForegroundColorAttributeName] = color
        if tracking != 0 { attrs[kCTKernAttributeName] = tracking }
        let astr = CFAttributedStringCreate(kCFAllocatorDefault, s as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(astr)
        ctx.textPosition = p
        CTLineDraw(line, ctx)
    }
    private static func drawCentered(_ ctx: CGContext, _ s: String, at p: CGPoint, size: CGFloat, color: CGColor, align: Align) {
        let approxW = CGFloat(s.count) * size * 0.6
        drawText(ctx, s, at: CGPoint(x: p.x - approxW/2, y: p.y), size: size, color: color)
    }

    private static func makeContext(size: CGSize, scale: CGFloat) -> CGContext? {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        return CGContext(data: nil,
                         width: Int(size.width * scale), height: Int(size.height * scale),
                         bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
    private static func writePNG(_ img: CGImage, to path: String) -> Bool {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest)
    }
}
