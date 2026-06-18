// Black Label Trading — THEME / APPEARANCE STUDIO
// ───────────────────────────────────────────────────────────────────────────────
// The buyer's control surface for the holographic look. A live-preview pane sits beside the
// controls; every change mutates the HoloThemeController's `theme`, which re-skins the WHOLE app
// instantly (the controller persists to HoloThemeStore). Purely visual — no data, no fabricated
// values. NO cursor-specular control (specular is removed per owner feedback).
import SwiftUI

struct ThemeStudioPanel: View {
    @EnvironmentObject var holo: HoloThemeController
    @State private var saveName = ""
    @State private var showSave = false

    // Bindings into the live theme (mutating any of these re-skins the app + persists).
    private var t: Binding<HoloTheme> { $holo.theme }

    var body: some View {
        Panel(title: "Theme · Appearance Studio", icon: "paintpalette.fill", accent: holo.theme.accent) {
            Text("Own the look. Every control below re-skins the entire app instantly and is saved on this Mac. Reduce Motion (System Settings) always hard-overrides motion to a safe, still-premium fallback.")
                .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)

            // ── Live preview + controls, side by side on wide layouts ──
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    controls.frame(maxWidth: 360)
                    livePreview.frame(width: 300)
                }
                VStack(alignment: .leading, spacing: 18) {
                    livePreview.frame(maxWidth: .infinity)
                    controls
                }
            }
        }
    }

    // MARK: Live preview pane — a self-contained holographic showcase using the live theme.
    private var livePreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LIVE PREVIEW").font(.system(size: 9.5, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.sub).tracking(1.2)
            ZStack {
                AuroraBackdrop()
                ParticleField()
                VStack(spacing: 14) {
                    FoilText("Black Label", size: 22, weight: .heavy, serif: false)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            // Neutral sample number — shows the foil/counter effect, NOT a performance metric.
                            Text("Sample metric").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                            Spacer()
                            AnimatedCounter(previewSampleValue, format: { String(format: "%.0f", $0) },
                                            font: .system(size: 18, weight: .heavy, design: .rounded), color: holo.theme.accent)
                        }
                        HoloShimmerSkeleton(height: 9)
                        HoloShimmerSkeleton(width: 140, height: 9)
                    }
                    .padding(14).frame(maxWidth: .infinity)
                    .holoCard(radius: 14)

                    Text("Sample CTA").font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(Color(hex: 0x1A1305))
                        .padding(.vertical, 9).padding(.horizontal, 18)
                        .background(BLTheme.goldGrad).clipShape(Capsule())
                        .holoSheen().glowPulse()
                }
                .padding(18)
            }
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
        }
        // Re-render the preview when any theme field changes so it tracks edits live.
        .id(holo.theme)
    }
    // A neutral preview number that tracks the glow slider so the AnimatedCounter visibly rolls
    // while tuning — purely a visual sample, never a real metric and never tied to any symbol.
    private var previewSampleValue: Double { (1000 + holo.theme.glowStrength * 240).rounded() }

    // MARK: Controls
    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            presetRow
            Divider().background(BLTheme.stroke)

            // Accent color
            VStack(alignment: .leading, spacing: 8) {
                label("Accent color")
                HStack(spacing: 8) {
                    ForEach(accentSwatches, id: \.self) { hex in
                        Circle().fill(Color(hex: hex)).frame(width: 24, height: 24)
                            .overlay(Circle().stroke(Color.white.opacity(holo.theme.accentHex == hex ? 0.9 : 0.18), lineWidth: holo.theme.accentHex == hex ? 2 : 1))
                            .onTapGesture { setAccent(hex) }
                    }
                    ColorPicker("", selection: customAccentBinding, supportsOpacity: false)
                        .labelsHidden().frame(width: 28)
                        .help("Custom accent color")
                }
            }

            // Secondary iridescent hue
            VStack(alignment: .leading, spacing: 8) {
                label("Iridescent hue")
                HStack(spacing: 8) {
                    ForEach(iridescentSwatches, id: \.self) { hex in
                        Circle().fill(Color(hex: hex)).frame(width: 20, height: 20)
                            .overlay(Circle().stroke(Color.white.opacity(holo.theme.iridescentHex == hex ? 0.9 : 0.18), lineWidth: holo.theme.iridescentHex == hex ? 2 : 1))
                            .onTapGesture { t.wrappedValue.iridescentHex = hex }
                    }
                    ColorPicker("", selection: customIridescentBinding, supportsOpacity: false)
                        .labelsHidden().frame(width: 24)
                }
            }

            // Holo intensity
            segmented("Holo intensity", HoloIntensity.allCases.map { ($0.label, $0) }, selection: t.intensity)
            // Motion level
            segmented("Motion level", HoloMotion.allCases.map { ($0.label, $0) }, selection: t.motion)
            // Background style
            segmented("Background", HoloBackground.allCases.map { ($0.label, $0) }, selection: t.background)

            // In-app motion toggle (independent of the level; Reduce Motion still hard-overrides).
            Toggle(isOn: $holo.motionEnabled) {
                Text("Animations enabled").font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
            }.toggleStyle(.switch).tint(holo.theme.accent)

            // Particle density
            slider("Particle density", value: t.particleDensity, range: 0...1, fmt: pctOrOff)
            // Glow strength
            slider("Glow strength", value: t.glowStrength, range: 0...1, fmt: { String(format: "%.0f%%", $0 * 100) })

            // Card tilt
            Toggle(isOn: t.tiltEnabled) {
                Text("Card 3D tilt").font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
            }.toggleStyle(.switch).tint(holo.theme.accent)
            if holo.theme.tiltEnabled {
                slider("Tilt strength", value: t.tiltStrength, range: 0...1, fmt: { String(format: "%.0f%%", $0 * 100) })
            }

            Divider().background(BLTheme.stroke)
            customPresetRow
            HStack(spacing: 8) {
                GhostButton(label: "Reset to Gold Vault", icon: "arrow.counterclockwise") { holo.resetToDefault() }
            }
        }
    }

    // MARK: Preset chips (built-in)
    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("Presets")
            FlowChips(items: HoloTheme.presets.map { $0.name }) { name in
                let isOn = holo.theme.matchingPresetName == name
                Button { if let p = HoloTheme.presets.first(where: { $0.name == name }) { holo.apply(p.theme) } } label: {
                    Text(name).font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(isOn ? Color(hex: 0x1A1305) : BLTheme.text)
                        .padding(.vertical, 7).padding(.horizontal, 13)
                        .background(isOn ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(isOn ? Color.clear : BLTheme.stroke, lineWidth: 1))
                }.buttonStyle(.plain)
            }
        }
    }

    // MARK: Custom (user-saved) presets
    private var customPresetRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                label("My presets")
                Spacer()
                GhostButton(label: "Save current", icon: "plus") { showSave = true; saveName = "" }
            }
            if showSave {
                HStack(spacing: 8) {
                    Field(title: "Preset name", text: $saveName, prompt: "e.g. My Desk")
                    GoldButton(label: "Save", icon: "checkmark") {
                        holo.saveCurrentAsPreset(named: saveName); showSave = false
                    }
                    GhostButton(label: "Cancel", icon: "xmark", tint: BLTheme.sub) { showSave = false }
                }
            }
            if holo.customPresets.isEmpty {
                Text("No saved looks yet — tune the controls, then Save current.")
                    .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub)
            } else {
                FlowChips(items: holo.customPresets.map { $0.name }) { name in
                    if let p = holo.customPresets.first(where: { $0.name == name }) {
                        HStack(spacing: 4) {
                            Button { holo.apply(p.theme) } label: {
                                Text(name).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                            }.buttonStyle(.plain)
                            Button { holo.deletePreset(p) } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundColor(BLTheme.sub)
                            }.buttonStyle(.plain).help("Delete preset")
                        }
                        .padding(.vertical, 7).padding(.horizontal, 11)
                        .background(BLTheme.bg2).clipShape(Capsule())
                        .overlay(Capsule().stroke(BLTheme.stroke, lineWidth: 1))
                    }
                }
            }
        }
    }

    // MARK: building blocks
    private func label(_ s: String) -> some View {
        Text(s.uppercased()).font(.system(size: 9.5, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.sub).tracking(1.0)
    }
    private func segmented<T: Hashable>(_ title: String, _ opts: [(String, T)], selection: Binding<T>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            label(title)
            HStack(spacing: 4) {
                ForEach(opts, id: \.1) { (lab, val) in
                    let on = selection.wrappedValue == val
                    Button { withAnimation(.easeInOut(duration: 0.25)) { selection.wrappedValue = val } } label: {
                        Text(lab).font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(on ? Color(hex: 0x1A1305) : BLTheme.sub)
                            .padding(.vertical, 6).frame(maxWidth: .infinity)
                            .background(on ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(Color.clear)).clipShape(Capsule())
                    }.buttonStyle(.plain)
                }
            }
            .padding(3).background(BLTheme.bg2).clipShape(Capsule()).overlay(Capsule().stroke(BLTheme.stroke, lineWidth: 1))
        }
    }
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, fmt: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                label(title)
                Spacer()
                Text(fmt(value.wrappedValue)).font(.system(size: 11.5, weight: .bold, design: .rounded)).foregroundColor(holo.theme.accent).monospacedDigit()
            }
            Slider(value: value, in: range).tint(holo.theme.accent).controlSize(.small)
        }
    }
    private func pctOrOff(_ v: Double) -> String { v <= 0.001 ? "Off" : String(format: "%.0f%%", v * 100) }

    // MARK: accent helpers
    private let accentSwatches: [UInt32] = [0xD9B65C, 0xD8DBE0, 0x7DE2C3, 0x4FD7FF, 0x6F86FF, 0xFF6B6B, 0xB07DFF, 0x6FD08C]
    private let iridescentSwatches: [UInt32] = [0x4FD7FF, 0x9C7DFF, 0xFF5FE1, 0xBFD4FF, 0x7DE2C3]
    private func setAccent(_ hex: UInt32) {
        // Derive a highlight + dim from the chosen accent so the foil/border read correctly.
        t.wrappedValue.accentHex = hex
        t.wrappedValue.accentHiHex = lighten(hex, 0.35)
        t.wrappedValue.accentDimHex = darken(hex, 0.30)
    }
    private var customAccentBinding: Binding<Color> {
        Binding(get: { holo.theme.accent }, set: { setAccent($0.holoHex) })
    }
    private var customIridescentBinding: Binding<Color> {
        Binding(get: { holo.theme.iridescent }, set: { t.wrappedValue.iridescentHex = $0.holoHex })
    }
    private func lighten(_ hex: UInt32, _ amt: Double) -> UInt32 { mix(hex, target: 0xFFFFFF, amt) }
    private func darken(_ hex: UInt32, _ amt: Double) -> UInt32 { mix(hex, target: 0x000000, amt) }
    private func mix(_ hex: UInt32, target: UInt32, _ amt: Double) -> UInt32 {
        func ch(_ v: UInt32, _ s: Int) -> Double { Double((v >> s) & 0xFF) }
        let r = ch(hex,16) + (ch(target,16) - ch(hex,16)) * amt
        let g = ch(hex,8)  + (ch(target,8)  - ch(hex,8))  * amt
        let b = ch(hex,0)  + (ch(target,0)  - ch(hex,0))  * amt
        return (UInt32(r.rounded()) << 16) | (UInt32(g.rounded()) << 8) | UInt32(b.rounded())
    }
}

// A simple wrapping chip layout (no external deps).
struct FlowChips<Chip: View>: View {
    let items: [String]
    @ViewBuilder let chip: (String) -> Chip
    var body: some View {
        // For these small counts a wrapping HStack via a LazyVGrid of flexible columns reads clean.
        FlexibleWrap(items: items) { chip($0) }
    }
}

// Lightweight wrap layout using SwiftUI Layout (macOS 13+).
struct FlexibleWrap<Content: View>: View {
    let items: [String]
    @ViewBuilder let content: (String) -> Content
    var body: some View {
        WrapLayout(spacing: 8) {
            ForEach(items, id: \.self) { content($0) }
        }
    }
}

struct WrapLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxRowW: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height); maxRowW = max(maxRowW, x)
        }
        return CGSize(width: min(maxW, maxRowW), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxW = bounds.width
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x - bounds.minX + s.width > maxW, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}
