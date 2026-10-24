// Black Label Trading — HoloTheme model + persistence (PURE, headless-testable).
// ───────────────────────────────────────────────────────────────────────────────
// This file is deliberately free of SwiftUI/AppKit so the theme math + Codable round-trip
// can be verified in the headless test harness. The SwiftUI Color conveniences and the whole
// FX kit live in Holographic.swift. Everything here is PURELY VISUAL config — no data, no
// fabricated values. A buyer's Theme/Appearance Studio choices persist here and re-skin the app.
import Foundation

// MARK: - Holo enums (intensity / motion / background)

/// Holographic intensity — scales border iridescence, sheen and glow strength.
enum HoloIntensity: String, Codable, CaseIterable, Identifiable {
    case off, subtle, balanced, full
    var id: String { rawValue }
    var label: String { self == .off ? "Off" : rawValue.capitalized }
    /// 0 → no FX (flat premium), 1 → full holographic. Master multiplier.
    var scale: Double { switch self { case .off: return 0; case .subtle: return 0.45; case .balanced: return 0.75; case .full: return 1.0 } }
}

/// Motion level — scales drift speed / breathing / particle motion. Reduce Motion hard-overrides.
enum HoloMotion: String, Codable, CaseIterable, Identifiable {
    case off, calm, lively
    var id: String { rawValue }
    var label: String { self == .off ? "Off" : rawValue.capitalized }
    /// Speed multiplier (higher = faster). 0 disables continuous loops.
    var speed: Double { switch self { case .off: return 0; case .calm: return 0.7; case .lively: return 1.35 } }
}

/// Living background style.
enum HoloBackground: String, Codable, CaseIterable, Identifiable {
    case aurora, starfield, solid
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

// MARK: - HoloTheme  (the single persisted model every FX component reads)

/// The persisted holographic look. Every FX component reads this — no hardcoded intensities.
struct HoloTheme: Codable, Hashable {
    // Accent stored as hex so a custom color picker can round-trip (presets set these too).
    var accentHex: UInt32 = 0xD9B65C       // gold (this app's BLTheme.gold)
    var accentHiHex: UInt32 = 0xF0D488     // glint highlight (BLTheme.goldHi)
    var accentDimHex: UInt32 = 0xB8923A    // dim (BLTheme.goldDim)
    /// Secondary iridescent hue used in borders/sheens (cyan by default for the holo shimmer).
    var iridescentHex: UInt32 = 0x4FD7FF

    var intensity: HoloIntensity = .balanced
    var motion: HoloMotion = .calm
    var background: HoloBackground = .aurora

    var particleDensity: Double = 0.5      // 0 → off, 1 → max (capped to PARTICLE_CAP)
    var tiltEnabled: Bool = false          // cursor 3D tilt OFF by default — never soften text (opt-in via Theme Studio)
    var tiltStrength: Double = 0.6         // 0 → flat, 1 → strong 3D
    var glowStrength: Double = 0.6         // 0 → none, 1 → strong gold glow

    // Forgiving Codable: a settings blob saved before a field existed must still load — each key
    // falls back to the struct default rather than failing the whole decode. (An older save that
    // carried a now-removed `specularStrength` key is simply ignored on decode — specular is gone.)
    private enum CodingKeys: String, CodingKey {
        case accentHex, accentHiHex, accentDimHex, iridescentHex, intensity, motion, background
        case particleDensity, tiltEnabled, tiltStrength, glowStrength
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var t = HoloTheme()   // defaults; override only what's present
        t.accentHex        = try c.decodeIfPresent(UInt32.self, forKey: .accentHex)         ?? t.accentHex
        t.accentHiHex      = try c.decodeIfPresent(UInt32.self, forKey: .accentHiHex)       ?? t.accentHiHex
        t.accentDimHex     = try c.decodeIfPresent(UInt32.self, forKey: .accentDimHex)      ?? t.accentDimHex
        t.iridescentHex    = try c.decodeIfPresent(UInt32.self, forKey: .iridescentHex)     ?? t.iridescentHex
        t.intensity        = try c.decodeIfPresent(HoloIntensity.self, forKey: .intensity)  ?? t.intensity
        t.motion           = try c.decodeIfPresent(HoloMotion.self, forKey: .motion)        ?? t.motion
        t.background       = try c.decodeIfPresent(HoloBackground.self, forKey: .background) ?? t.background
        t.particleDensity  = try c.decodeIfPresent(Double.self, forKey: .particleDensity)   ?? t.particleDensity
        t.tiltEnabled      = try c.decodeIfPresent(Bool.self, forKey: .tiltEnabled)         ?? t.tiltEnabled
        t.tiltStrength     = try c.decodeIfPresent(Double.self, forKey: .tiltStrength)      ?? t.tiltStrength
        t.glowStrength     = try c.decodeIfPresent(Double.self, forKey: .glowStrength)      ?? t.glowStrength
        self = t
    }
    /// Memberwise-style init kept available since a custom init() suppresses the synthesized one.
    init(accentHex: UInt32 = 0xD9B65C, accentHiHex: UInt32 = 0xF0D488, accentDimHex: UInt32 = 0xB8923A,
         iridescentHex: UInt32 = 0x4FD7FF, intensity: HoloIntensity = .balanced, motion: HoloMotion = .calm,
         background: HoloBackground = .aurora, particleDensity: Double = 0.5, tiltEnabled: Bool = false,
         tiltStrength: Double = 0.6, glowStrength: Double = 0.6) {
        self.accentHex = accentHex; self.accentHiHex = accentHiHex; self.accentDimHex = accentDimHex
        self.iridescentHex = iridescentHex; self.intensity = intensity; self.motion = motion
        self.background = background; self.particleDensity = particleDensity; self.tiltEnabled = tiltEnabled
        self.tiltStrength = tiltStrength; self.glowStrength = glowStrength
    }

    /// Max particles this theme requests (capped). Off when intensity is off or density 0.
    var particleCount: Int {
        guard intensity != .off, particleDensity > 0 else { return 0 }
        return Int((particleDensity * Double(HoloTheme.PARTICLE_CAP)).rounded())
    }
    /// Effective FX strength after intensity scaling (0…1). 0 = flat fallback.
    var fxScale: Double { intensity.scale }

    // MARK: - Legibility ("clear as shit" — owner feedback)
    // These values encode the hard legibility contract so it can't silently regress:
    //   • Reading surfaces (cards/panels/fields that carry body text, labels, numbers) are ALWAYS
    //     fully opaque — independent of FX intensity — so the moving aurora never shows through
    //     behind text and fuzzes it. The FX kit composites a solid tint at this opacity UNDER the
    //     translucent glass, so the look stays premium while text reads on a high-contrast base.
    //   • Body / label / value / button text carries NO glow (zero radius) — soft shadows fuzz edges.
    //   • Only large display headings (FoilText) may carry a TIGHT glow, bounded small (<= 6) even at
    //     full intensity, so even headline edges stay sharp.

    /// Opacity of the SOLID tint composited behind any reading surface. Always 1.0 — text never
    /// sits directly over the aurora. (Decorative chrome can still be translucent; this is only the
    /// reading base.)
    var readingSurfaceOpacity: Double { 1.0 }

    /// Glow radius permitted on body/label/value/button text. Always 0 — crisp solid text only.
    var bodyTextGlowRadius: Double { 0 }

    /// Glow radius permitted on large display headings (FoilText). Tight + bounded so edges stay
    /// sharp; scales gently with glow strength but is hard-capped at 6 regardless of intensity.
    var headingGlowRadius: Double { min(6.0, 3.0 + 3.0 * glowStrength) }
    /// Effective continuous-motion speed (0 = no loops). Caller still gates on \.blMotion.
    func motionSpeed(reduceMotion: Bool, toggleOn: Bool) -> Double {
        (reduceMotion || !toggleOn) ? 0 : motion.speed
    }

    static let PARTICLE_CAP = 56           // hard ceiling for ParticleField

    // MARK: Presets — one-click named looks.
    // All presets ship with cursor 3D tilt OFF — text must never soften under perspective. Tilt is
    // opt-in per buyer via the Theme Studio toggle (which carries tiltStrength for when they enable it).
    static let goldVault = HoloTheme(accentHex: 0xD9B65C, accentHiHex: 0xF0D488, accentDimHex: 0xB8923A,
                                     iridescentHex: 0x4FD7FF, intensity: .balanced, motion: .calm,
                                     background: .aurora, particleDensity: 0.5, tiltEnabled: false,
                                     tiltStrength: 0.6, glowStrength: 0.6)
    static let platinum = HoloTheme(accentHex: 0xD8DBE0, accentHiHex: 0xFFFFFF, accentDimHex: 0x9AA0A8,
                                    iridescentHex: 0xBFD4FF, intensity: .subtle, motion: .calm,
                                    background: .aurora, particleDensity: 0.35, tiltEnabled: false,
                                    tiltStrength: 0.45, glowStrength: 0.4)
    static let aurora = HoloTheme(accentHex: 0x7DE2C3, accentHiHex: 0xBFF7E6, accentDimHex: 0x3E9C86,
                                  iridescentHex: 0x9C7DFF, intensity: .full, motion: .lively,
                                  background: .aurora, particleDensity: 0.7, tiltEnabled: false,
                                  tiltStrength: 0.7, glowStrength: 0.75)
    static let cyberNeon = HoloTheme(accentHex: 0x4FD7FF, accentHiHex: 0xA6F0FF, accentDimHex: 0x2E9BBF,
                                     iridescentHex: 0xFF5FE1, intensity: .full, motion: .lively,
                                     background: .starfield, particleDensity: 0.85, tiltEnabled: false,
                                     tiltStrength: 0.85, glowStrength: 0.9)
    static let midnight = HoloTheme(accentHex: 0x6F86FF, accentHiHex: 0xAFC0FF, accentDimHex: 0x44529E,
                                    iridescentHex: 0x9C7DFF, intensity: .subtle, motion: .calm,
                                    background: .solid, particleDensity: 0.2, tiltEnabled: false,
                                    tiltStrength: 0.4, glowStrength: 0.35)

    /// Named presets exposed in the Theme Studio (display name → theme).
    static let presets: [(name: String, theme: HoloTheme)] = [
        ("Gold Vault", .goldVault), ("Platinum", .platinum), ("Aurora", .aurora),
        ("Cyber Neon", .cyberNeon), ("Midnight", .midnight),
    ]

    /// Name of the built-in preset that exactly matches this theme, if any (for Studio highlighting).
    var matchingPresetName: String? { HoloTheme.presets.first(where: { $0.theme == self })?.name }
}

// A user-saved custom holographic look (lives alongside the built-in presets).
struct HoloPreset: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = "My Look"
    var theme: HoloTheme = .goldVault
}

// MARK: - Persistence  (UserDefaults-backed; on-device only, ships no data)
// Mirrors the app's existing AppSettingsStore pattern. The live theme + the motion toggle + the
// user's saved custom presets all persist here so the buyer owns the look across launches.
enum HoloThemeStore {
    static let themeKey   = "com.blacklabel.trading.holoTheme"
    static let motionKey  = "com.blacklabel.trading.motionEnabled"
    static let presetsKey = "com.blacklabel.trading.holoPresets"

    private static let defaults: UserDefaults = .standard

    /// Load the persisted live theme, or the Gold Vault default. Forgiving — a corrupt blob
    /// falls back to default rather than crashing.
    static func loadTheme() -> HoloTheme {
        guard let data = defaults.data(forKey: themeKey),
              let t = try? JSONDecoder().decode(HoloTheme.self, from: data) else { return .goldVault }
        return t
    }
    static func saveTheme(_ t: HoloTheme) {
        if let data = try? JSONEncoder().encode(t) { defaults.set(data, forKey: themeKey) }
    }

    /// The in-app Motion toggle (independent of system Reduce Motion, which hard-overrides).
    /// Default OFF for new profiles (founder directive 2026-07-08) — the buyer opts in via Theme Studio.
    static var motionEnabled: Bool {
        get { defaults.object(forKey: motionKey) == nil ? false : defaults.bool(forKey: motionKey) }
        set { defaults.set(newValue, forKey: motionKey) }
    }

    /// The buyer's saved custom presets.
    static func loadPresets() -> [HoloPreset] {
        guard let data = defaults.data(forKey: presetsKey),
              let p = try? JSONDecoder().decode([HoloPreset].self, from: data) else { return [] }
        return p
    }
    static func savePresets(_ p: [HoloPreset]) {
        if let data = try? JSONEncoder().encode(p) { defaults.set(data, forKey: presetsKey) }
    }
}
