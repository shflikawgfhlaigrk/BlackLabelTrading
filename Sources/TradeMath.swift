// TradeMath.swift — pure number/format helpers (NO SwiftUI), shared by the app + test target.
import Foundation

enum TradeMath {
    /// Position sizing from account, risk%, entry and stop.
    static func positionSize(account: Double, riskPct: Double, entry: Double, stop: Double)
        -> (riskDollars: Double, perUnitRisk: Double, size: Double, notional: Double) {
        let riskDollars = account * riskPct / 100
        let perUnit = abs(entry - stop)
        let size = perUnit > 0 ? (riskDollars / perUnit) : 0
        let notional = size * entry
        return (riskDollars, perUnit, size, notional)
    }
    /// Reward:risk ratio + R for a given entry/stop/target.
    static func riskReward(entry: Double, stop: Double, target: Double) -> (risk: Double, reward: Double, ratio: Double) {
        let risk = abs(entry - stop)
        let reward = abs(target - entry)
        return (risk, reward, risk > 0 ? reward / risk : 0)
    }
    /// Compounding projector: balance after `months` of monthly growth `pct`.
    static func compound(start: Double, monthlyPct: Double, months: Int) -> [Double] {
        var out: [Double] = []
        var bal = start
        let r = monthlyPct / 100
        for _ in 0..<max(0, months) { bal *= (1 + r); out.append(bal) }
        return out
    }
    static func money(_ v: Double) -> String {
        let f = NumberFormatter(); f.numberStyle = .currency; f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? "$0"
    }
    static func money2(_ v: Double) -> String {
        let f = NumberFormatter(); f.numberStyle = .currency; f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: v)) ?? "$0"
    }
    static func pct(_ v: Double) -> String { String(format: "%.1f%%", v) }
    static func num(_ v: Double) -> String {
        if v.isInfinite { return "∞" }
        return String(format: "%.2f", v)
    }
    // Trim trailing zeros for text-field display.
    static func numTrim(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
    // Compact magnitude (1.2K / 3.4M) for axis labels like volume.
    static func compact(_ v: Double) -> String {
        let a = abs(v)
        if a >= 1_000_000_000 { return String(format: "%.1fB", v / 1_000_000_000) }
        if a >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if a >= 1_000 { return String(format: "%.1fK", v / 1_000) }
        return numTrim(v)
    }
}
