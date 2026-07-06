// Black Label TRADING — HOLOGRAPHIC PREMIUM FX KIT
// ───────────────────────────────────────────────────────────────────────────────
// Mirrors the canonical RealEstate Holographic.swift kit (same public API), adapted to this
// app's gold `BLTheme` palette + its persisted `HoloTheme` settings store.
//
// Everything here is PURELY VISUAL — no data, no Utah, no fabricated values. Every component
// reads the live `HoloTheme` from the environment (never a hardcoded intensity), so the buyer's
// Theme / Appearance Studio choices re-skin the entire app instantly. All continuous motion is
// gated behind `\.blMotion` (the in-app Motion toggle AND system Reduce Motion) and additionally
// scaled by the theme's Motion Level — Reduce Motion ALWAYS hard-overrides to a gorgeous static
// fallback.
//
// Perf contract: 60fps, GPU-light. Canvas/TimelineView for living layers, `.drawingGroup()` on
// particle/aurora canvases, particle counts capped (HoloTheme.PARTICLE_CAP), no full-window heavy
// blur loops.
//
// NO CURSOR-FOLLOWING SPECULAR HIGHLIGHT — removed per owner feedback (it blurred card content).
// Hover feel = 3D tilt + iridescent animated border + glow only.
//
// Components:
//   AuroraBackdrop            living animated background (drifting blobs / starfield / solid)
//   .holoCard()               signature surface: iridescent border + glow + pointer 3D tilt + sweep
//   .holoSheen()              moving diagonal iridescent light sweep over any surface
//   FoilText                  metallic/holographic headline text (gradient + sheen + glow)
//   ParticleField             drifting gold motes (Canvas, capped, parallax)
//   AnimatedCounter           numbers roll/transition on change (.numericText)
//   IridescentBorder          animated rim-light for CTAs / selected states
//   GlowPulse                 soft pulsing glow on the primary action
//   HoloShimmerSkeleton       holographic loading shimmer (never a spinner)
//   ParallaxLayer             depth: layers move at different rates on pointer
import SwiftUI
import AppKit

// MARK: - BL palette bridge  (the FX kit's neutral tokens, mapped onto BLTheme)
// The reference kit references BL.base / BL.glassFill / BL.hair2 / BL.bg2v. We map them onto this
// app's existing gold palette so the look matches the rest of Trading.
enum BL {
    static var base: Color { BLTheme.bg }              // deep app base
    static var bg2v: Color { BLTheme.bg2 }             // recessed surface (skeleton fill)
    // LEGIBILITY: the reading base behind text is FULLY OPAQUE (no aurora bleed-through). The card
    // still frosts what's behind it via .ultraThinMaterial, but a solid panel tint sits UNDER the
    // material so text always reads on a high-contrast surface. (Was panel.opacity(0.55) — that let
    // the moving aurora show through and fuzz text; owner feedback "clear as shit".)
    static var glassFill: Color { BLTheme.panel }      // opaque reading base behind card content
    static var hair2: Color { BLTheme.stroke }         // hairline stroke
}

// MARK: - BLFont  (display + body fonts the kit's FoilText uses)
enum BLFont {
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    static func body(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

// MARK: - Live environment
// The FX kit reads the theme + the motion gate from the environment so any view renders with the
// buyer's look. `\.blMotion` = (in-app Motion toggle) AND (NOT system Reduce Motion).
struct HoloThemeKey: EnvironmentKey { static let defaultValue = HoloTheme.goldVault }
struct BLMotionKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var holoTheme: HoloTheme {
        get { self[HoloThemeKey.self] }
        set { self[HoloThemeKey.self] = newValue }
    }
    var blMotion: Bool {
        get { self[BLMotionKey.self] }
        set { self[BLMotionKey.self] = newValue }
    }
}

// MARK: - FXClock  (wall-clock phases for TimelineView-driven FX loops)
// Every continuous FX loop is driven by a pausable TimelineView computing its phase from the
// wall clock — NEVER by `withAnimation(.repeatForever)` on @State. A running repeatForever
// cannot be cancelled: re-assigning the value (plainly or via a zero-duration withAnimation)
// leaves the animation attached, and the layer keeps re-rasterizing every frame even when the
// rendered output is frozen (measured 2026-07-03: ~40% CPU while DEACTIVATED, conic border
// stroke hot in the sample). A TimelineView with `paused: true` provably stops ticking (0.0%).
// Wall-clock phases also mean no per-view start bookkeeping — loops stay in step for free.
enum FXClock {
    /// 0→1 sawtooth with the given period (seconds).
    static func loop(_ date: Date, _ period: Double) -> Double {
        let per = max(0.001, period)
        let p = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: per) / per
        return p < 0 ? p + 1 : p
    }
    /// 0→1→0 triangle, `period` seconds each way (the old autoreverse loops).
    static func pingPong(_ date: Date, _ period: Double) -> Double {
        let p = loop(date, period * 2)
        return p < 0.5 ? p * 2 : 2 - p * 2
    }
    /// Standard easeInOut, matching the feel of the old .easeInOut sweep loops.
    static func easeInOut(_ p: Double) -> Double { p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2 }
}

// MARK: - Live theme controller  (observable; persists to HoloThemeStore)
// Injected at the root; the Theme Studio mutates `theme`, which re-renders the whole app instantly.
final class HoloThemeController: ObservableObject {
    @Published var theme: HoloTheme { didSet { HoloThemeStore.saveTheme(theme) } }
    @Published var motionEnabled: Bool { didSet { HoloThemeStore.motionEnabled = motionEnabled } }
    @Published var customPresets: [HoloPreset] { didSet { HoloThemeStore.savePresets(customPresets) } }

    init() {
        theme = HoloThemeStore.loadTheme()
        motionEnabled = HoloThemeStore.motionEnabled
        customPresets = HoloThemeStore.loadPresets()
    }

    func apply(_ t: HoloTheme) { withAnimation(.easeInOut(duration: 0.45)) { theme = t } }
    func saveCurrentAsPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        customPresets.append(HoloPreset(name: trimmed.isEmpty ? "My Look" : trimmed, theme: theme))
    }
    func deletePreset(_ p: HoloPreset) { customPresets.removeAll { $0.id == p.id } }
    func resetToDefault() { apply(.goldVault) }
}

// Inject `\.blMotion` from the controller + the live system Reduce-Motion setting + app
// activity: ambient FX pause when the app is backgrounded (an idle window burned ~20% CPU
// on TimelineView/repeatForever layers that never slept — same gate as Marketing) AND when
// the displays sleep (a frontmost app on a dark/locked screen otherwise keeps ticking its
// 30fps timelines — measured ~40% CPU rendering to a screen nobody can see). Screen sleep
// posts on NSWorkspace.shared.notificationCenter, not the default center.
struct HoloEnvironment: ViewModifier {
    @ObservedObject var controller: HoloThemeController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appActive = true
    @State private var screenAwake = true
    func body(content: Content) -> some View {
        content
            .environment(\.holoTheme, controller.theme)
            .environment(\.blMotion, controller.motionEnabled && !reduceMotion && appActive && screenAwake)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in appActive = false }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in appActive = true }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidSleepNotification)) { _ in screenAwake = false }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidWakeNotification)) { _ in screenAwake = true }
    }
}
extension View {
    /// Inject the live HoloTheme + the effective motion gate (toggle AND not Reduce Motion).
    func holoEnvironment(_ controller: HoloThemeController) -> some View { modifier(HoloEnvironment(controller: controller)) }
}

// MARK: - Color hex helpers
extension HoloTheme {
    var accent: Color { Color(hex: accentHex) }
    var accentHi: Color { Color(hex: accentHiHex) }
    var accentDim: Color { Color(hex: accentDimHex) }
    var iridescent: Color { Color(hex: iridescentHex) }
    /// Iridescent sweep stops used by borders/foil: accent → highlight → iridescent → highlight → accent.
    var spectrum: [Color] { [accent, accentHi, iridescent, accentHi, accent] }
}
extension Color {
    /// Best-effort sRGB hex of this color (for persisting a custom-picked accent).
    var holoHex: UInt32 {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.gray
        let r = UInt32((ns.redComponent * 255).rounded())
        let g = UInt32((ns.greenComponent * 255).rounded())
        let b = UInt32((ns.blueComponent * 255).rounded())
        return (r << 16) | (g << 8) | b
    }
}

// Tiny deterministic RNG so the starfield/particles are stable across frames.
// (Named HoloRNG to avoid colliding with the SeededRNG already defined in BacktestDepth.swift.)
struct HoloRNG {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state }
    mutating func next01() -> CGFloat { CGFloat(Double(next() >> 11) / Double(1 << 53)) }
}

// MARK: - 1. AuroraBackdrop  (living animated background)
// Drifting blurred color blobs (Aurora), a parallax star Canvas (Starfield), or a calm solid.
// Driven by TimelineView(.animation) so it drifts forever, eased. Replaces flat backgrounds.
struct AuroraBackdrop: View {
    @Environment(\.holoTheme) private var theme
    @Environment(\.blMotion) private var motion
    var body: some View {
        ZStack {
            BL.base.ignoresSafeArea()
            switch theme.background {
            case .aurora:    auroraBlobs
            case .starfield: Starfield().ignoresSafeArea()
            case .solid:     solidWash
            }
            // Faint vignette for depth on every style.
            RadialGradient(colors: [.clear, .black.opacity(0.35)], center: .center, startRadius: 320, endRadius: 900)
                .ignoresSafeArea().allowsHitTesting(false)
        }
        // FOOLPROOF: this is a purely-decorative full-area background. Disabling hit-testing on the
        // ENTIRE struct body means it can NEVER intercept a click on the content above it, no matter
        // where it's placed in a ZStack (it sits behind content as a true background layer). The inner
        // BL.base Rectangle + solidWash are otherwise hit-testable and would eat clicks.
        .allowsHitTesting(false)
    }
    private var speed: Double { theme.motion.speed == 0 || !motion ? 0 : theme.motion.speed }
    private var solidWash: some View {
        ZStack {
            RadialGradient(colors: [theme.accent.opacity(0.07 * theme.fxScale), .clear], center: .topTrailing, startRadius: 0, endRadius: 760).ignoresSafeArea()
            RadialGradient(colors: [theme.iridescent.opacity(0.05 * theme.fxScale), .clear], center: .bottomLeading, startRadius: 0, endRadius: 640).ignoresSafeArea()
        }
    }
    private var auroraBlobs: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: speed == 0 ? nil : 1.0/30.0, paused: speed == 0)) { tl in
                let t = speed == 0 ? 0 : tl.date.timeIntervalSinceReferenceDate * 0.05 * speed
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    blob(theme.accent,      0.22, base: CGPoint(x: 0.18, y: 0.20), t: t, p: 0.0, w: w, h: h, r: 320)
                    blob(theme.accentDim,   0.18, base: CGPoint(x: 0.82, y: 0.78), t: t, p: 1.7, w: w, h: h, r: 300)
                    blob(theme.iridescent,  0.14, base: CGPoint(x: 0.70, y: 0.22), t: t, p: 3.1, w: w, h: h, r: 260)
                    blob(theme.accentHi,    0.10, base: CGPoint(x: 0.30, y: 0.80), t: t, p: 4.6, w: w, h: h, r: 240)
                }
                .blur(radius: 90)
                .opacity(0.5 + 0.5 * theme.fxScale)
                .drawingGroup()              // GPU-composite the blurred layer
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
    @ViewBuilder private func blob(_ c: Color, _ op: Double, base: CGPoint, t: Double, p: Double, w: CGFloat, h: CGFloat, r: CGFloat) -> some View {
        let dx = CGFloat(cos(t + p)) * w * 0.06
        let dy = CGFloat(sin(t * 0.8 + p)) * h * 0.06
        Circle().fill(c.opacity(op * (0.6 + 0.4 * theme.fxScale)))
            .frame(width: r, height: r)
            .position(x: base.x * w + dx, y: base.y * h + dy)
    }
}

// Parallax star Canvas — capped points, drifts slowly, twinkles. GPU-light.
struct Starfield: View {
    @Environment(\.holoTheme) private var theme
    @Environment(\.blMotion) private var motion
    private let stars: [(CGPoint, CGFloat, Double)] = (0..<90).map { i in
        var g = HoloRNG(seed: UInt64(i) &* 2654435761)
        return (CGPoint(x: g.next01(), y: g.next01()), CGFloat(0.5 + g.next01() * 1.6), g.next01())
    }
    var body: some View {
        let speed = theme.motion.speed == 0 || !motion ? 0.0 : theme.motion.speed
        TimelineView(.animation(paused: speed == 0)) { tl in
            let t = speed == 0 ? 0 : tl.date.timeIntervalSinceReferenceDate * 0.04 * speed
            Canvas { ctx, size in
                for (p, rad, phase) in stars {
                    let y = (p.y + CGFloat(t * 0.02)).truncatingRemainder(dividingBy: 1.0)
                    let tw = 0.4 + 0.6 * abs(sin(t * 1.2 + phase * 6.28))
                    let rect = CGRect(x: p.x * size.width, y: y * size.height, width: rad, height: rad)
                    ctx.fill(Path(ellipseIn: rect), with: .color(theme.accentHi.opacity(0.5 * tw)))
                }
            }
            .drawingGroup()
        }
        .background(BL.base)
        .allowsHitTesting(false)
    }
}

// MARK: - 2. HoloCard  (the signature surface)
// .ultraThinMaterial + panel tint, iridescent animated border, layered shadow + gold glow,
// inner top highlight, pointer 3D tilt, and a diagonal iridescent sweep. Falls back to a gorgeous
// static card when motion is off. Reads HoloTheme for ALL intensities. Call-site API is stable:
// `.holoCard(radius:sweep:)`. NO cursor-following specular highlight — it blurred card content.
struct HoloCard: ViewModifier {
    var radius: CGFloat
    var sweep: Bool
    @Environment(\.blMotion) private var motion
    @Environment(\.holoTheme) private var theme
    @State private var hover = false
    @State private var local: CGPoint = .init(x: 0.5, y: 0.5)   // cursor position within card (0…1)
    @State private var size: CGSize = .zero

    private var fx: Double { theme.fxScale }
    private var glow: Double { theme.glowStrength }
    private var tiltAmt: Double { theme.tiltEnabled ? theme.tiltStrength : 0 }

    func body(content: Content) -> some View {
        let live = motion && theme.motion.speed > 0
        // The full card surface WITHOUT any 3D tilt. When tilt is enabled we wrap this in the two
        // rotation3DEffect modifiers; when it's off they are ABSENT from the view tree (a true branch,
        // not .degrees(0)) so text never picks up perspective softening.
        let surface = content
            .background(
                // LEGIBILITY: a FULLY OPAQUE reading base sits directly behind content (text never
                // over aurora). The .ultraThinMaterial frosts what's behind the CARD for the glass
                // look, but it lives UNDER the opaque tint so it never lowers text contrast.
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)                 // frosts the aurora behind the card
                    BL.glassFill.opacity(theme.readingSurfaceOpacity)    // opaque reading base (==1.0)
                    LinearGradient(colors: [Color.white.opacity(0.04), .clear], startPoint: .top, endPoint: .bottom)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            // Diagonal sheen sweep (pausable TimelineView — wall-clock phase, no repeatForever).
            .overlay {
                if sweep && fx > 0 {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !live)) { tl in
                        let sx = live ? -1.0 + 3.0 * FXClock.easeInOut(FXClock.loop(tl.date, 7 / max(0.3, theme.motion.speed))) : 2.0
                        GeometryReader { geo in
                            LinearGradient(colors: [.clear, theme.accentHi.opacity(0.0), theme.accentHi.opacity(0.5 * fx), Color.white.opacity(0.3 * fx), theme.accentHi.opacity(0.0), .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: geo.size.width * 0.5)
                                .offset(x: sx * geo.size.width * 1.5)
                                .blendMode(.screen).allowsHitTesting(false)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    }
                    .allowsHitTesting(false)
                }
            }
            // Iridescent animated border (rotating AngularGradient) — or static gold when motion off.
            // Decorative rim — never hit-testable so the card's content/buttons stay clickable.
            .overlay(
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !live || fx <= 0)) { tl in
                    let a = live && fx > 0 ? 360 * FXClock.loop(tl.date, 18 / max(0.3, theme.motion.speed)) : 90
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(borderStyle(angle: .degrees(a)), lineWidth: 1)
                }
                .allowsHitTesting(false)
            )
            // Inner top highlight (subtle glass edge).
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(LinearGradient(colors: [Color.white.opacity(0.10), .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
                    .blendMode(.overlay).allowsHitTesting(false)
            )
            .shadow(color: .black.opacity(0.5), radius: hover ? 28 : 22, x: 0, y: hover ? 16 : 12)
            .shadow(color: theme.accent.opacity((hover ? 0.22 : 0.12) * glow), radius: hover ? 34 : 28, x: 0, y: 0)

        // Tilt is OPT-IN. Only when the theme enables it do the rotation3DEffect modifiers exist —
        // otherwise the branch below skips them entirely (zero perspective on text/content).
        return Group {
            if theme.tiltEnabled {
                surface
                    // Pointer-tracking 3D tilt (NO specular sheen).
                    .rotation3DEffect(.degrees(hover ? (Double(local.y) - 0.5) * -7 * tiltAmt : 0), axis: (x: 1, y: 0, z: 0), perspective: 0.4)
                    .rotation3DEffect(.degrees(hover ? (Double(local.x) - 0.5) * 7 * tiltAmt : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
            } else {
                surface
            }
        }
            .background(GeometryReader { g in Color.clear.onAppear { size = g.size }.onChange(of: g.size) { size = $0 } })
            .onContinuousHover { ph in
                switch ph {
                case .active(let pt):
                    withAnimation(.easeOut(duration: 0.12)) { hover = true }
                    if size.width > 0, size.height > 0 { local = CGPoint(x: pt.x / size.width, y: pt.y / size.height) }
                case .ended:
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { hover = false; local = CGPoint(x: 0.5, y: 0.5) }
                }
            }
    }
    private func borderStyle(angle: Angle) -> AnyShapeStyle {
        if fx <= 0 { return AnyShapeStyle(LinearGradient(colors: [theme.accent.opacity(0.28), BL.hair2.opacity(0.7)], startPoint: .top, endPoint: .bottom)) }
        let a = angle
        return AnyShapeStyle(AngularGradient(
            colors: [theme.accent.opacity(0.5 * fx), theme.iridescent.opacity(0.45 * fx), theme.accentHi.opacity(0.55 * fx),
                     theme.accentDim.opacity(0.35 * fx), theme.accent.opacity(0.5 * fx)],
            center: .center, angle: a))
    }
}
extension View {
    /// Apply the signature holographic card surface. API is stable across the suite.
    func holoCard(radius: CGFloat = 16, sweep: Bool = true) -> some View {
        modifier(HoloCard(radius: radius, sweep: sweep))
    }
}

// MARK: - 3. HoloSheen  (moving diagonal iridescent light sweep over any surface/text)
struct HoloSheen: ViewModifier {
    var angle: Double
    @Environment(\.blMotion) private var motion
    @Environment(\.holoTheme) private var theme
    func body(content: Content) -> some View {
        let fx = theme.fxScale
        let live = motion && theme.motion.speed > 0
        content.overlay {
            if fx > 0 {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !live)) { tl in
                    let x = live ? -1.2 + 3.2 * FXClock.easeInOut(FXClock.loop(tl.date, 4.5 / max(0.4, theme.motion.speed))) : 2.0
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, Color.white.opacity(0.0), theme.accentHi.opacity(0.55 * fx), Color.white.opacity(0.35 * fx), theme.iridescent.opacity(0.0), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.6)
                            .offset(x: x * geo.size.width * 1.6)
                            .rotationEffect(.degrees(angle))
                            .blendMode(.screen).allowsHitTesting(false)
                    }
                    .mask(content)
                }
                .allowsHitTesting(false)
            }
        }
    }
}
extension View {
    /// Moving iridescent light sweep across this view. Use on hero panels, primary buttons, logos.
    func holoSheen(angle: Double = 18) -> some View { modifier(HoloSheen(angle: angle)) }
}

// MARK: - 4. FoilText  (metallic / holographic headline text)
struct FoilText: View {
    let text: String
    var size: CGFloat = 30
    var weight: Font.Weight = .semibold
    var serif: Bool = true
    init(_ text: String, size: CGFloat = 30, weight: Font.Weight = .semibold, serif: Bool = true) {
        self.text = text; self.size = size; self.weight = weight; self.serif = serif
    }
    @Environment(\.blMotion) private var motion
    @Environment(\.holoTheme) private var theme
    private var font: Font { serif ? BLFont.display(size, weight) : BLFont.body(size, weight) }
    var body: some View {
        let fx = theme.fxScale
        let live = motion && theme.motion.speed > 0 && fx > 0
        let stops = [theme.accentHi, theme.accent, theme.iridescent, theme.accentHi, theme.accent]
        Text(text)
            .font(font)
            .foregroundStyle(LinearGradient(colors: [theme.accentHi, theme.accent, theme.accentDim], startPoint: .top, endPoint: .bottom))
            .overlay(
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !live)) { tl in
                    let phase = live ? -1 + 2 * FXClock.pingPong(tl.date, 16 / max(0.4, theme.motion.speed)) : 0
                    GeometryReader { geo in
                        LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 2.2)
                            .offset(x: phase * geo.size.width * 1.2)
                            .opacity(fx)
                    }
                    .mask(Text(text).font(font))
                }
                .blendMode(.screen)
                .allowsHitTesting(false)   // decorative foil sweep must never swallow clicks on a heading
            )
            // LEGIBILITY: only a TIGHT, bounded glow on display headings (<= 6) so edges stay sharp.
            // (Was a soft radius-12 glow that fuzzed even the headline; owner feedback "clear as shit".)
            .shadow(color: theme.accent.opacity(0.22 * theme.glowStrength), radius: theme.headingGlowRadius)
            .accessibilityLabel(text)
    }
}

// MARK: - 5. ParticleField  (drifting gold motes, Canvas, capped, parallax to pointer)
struct ParticleField: View {
    @Environment(\.holoTheme) private var theme
    @Environment(\.blMotion) private var motion
    private struct Mote { var x, y, r, vx, vy, phase: CGFloat }
    private var motes: [Mote] {
        let n = theme.particleCount
        guard n > 0 else { return [] }
        return (0..<n).map { i in
            var g = HoloRNG(seed: UInt64(i) &* 0x100000001B3)
            return Mote(x: g.next01(), y: g.next01(), r: 0.6 + g.next01() * 2.2,
                        vx: (g.next01() - 0.5) * 0.6, vy: -0.2 - g.next01() * 0.5, phase: g.next01())
        }
    }
    var body: some View {
        let speed = theme.motion.speed == 0 || !motion ? 0.0 : theme.motion.speed
        let list = motes
        // FOOLPROOF: ParticleField is a `Canvas`, which is hit-testable BY DEFAULT. As a decorative
        // overlay it must NEVER eat clicks. We disable hit-testing on the ENTIRE struct body (both the
        // empty and the populated branch) so it can never intercept a tap regardless of placement.
        Group {
            if list.isEmpty {
                Color.clear
            } else {
                TimelineView(.animation(paused: speed == 0)) { tl in
                    let t = speed == 0 ? 0 : tl.date.timeIntervalSinceReferenceDate * speed
                    Canvas { ctx, size in
                        for m in list {
                            let driftY = (m.y - CGFloat(t * 0.02) * abs(m.vy)).truncatingRemainder(dividingBy: 1.0)
                            let y = driftY < 0 ? driftY + 1 : driftY
                            let x = (m.x + CGFloat(sin(t * 0.3 + m.phase * 6.28)) * 0.01 * m.vx)
                            let tw = 0.35 + 0.65 * abs(sin(t * 0.8 + m.phase * 6.28))
                            let rect = CGRect(x: x * size.width, y: y * size.height, width: m.r * 2, height: m.r * 2)
                            ctx.fill(Path(ellipseIn: rect), with: .color(theme.accentHi.opacity(0.5 * tw * theme.fxScale)))
                        }
                    }
                    .drawingGroup()
                }
            }
        }
        // Baked in at the struct boundary — a decorative motes layer can never block a button.
        // (The previous pointer-parallax `.onContinuousHover` is intentionally removed: hover tracking
        // on a non-hit-testing view is a no-op, and we never want this layer to consume pointer events.)
        .allowsHitTesting(false)
    }
}

// MARK: - 6. AnimatedCounter  (numbers roll/transition on change)
struct AnimatedCounter: View {
    let value: Double
    var format: (Double) -> String = { String(Int($0)) }
    var font: Font = .system(size: 28, weight: .heavy, design: .rounded)
    var color: Color? = nil
    @Environment(\.blMotion) private var motion
    init(_ value: Double, format: @escaping (Double) -> String = { String(Int($0)) },
         font: Font = .system(size: 28, weight: .heavy, design: .rounded), color: Color? = nil) {
        self.value = value; self.format = format; self.font = font; self.color = color
    }
    var body: some View {
        let base = Text(format(value)).font(font).monospacedDigit()
        Group {
            if #available(macOS 14.0, *) {
                base.contentTransition(.numericText(value: value))
            } else {
                base.contentTransition(.numericText())   // macOS 13: rolls on any change
            }
        }
        .foregroundColor(color)
        .animation(motion ? .spring(response: 0.5, dampingFraction: 0.85) : nil, value: value)
    }
}

// MARK: - 7. IridescentBorder / GlowPulse  (CTA + selected-state rim-light)
struct IridescentBorder: ViewModifier {
    var radius: CGFloat = 12
    var lineWidth: CGFloat = 1.4
    var active: Bool = true
    @Environment(\.blMotion) private var motion
    @Environment(\.holoTheme) private var theme
    func body(content: Content) -> some View {
        let fx = theme.fxScale
        let live = motion && theme.motion.speed > 0 && active && fx > 0
        content.overlay(
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !live)) { tl in
                let phase = live ? FXClock.loop(tl.date, 6 / max(0.4, theme.motion.speed)) : 0
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(active && fx > 0
                        ? AnyShapeStyle(AngularGradient(colors: theme.spectrum, center: .center, angle: .degrees(phase * 360)))
                        : AnyShapeStyle(theme.accent.opacity(active ? 0.5 : 0.0)), lineWidth: lineWidth)
            }
            .allowsHitTesting(false)   // decorative rim — must never block the CTA it decorates
        )
    }
}
extension View { func iridescentBorder(radius: CGFloat = 12, lineWidth: CGFloat = 1.4, active: Bool = true) -> some View { modifier(IridescentBorder(radius: radius, lineWidth: lineWidth, active: active)) } }

struct GlowPulse: ViewModifier {
    var color: Color? = nil
    @Environment(\.blMotion) private var motion
    @Environment(\.holoTheme) private var theme
    func body(content: Content) -> some View {
        let c = color ?? theme.accent
        let live = motion && theme.motion.speed > 0
        // Glow breathes at 12fps — the shadow wraps the content, so the timeline is capped low
        // to keep the per-tick re-render cheap; a 2.4s soft pulse is smooth well below 30fps.
        TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: !live)) { tl in
            let k = live ? FXClock.easeInOut(FXClock.pingPong(tl.date, 2.4 / max(0.4, theme.motion.speed))) : 0
            content.shadow(color: c.opacity((0.25 + 0.30 * k) * theme.glowStrength), radius: 10 + 8 * k)
        }
    }
}
extension View { func glowPulse(_ color: Color? = nil) -> some View { modifier(GlowPulse(color: color)) } }

// MARK: - 8. HoloShimmerSkeleton  (loading state = moving holographic gradient)
struct HoloShimmerSkeleton: View {
    var width: CGFloat? = nil
    var height: CGFloat = 14
    var radius: CGFloat = 7
    @Environment(\.blMotion) private var motion
    @Environment(\.holoTheme) private var theme
    var body: some View {
        let live = motion && theme.motion.speed > 0
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(BL.bg2v)
            .frame(width: width, height: height)
            .overlay {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !live)) { tl in
                    let x = live ? -1 + 3 * FXClock.loop(tl.date, 1.4 / max(0.4, theme.motion.speed)) : 0.2
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, theme.accent.opacity(0.28), theme.accentHi.opacity(0.4), theme.accent.opacity(0.28), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.6)
                            .offset(x: x * geo.size.width * 1.6)
                            .blendMode(.screen)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                }
            }
    }
}

// Convenience: a stack of shimmer rows for list loading states.
struct HoloSkeletonRows: View {
    var rows: Int = 5
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<rows, id: \.self) { i in
                HStack(spacing: 12) {
                    HoloShimmerSkeleton(width: 34, height: 34, radius: 9)
                    VStack(alignment: .leading, spacing: 6) {
                        HoloShimmerSkeleton(width: 160 - CGFloat(i % 3) * 28, height: 11)
                        HoloShimmerSkeleton(width: 230 - CGFloat(i % 4) * 30, height: 9)
                    }
                    Spacer()
                    HoloShimmerSkeleton(width: 56, height: 22, radius: 7)
                }
            }
        }
    }
}

// MARK: - 9. ParallaxLayer  (depth: layers move at different rates on pointer)
struct ParallaxLayer<Content: View>: View {
    var depth: CGFloat = 12      // px of travel at the edges
    @ViewBuilder var content: () -> Content
    @Environment(\.blMotion) private var motion
    @State private var off: CGSize = .zero
    var body: some View {
        content()
            .offset(off)
            .onContinuousHover { ph in
                guard motion else { return }
                if case .active(let pt) = ph {
                    withAnimation(.easeOut(duration: 0.35)) {
                        off = CGSize(width: (pt.x.truncatingRemainder(dividingBy: 600)/600 - 0.5) * depth,
                                     height: (pt.y.truncatingRemainder(dividingBy: 600)/600 - 0.5) * depth)
                    }
                } else { withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { off = .zero } }
            }
    }
}

// MARK: - Premium asymmetric screen transition (slide + crossfade) used app-wide.
// NO blur on content during the transition — text/cards never go soft. Slide + opacity only.
extension AnyTransition {
    static var holoScreen: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity))
    }
}
