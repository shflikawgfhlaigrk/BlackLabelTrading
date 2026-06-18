// Black Label Trading — theme + reusable UI.
import SwiftUI
import AppKit

enum BLTheme {
    static let bg     = Color(hex: 0x0B0B0D)
    static let bg2    = Color(hex: 0x08080A)
    static let panel  = Color(hex: 0x141416)
    static let panel2 = Color(hex: 0x18181B)
    static let gold   = Color(hex: 0xD9B65C)
    static let goldHi = Color(hex: 0xF0D488)
    static let goldDim = Color(hex: 0xB8923A)
    static let line   = Color(hex: 0x2A2616)
    static let stroke = Color(hex: 0x26262B)
    static let text   = Color(hex: 0xEDEDED)
    static let sub    = Color(hex: 0x8C8C8C)
    static let green  = Color(hex: 0x6FD08C)
    static let red    = Color(hex: 0xFF6B6B)
    static let blue   = Color(hex: 0x6FA8FF)

    static var goldGrad: LinearGradient { LinearGradient(colors: [goldHi, gold, goldDim], startPoint: .topLeading, endPoint: .bottomTrailing) }
    static var panelGrad: LinearGradient { LinearGradient(colors: [panel2, panel], startPoint: .top, endPoint: .bottom) }
    static func hairline(_ tint: Color = gold) -> LinearGradient { LinearGradient(colors: [tint.opacity(0.32), stroke.opacity(0.6)], startPoint: .top, endPoint: .bottom) }
    static func icon() -> NSImage? { Bundle.main.resourcePath.flatMap { NSImage(contentsOfFile: $0 + "/AppIcon.icns") } ?? NSImage(named: "AppIcon") }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF)/255, green: Double((hex >> 8) & 0xFF)/255, blue: Double(hex & 0xFF)/255, opacity: 1)
    }
}

struct Logo: View {
    var size: CGFloat = 64
    var body: some View {
        Group {
            if let img = BLTheme.icon() { Image(nsImage: img).resizable().interpolation(.high) }
            else { Text("BLT").font(.system(size: size*0.34, weight: .black, design: .rounded)).foregroundStyle(BLTheme.goldGrad) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size*0.22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size*0.22, style: .continuous).stroke(BLTheme.gold.opacity(0.25), lineWidth: 1))
        .shadow(color: BLTheme.gold.opacity(0.35), radius: size*0.2, y: 4)
    }
}

struct Field: View {
    let title: String
    @Binding var text: String
    var prompt = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.6)
            TextField(prompt.isEmpty ? title : prompt, text: $text)
                .textFieldStyle(.plain).font(.system(size: 14, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                .focused($focused)
                .padding(.vertical, 10).padding(.horizontal, 12)
                .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? BLTheme.gold.opacity(0.7) : BLTheme.stroke, lineWidth: focused ? 1.5 : 1))
                .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}

struct GoldButton: View {
    let label: String; var fill = false; var icon = ""; let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if !icon.isEmpty { Image(systemName: icon) }
                Text(label)
            }
            .font(.system(size: 13.5, weight: .bold, design: .rounded)).foregroundColor(Color(hex: 0x1A1305))
            .padding(.vertical, 11).padding(.horizontal, 18).frame(maxWidth: fill ? .infinity : nil)
            .background(BLTheme.goldGrad).clipShape(Capsule())
            .holoSheen()                                   // moving iridescent light sweep on the primary CTA
            .overlay(Capsule().stroke(Color.white.opacity(hover ? 0.25 : 0.12), lineWidth: 1))
            .shadow(color: BLTheme.gold.opacity(hover ? 0.55 : 0.28), radius: hover ? 16 : 8, y: 3)
        }
        .buttonStyle(.plain).onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { hover = h } }
    }
}

// Subtle outline/ghost button for secondary actions.
struct GhostButton: View {
    let label: String; var icon = ""; var tint: Color = BLTheme.text; let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { if !icon.isEmpty { Image(systemName: icon) }; Text(label) }
                .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(tint)
                .padding(.vertical, 9).padding(.horizontal, 16)
                .background(hover ? tint.opacity(0.12) : BLTheme.bg2).clipShape(Capsule())
                .overlay(Capsule().stroke(tint.opacity(hover ? 0.5 : 0.25), lineWidth: 1))
        }
        .buttonStyle(.plain).onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

// Always-visible close affordance for modal sheets. Prepends a top bar with a clear "✕ Close" pill
// (Esc-bound) so a presented editor/detail NEVER looks like a dead-end — the Save/Cancel pair often
// sits at the BOTTOM of long scrolling forms, which reads as "no back button". A prepended bar (not
// an overlay) never collides with top-right header content.
struct SheetCloseBar: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        Text("Close").font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(BLTheme.text)
                    .padding(.vertical, 6).padding(.horizontal, 11)
                    .background(BLTheme.bg2, in: Capsule())
                    .overlay(Capsule().stroke(BLTheme.gold.opacity(0.45), lineWidth: 1))
                }
                .buttonStyle(.plain).help("Close (Esc)").keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 2)
            content
        }
        .background(BLTheme.bg)
    }
}
extension View {
    /// Adds an always-visible top-right "Close" button (Esc-bound) above a sheet's content.
    func sheetCloseBar() -> some View { modifier(SheetCloseBar()) }
}

struct Panel<Content: View>: View {
    let title: String; var icon = "square.grid.2x2"; var accent: Color = BLTheme.gold; @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundColor(Color(hex: 0x1A1305))
                    .frame(width: 26, height: 26).background(BLTheme.goldGrad).clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(color: BLTheme.gold.opacity(0.3), radius: 5, y: 1)
                Text(title).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
            }
            content()
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        // Signature holographic surface — iridescent animated border + glow + pointer 3D tilt.
        .holoCard(radius: 18)
    }
}

struct Stat: View {
    let label: String; let value: String; var big = false; var tint: Color = BLTheme.text
    var body: some View {
        HStack { Text(label).font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
            Spacer()
            Text(value).font(.system(size: big ? 19 : 14, weight: big ? .heavy : .bold, design: .rounded)).foregroundColor(big ? BLTheme.gold : tint) }
    }
}

struct StatusPill: View {
    let text: String; let tint: Color
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundColor(tint).tracking(0.4)
            .padding(.vertical, 3.5).padding(.horizontal, 9)
            .background(tint.opacity(0.15)).clipShape(Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.45), lineWidth: 1))
    }
}

// Premium hero stat card with icon badge + soft glow.
struct MetricCard: View {
    let label: String; let value: String; let icon: String; var tint: Color = BLTheme.text
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).font(.system(size: 14, weight: .bold)).foregroundColor(Color(hex: 0x1A1305))
                .frame(width: 32, height: 32).background(BLTheme.goldGrad).clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: BLTheme.gold.opacity(0.35), radius: 6, y: 2)
            Text(value).font(.system(size: 27, weight: .heavy, design: .rounded)).foregroundColor(tint).contentTransition(.numericText())
            Text(label.uppercased()).font(.system(size: 10.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.6)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        // Holographic stat card (border iridescence + glow + pointer tilt come from the kit).
        .holoCard(radius: 16)
    }
}

// Screen title with subtitle + accent underline for consistent hierarchy.
struct ScreenTitle: View {
    let title: String; var subtitle = ""; var icon = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if !icon.isEmpty {
                    Image(systemName: icon).font(.system(size: 15, weight: .bold)).foregroundColor(Color(hex: 0x1A1305))
                        .frame(width: 30, height: 30).background(BLTheme.goldGrad).clipShape(RoundedRectangle(cornerRadius: 9))
                        .shadow(color: BLTheme.gold.opacity(0.3), radius: 5, y: 1)
                }
                Text(title).font(.system(size: 25, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
            }
            if !subtitle.isEmpty {
                Text(subtitle).font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
            }
            Capsule().fill(BLTheme.goldGrad).frame(width: 46, height: 3).opacity(0.85)
        }
    }
}

// Intentional empty-state: icon badge + title + hint.
struct EmptyState: View {
    let icon: String; let title: String; var hint = ""
    var body: some View {
        VStack(spacing: 12) {
            // Glowing iconographic centerpiece — holographic empty state, never a flat message.
            Image(systemName: icon).font(.system(size: 30, weight: .semibold)).foregroundColor(Color(hex: 0x1A1305))
                .frame(width: 64, height: 64).background(BLTheme.goldGrad.opacity(0.85)).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .holoSheen()
                .glowPulse()
            Text(title).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
            if !hint.isEmpty {
                Text(hint).font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    .multilineTextAlignment(.center).frame(maxWidth: 280)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }
}

// Labeled slider with live value, used by the signal factor controls.
struct FactorSlider: View {
    let label: String; @Binding var value: Double; var range: ClosedRange<Double> = -1...1; var fmt: (Double) -> String = { String(format: "%+.2f", $0) }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                Spacer()
                Text(fmt(value)).font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.gold).monospacedDigit()
            }
            Slider(value: $value, in: range).tint(BLTheme.gold).controlSize(.small)
        }
    }
}
