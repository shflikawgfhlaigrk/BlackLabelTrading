// Black Label Trading — LIVE interactive chart (native AppKit canvas).
//
// This is the headline chart surface. It hosts the SAME CoreGraphics renderer the headless proof
// uses (ChartRender.drawChart) inside an NSView, and adds true TradingView-grade interaction that
// SwiftUI Charts can't do well:
//   • SCROLL to zoom (cursor-anchored — the bar under the pointer stays put)
//   • DRAG to pan  • PINCH (trackpad) to zoom  • two-finger scroll to pan
//   • live crosshair with an OHLC readout that follows the pointer
//   • keyboard: ←/→ pan, +/- zoom, F fit-all, E jump-to-live
//   • the latest (forming) bar stays glued to the right edge as live ticks fold in
//
// HONEST FRAMING: it renders ONLY the candles handed in (the buyer's own captured / imported
// bars). Empty -> an honest "no data" frame. Nothing is downloaded, sampled, or invented; the
// Y axis auto-fits the VISIBLE window only and is never widened to hide a move.
import SwiftUI
import AppKit

// Toolbar → view bridge. SwiftUI buttons can't reach an NSView directly, so the screen holds a
// controller, the representable registers the live view into it, and the buttons call through.
final class BLChartController: ObservableObject {
    weak var view: BLChartNSView?
    func zoomIn()   { view?.zoomCentered(1.45) }
    func zoomOut()  { view?.zoomCentered(1/1.45) }
    func panLeft()  { view?.pan(byFraction: -0.28) }
    func panRight() { view?.pan(byFraction: 0.28) }
    func fitAll()   { view?.fitAll() }
    func jumpToLive() { view?.jumpToLive() }
}

// MARK: - The interactive canvas.
final class BLChartNSView: NSView {
    // Data + presentation (pushed in by the representable each SwiftUI update).
    var candles: [Candle] = []
    var indicators = RenderIndicators()
    var lineMode = false
    var drawings: [Drawing] = []
    var symbol = ""
    var showVolume = true
    var activeTool: DrawingKind? = nil

    // Visible window over candle-index space. Fractional for buttery zoom/pan.
    private(set) var winStart: Double = 0
    private(set) var winCount: Double = 60
    private var stuckToLiveEdge = true
    private var initialized = false
    private var lastSymbol = ""

    // Interaction scratch.
    private var crosshairIndex: Int? = nil
    private var dragStartPx: CGPoint? = nil
    private var dragCurrentPx: CGPoint? = nil
    private var tracking: NSTrackingArea? = nil

    // Callback when the user finishes drawing a tool (screen persists it).
    var onCommitDrawing: ((Drawing) -> Void)? = nil

    override init(frame: NSRect) { super.init(frame: frame); commonInit() }
    required init?(coder: NSCoder) { super.init(coder: coder); commonInit() }
    private func commonInit() { wantsLayer = true; layerContentsRedrawPolicy = .onSetNeedsDisplay }

    override var isFlipped: Bool { false }            // origin bottom-left: matches ChartRender's math
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: state push from SwiftUI
    func apply(candles: [Candle], indicators: RenderIndicators, lineMode: Bool, drawings: [Drawing],
               symbol: String, showVolume: Bool, activeTool: DrawingKind?) {
        let symbolChanged = symbol != lastSymbol
        let oldCount = self.candles.count
        self.candles = candles
        self.indicators = indicators
        self.lineMode = lineMode
        self.drawings = drawings
        self.symbol = symbol
        self.showVolume = showVolume
        self.activeTool = activeTool
        lastSymbol = symbol

        let total = candles.count
        if symbolChanged || !initialized {
            // Fresh symbol → right-anchored ~60-bar window, glued to the live edge.
            winCount = total > 0 ? min(60, Double(total)) : 60
            winStart = max(0, Double(total) - winCount)
            stuckToLiveEdge = true
            crosshairIndex = nil
            initialized = total > 0 ? true : initialized
        } else if total != oldCount {
            clampWindow()
            if stuckToLiveEdge { winStart = max(0, Double(total) - winCount) }
        } else {
            clampWindow()
        }
        needsDisplay = true
    }

    // MARK: layout helpers (must agree pixel-for-pixel with what ChartRender draws)
    private func plotRect() -> CGRect {
        let L = ChartRender.layout(size: bounds.size, indicators: indicators, showVolume: showVolume,
                                   hasVolume: candles.contains { $0.volume > 0 }, header: false)
        return L.price
    }
    private func visibleDomain() -> (lo: Double, hi: Double) {
        let total = candles.count
        guard total > 0 else { return (0, 1) }
        let wc = winCount <= 0 ? Double(total) : min(Double(total), max(4, winCount))
        let ws = min(max(0, winStart), Double(total) - wc)
        let lo = max(0, Int(floor(ws)) - 1), hi = min(total - 1, Int(ceil(ws + wc)) + 1)
        let vis = lo <= hi ? Array(candles[lo...hi]) : candles
        return ChartScale.robustDomain(vis)
    }
    private func slotWidth() -> CGFloat { plotRect().width / CGFloat(max(1, winCount)) }
    // Fractional bar index under a pixel x (inverse of ChartRender's xCenter).
    private func indexAtX(_ px: CGFloat) -> Double {
        let r = plotRect(); guard r.width > 0 else { return winStart }
        let frac = Double((px - r.minX) / r.width)
        return winStart + frac * winCount - 0.5
    }
    private func priceAtY(_ py: CGFloat) -> Double {
        let r = plotRect(); guard r.height > 0 else { return 0 }
        let d = visibleDomain()
        let t = Double((py - r.minY) / r.height)
        return d.lo + t * (d.hi - d.lo)
    }

    private func clampWindow() {
        let total = Double(candles.count)
        guard total > 0 else { return }
        if total <= 8 { winCount = total; winStart = 0; return }
        winCount = min(total, max(8, winCount))
        winStart = min(max(0, winStart), total - winCount)
    }
    private func refreshStuck() {
        stuckToLiveEdge = (winStart + winCount >= Double(candles.count) - 0.75)
    }

    // MARK: zoom / pan primitives
    func zoom(atX px: CGFloat, factor: Double) {
        let total = Double(candles.count)
        guard total > 8 else { return }
        let r = plotRect(); guard r.width > 0 else { return }
        let frac = min(max(Double((px - r.minX) / r.width), 0), 1)
        let anchor = winStart + frac * winCount        // bar index under the cursor — keep it fixed
        var nc = winCount / max(factor, 0.0001)
        nc = min(total, max(8, nc))
        winCount = nc
        winStart = anchor - frac * nc
        clampWindow(); refreshStuck()
        needsDisplay = true
    }
    func zoomCentered(_ factor: Double) { zoom(atX: plotRect().midX, factor: factor) }
    func pan(byFraction f: Double) {
        let total = Double(candles.count); guard total > winCount else { return }
        winStart += f * winCount
        clampWindow(); refreshStuck(); needsDisplay = true
    }
    private func panByPixels(_ dx: CGFloat) {
        let slot = slotWidth(); guard slot > 0 else { return }
        winStart -= Double(dx / slot)
        clampWindow(); refreshStuck(); needsDisplay = true
    }
    func fitAll() {
        let total = Double(candles.count); guard total > 0 else { return }
        winCount = total; winStart = 0; stuckToLiveEdge = true; needsDisplay = true
    }
    func jumpToLive() {
        let total = Double(candles.count); guard total > 0 else { return }
        if winCount <= 0 || winCount >= total { winCount = min(60, total) }
        winStart = max(0, total - winCount); stuckToLiveEdge = true; needsDisplay = true
    }

    // MARK: events
    override func scrollWheel(with event: NSEvent) {
        guard candles.count > 8 else { return }
        let p = convert(event.locationInWindow, from: nil)
        if event.hasPreciseScrollingDeltas {
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            if abs(dx) > abs(dy) * 1.25 {
                panByPixels(dx)                              // horizontal two-finger scroll → pan
            } else if dy != 0 {
                zoom(atX: p.x, factor: exp(Double(dy) * 0.0045))   // vertical scroll → cursor-anchored zoom
            }
        } else {
            // mouse wheel notch → zoom anchored at the cursor
            let f = event.scrollingDeltaY >= 0 ? 1.18 : 1 / 1.18
            zoom(atX: p.x, factor: f)
        }
    }
    override func magnify(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        zoom(atX: p.x, factor: 1 + Double(event.magnification))
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 { jumpToLive(); return }
        if activeTool != nil { dragStartPx = p; dragCurrentPx = p }
    }
    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if activeTool != nil {
            if dragStartPx == nil { dragStartPx = p }
            dragCurrentPx = p; needsDisplay = true
        } else {
            winStart -= Double(event.deltaX) / Double(max(slotWidth(), 0.0001))
            clampWindow(); refreshStuck()
            updateCrosshair(at: p); needsDisplay = true
        }
    }
    override func mouseUp(with event: NSEvent) {
        defer { dragStartPx = nil; dragCurrentPx = nil }
        guard let tool = activeTool, let s = dragStartPx, let c = dragCurrentPx else { return }
        let d = Drawing(kind: tool, x1: indexAtX(s.x), y1: priceAtY(s.y), x2: indexAtX(c.x), y2: priceAtY(c.y))
        onCommitDrawing?(d)
    }
    override func mouseMoved(with event: NSEvent) { updateCrosshair(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { crosshairIndex = nil; needsDisplay = true }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers ?? "" {
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!):  pan(byFraction: -0.18)
        case String(UnicodeScalar(NSRightArrowFunctionKey)!): pan(byFraction: 0.18)
        case "+", "=": zoomCentered(1.45)
        case "-", "_": zoomCentered(1/1.45)
        case "f", "F": fitAll()
        case "e", "E": jumpToLive()
        default: super.keyDown(with: event)
        }
    }

    private func updateCrosshair(at p: CGPoint) {
        let r = plotRect()
        guard candles.count > 0, p.x >= r.minX, p.x <= r.maxX, p.y >= r.minY, p.y <= r.maxY else {
            if crosshairIndex != nil { crosshairIndex = nil; needsDisplay = true }; return
        }
        let idx = min(max(Int(indexAtX(p.x).rounded()), 0), candles.count - 1)
        if idx != crosshairIndex { crosshairIndex = idx; needsDisplay = true }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.activeInActiveApp, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }

    // MARK: draw
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        var ind = indicators
        ind.crosshairIndex = crosshairIndex
        ChartRender.drawChart(ctx: ctx, size: bounds.size, candles: candles, symbol: symbol, title: "",
                              indicators: ind, showVolume: showVolume, lineMode: lineMode,
                              winStart: winStart, winCount: winCount, drawings: drawings, header: false)
        drawToolPreview(ctx)
    }

    private func drawToolPreview(_ ctx: CGContext) {
        guard let tool = activeTool, let s = dragStartPx, let c = dragCurrentPx else { return }
        let r = plotRect()
        let gold = CGColor(red: 0.851, green: 0.714, blue: 0.361, alpha: 0.7)
        ctx.saveGState(); ctx.clip(to: r)
        ctx.setStrokeColor(gold); ctx.setLineWidth(1.5); ctx.setLineDash(phase: 0, lengths: [4, 3])
        switch tool {
        case .horizontal:
            ctx.move(to: CGPoint(x: r.minX, y: c.y)); ctx.addLine(to: CGPoint(x: r.maxX, y: c.y)); ctx.strokePath()
        case .rect:
            ctx.stroke(CGRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(c.x - s.x), height: abs(c.y - s.y)))
        case .fib:
            for ratio in [0.0, 0.236, 0.382, 0.5, 0.618, 0.786, 1.0] {
                let y = s.y + (c.y - s.y) * CGFloat(ratio)
                ctx.move(to: CGPoint(x: r.minX, y: y)); ctx.addLine(to: CGPoint(x: r.maxX, y: y))
            }
            ctx.strokePath()
        default:
            ctx.move(to: s); ctx.addLine(to: c); ctx.strokePath()
        }
        ctx.restoreGState()
    }
}

// MARK: - SwiftUI bridge.
struct BLChartView: NSViewRepresentable {
    var candles: [Candle]
    var indicators: RenderIndicators
    var lineMode: Bool
    var drawings: [Drawing]
    var symbol: String
    var showVolume: Bool
    var activeTool: DrawingKind?
    var controller: BLChartController
    var onCommitDrawing: (Drawing) -> Void

    func makeNSView(context: Context) -> BLChartNSView {
        let v = BLChartNSView()
        controller.view = v
        v.onCommitDrawing = onCommitDrawing
        v.apply(candles: candles, indicators: indicators, lineMode: lineMode, drawings: drawings,
                symbol: symbol, showVolume: showVolume, activeTool: activeTool)
        return v
    }
    func updateNSView(_ v: BLChartNSView, context: Context) {
        controller.view = v
        v.onCommitDrawing = onCommitDrawing
        v.apply(candles: candles, indicators: indicators, lineMode: lineMode, drawings: drawings,
                symbol: symbol, showVolume: showVolume, activeTool: activeTool)
    }
}
