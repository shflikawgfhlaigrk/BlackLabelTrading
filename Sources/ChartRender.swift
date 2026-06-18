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

// Palette mirrors BLTheme (Black Gold) so the proof looks like the shipping chart.
enum RenderPalette {
    static let bg      = CGColor(red: 0.043, green: 0.043, blue: 0.051, alpha: 1)   // #0B0B0D
    static let panel   = CGColor(red: 0.071, green: 0.071, blue: 0.086, alpha: 1)   // #121216
    static let stroke  = CGColor(red: 1, green: 1, blue: 1, alpha: 0.10)
    static let grid    = CGColor(red: 1, green: 1, blue: 1, alpha: 0.06)
    static let text    = CGColor(red: 0.93, green: 0.93, blue: 0.95, alpha: 1)
    static let sub     = CGColor(red: 0.55, green: 0.56, blue: 0.62, alpha: 1)
    static let gold     = CGColor(red: 0.96, green: 0.78, blue: 0.30, alpha: 1)
    static let goldHi   = CGColor(red: 1.0,  green: 0.88, blue: 0.52, alpha: 1)
    static let green    = CGColor(red: 0.20, green: 0.82, blue: 0.52, alpha: 1)
    static let red      = CGColor(red: 0.95, green: 0.33, blue: 0.36, alpha: 1)
    static let blue     = CGColor(red: 0.40, green: 0.66, blue: 0.98, alpha: 1)
    static func alpha(_ c: CGColor, _ a: CGFloat) -> CGColor { c.copy(alpha: a) ?? c }
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
        // Background.
        ctx.setFillColor(RenderPalette.bg); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

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
        let marginL: CGFloat = 18, marginR: CGFloat = 70, gap: CGFloat = 10
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
        let lo = candles.map(\.low).min() ?? 0
        let hi = candles.map(\.high).max() ?? 1
        let dom = ChartScale.priceDomain(low: lo, high: hi)
        let useLog = ind.logScale && dom.lo > 0

        // x mapping: candle index -> pixel center.
        let slot = plotW / CGFloat(max(1, n))
        func xCenter(_ i: Int) -> CGFloat { priceRect.minX + (CGFloat(i) + 0.5) * slot }
        func yPrice(_ p: Double, _ r: CGRect) -> CGFloat {
            CGFloat(ChartScale.yPixel(p, lo: dom.lo, hi: dom.hi,
                                      topY: Double(r.maxY), bottomY: Double(r.minY), log: useLog))
        }

        // ---- Price pane: panel, gridlines, y-axis labels ----
        drawPanel(ctx, priceRect)
        let ticks = ChartScale.ticks(lo: dom.lo, hi: dom.hi, target: 7)
        let step = ticks.count > 1 ? (ticks[1] - ticks[0]) : (dom.hi - dom.lo)
        let decimals = ChartScale.priceDecimals(step: step)
        for t in ticks {
            let y = yPrice(t, priceRect)
            guard y >= priceRect.minY - 0.5 && y <= priceRect.maxY + 0.5 else { continue }
            strokeLine(ctx, CGPoint(x: priceRect.minX, y: y), CGPoint(x: priceRect.maxX, y: y),
                       color: RenderPalette.grid, width: 1)
            drawText(ctx, fmt(t, decimals), at: CGPoint(x: priceRect.maxX + 6, y: y - 5),
                     size: 10, color: RenderPalette.sub)
        }
        // x gridlines + date axis (a handful of evenly spaced labels with gap-free index spacing).
        drawTimeAxis(ctx, candles: candles, rect: priceRect, bottomY: bottomAxis, xCenter: xCenter)

        // ---- Indicator overlays (under candles for VWAP/BB band, over for MAs reads fine) ----
        let closes = candles.map(\.close)
        if let bb = ind.bollinger {
            let b = ChartIndicators.bollinger(closes, period: bb.period, k: bb.k)
            drawSeries(ctx, b.upper, rect: priceRect, xCenter: xCenter, y: { yPrice($0, priceRect) }, color: RenderPalette.alpha(RenderPalette.blue, 0.55), width: 1.1, dash: [4,3])
            drawSeries(ctx, b.lower, rect: priceRect, xCenter: xCenter, y: { yPrice($0, priceRect) }, color: RenderPalette.alpha(RenderPalette.blue, 0.55), width: 1.1, dash: [4,3])
            drawSeries(ctx, b.mid,   rect: priceRect, xCenter: xCenter, y: { yPrice($0, priceRect) }, color: RenderPalette.alpha(RenderPalette.blue, 0.30), width: 0.9, dash: [2,3])
        }

        // ---- Candles ----
        let bodyW = max(1.5, slot * 0.62)
        for c in candles {
            let x = xCenter(c.index)
            let col = c.up ? RenderPalette.green : RenderPalette.red
            // Wick
            strokeLine(ctx, CGPoint(x: x, y: yPrice(c.high, priceRect)), CGPoint(x: x, y: yPrice(c.low, priceRect)),
                       color: RenderPalette.alpha(col, 0.9), width: max(1, slot * 0.10))
            // Body
            let yo = yPrice(c.open, priceRect), yc = yPrice(c.close, priceRect)
            let top = min(yo, yc), bot = max(yo, yc)
            let bodyH = max(1, bot - top)
            ctx.setFillColor(col)
            ctx.fill(CGRect(x: x - bodyW/2, y: top, width: bodyW, height: bodyH))
        }

        // Moving averages / VWAP (drawn over candles).
        if let p = ind.sma { drawSeries(ctx, Indicators.sma(closes, p), rect: priceRect, xCenter: xCenter, y: { yPrice($0, priceRect) }, color: RenderPalette.gold, width: 1.8) }
        if let p = ind.ema1 { drawSeries(ctx, Indicators.ema(closes, p), rect: priceRect, xCenter: xCenter, y: { yPrice($0, priceRect) }, color: RenderPalette.goldHi, width: 1.8) }
        if let p = ind.ema2 { drawSeries(ctx, Indicators.ema(closes, p), rect: priceRect, xCenter: xCenter, y: { yPrice($0, priceRect) }, color: RenderPalette.blue, width: 1.8) }
        if let w = ind.vwapWindow { drawSeries(ctx, ChartIndicators.vwap(bars, window: w), rect: priceRect, xCenter: xCenter, y: { yPrice($0, priceRect) }, color: RenderPalette.green, width: 1.8, dash: [6,3]) }

        // Last-price line (real value only — never fabricated).
        if let lp = ind.lastPriceLine {
            let y = yPrice(lp, priceRect)
            strokeLine(ctx, CGPoint(x: priceRect.minX, y: y), CGPoint(x: priceRect.maxX, y: y),
                       color: RenderPalette.alpha(RenderPalette.goldHi, 0.9), width: 1, dash: [2,3])
            let lbl = fmt(lp, decimals)
            let tw = CGFloat(lbl.count) * 7 + 10
            ctx.setFillColor(RenderPalette.goldHi)
            ctx.fill(CGRect(x: priceRect.maxX + 2, y: y - 8, width: tw, height: 16))
            drawText(ctx, lbl, at: CGPoint(x: priceRect.maxX + 7, y: y - 5), size: 10, color: CGColor(red:0.05,green:0.05,blue:0.05,alpha:1), bold: true)
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
                let x = xCenter(c.index)
                let h = CGFloat(c.volume / max(maxV, 1)) * (volRect.height - 4)
                ctx.setFillColor(RenderPalette.alpha(c.up ? RenderPalette.green : RenderPalette.red, 0.5))
                ctx.fill(CGRect(x: x - bodyW/2, y: volRect.minY, width: bodyW, height: max(0.5, h)))
            }
            drawText(ctx, "Volume", at: CGPoint(x: volRect.minX + 8, y: volRect.maxY - 16), size: 10, color: RenderPalette.sub, bold: true)
        }

        // Legend chips (which overlays are on).
        drawLegend(ctx, ind: ind, at: CGPoint(x: priceRect.minX + 8, y: priceRect.minY + 8))
    }

    // MARK: header
    private static func drawHeader(ctx: CGContext, rect: CGRect, symbol: String, title: String, bars: [Bar]) {
        // gold underline
        strokeLine(ctx, CGPoint(x: 0, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                   color: RenderPalette.alpha(RenderPalette.gold, 0.25), width: 1)
        drawText(ctx, "BLACK LABEL TRADING", at: CGPoint(x: 18, y: rect.maxY - 22), size: 11, color: RenderPalette.gold, bold: true, tracking: 1.5)
        drawText(ctx, title, at: CGPoint(x: 18, y: rect.minY + 10), size: 16, color: RenderPalette.text, bold: true)
        // Right-aligned last close.
        if let last = bars.last {
            let up = last.close >= last.open
            let s = String(format: "%@ %.2f", up ? "▲" : "▼", last.close)
            drawText(ctx, s, at: CGPoint(x: rect.maxX - 18 - CGFloat(s.count)*9, y: rect.minY + 14),
                     size: 17, color: up ? RenderPalette.green : RenderPalette.red, bold: true)
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

    private static func drawTimeAxis(_ ctx: CGContext, candles: [Candle], rect: CGRect, bottomY: CGFloat,
                                     xCenter: (Int) -> CGFloat) {
        guard candles.count > 1 else { return }
        let want = 6
        let stride = max(1, candles.count / want)
        let f = DateFormatter(); f.dateFormat = "MM/dd HH:mm"
        var i = 0
        while i < candles.count {
            let x = xCenter(i)
            strokeLine(ctx, CGPoint(x: x, y: rect.minY), CGPoint(x: x, y: rect.maxY),
                       color: RenderPalette.grid, width: 1)
            drawText(ctx, f.string(from: candles[i].date), at: CGPoint(x: x - 24, y: bottomY - 6),
                     size: 9, color: RenderPalette.sub)
            i += stride
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
        ctx.setFillColor(RenderPalette.panel); ctx.fill(r)
        ctx.setStrokeColor(RenderPalette.stroke); ctx.setLineWidth(1); ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
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
