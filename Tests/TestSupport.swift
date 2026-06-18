// Headless test-only stand-ins for the few UI types the pure-logic engines reference.
// In the real app, TradeDirection lives in Model.swift (with a SwiftUI Color). The engines
// only use its .long/.short cases + equality, so this minimal mirror lets the math compile
// and be tested WITHOUT pulling in SwiftUI/AppKit. The app build never sees this file.
import Foundation

enum TradeDirection: String, Codable, CaseIterable, Identifiable {
    case long, short
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var icon: String { self == .long ? "arrow.up.right" : "arrow.down.right" }
}
