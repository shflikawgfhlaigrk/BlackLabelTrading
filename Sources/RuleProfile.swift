// Black Label Trading — prop-firm rule profiles (pure logic, no SwiftUI).
// ─────────────────────────────────────────────────────────────────────────────
// A RuleProfile is the buyer's OWN copy of a funded-evaluation firm's risk limits.
// The buyer edits every number freely. We NEVER ship invented firm limits: presets
// are blank firm-named templates (name + a "confirm on the firm's site" note, zero
// numbers, an empty source URL the buyer pastes) — §5.1. A profile only gates a
// displayed signal once the buyer has entered their own caps from the firm's terms.
//
// The gate is signals-only annotation: it tells the buyer whether the CURRENT trade
// plan, at a given contract size, would breach the caps THEY entered — and the most
// contracts that stay within every set limit. It never auto-trades, never asserts a
// win-rate or P&L, and an empty profile is honestly "no limits set".
import Foundation

struct RuleProfile: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    // All monetary/contract limits are the buyer's own entries. 0 == "not set" (no gate on that axis).
    var dailyLossLimit: Double = 0     // $ — max loss allowed in a day
    var trailingDrawdown: Double = 0   // $ — max trailing / end-of-day drawdown from peak
    var maxPositionSize: Double = 0    // contracts — hard account position cap
    var contractScaling: Double = 0    // contracts — scaling-plan cap at the buyer's current buffer level
    var pointValue: Double = 0         // $ per point per contract (buyer's instrument; 0 == unknown)
    var sourceURL: String = ""         // cited firm-terms URL the buyer confirmed the numbers against

    // A profile with no numeric caps set can't gate anything yet.
    var hasLimits: Bool {
        dailyLossLimit > 0 || trailingDrawdown > 0 || maxPositionSize > 0 || contractScaling > 0
    }
}

// The gate decision for one displayed signal under one profile. Pure and deterministic.
enum RuleProfileGate {
    enum Verdict: String, Equatable {
        case withinLimits   // signal at this size respects every set cap
        case breach         // signal at this size violates at least one set cap (HARD visual gate)
        case emptyProfile   // a profile is selected but has no caps entered yet
        case noProfile      // no profile selected
        case noSignal       // no computable signal (flat / no stop distance / unknown $/pt)
    }

    struct Decision: Equatable {
        var verdict: Verdict
        var reasons: [String]        // honest, specific breach reasons (empty unless .breach)
        var maxContracts: Int        // largest contract count within EVERY set limit (0 == even 1 breaches / no caps)
        var dollarRiskAtSize: Double // one-stop-out $ risk at the evaluated size
        var evaluatedContracts: Int  // the contract count this decision was computed for

        var isBreach: Bool { verdict == .breach }

        // Short buyer-facing annotation for a signal row. Never a performance claim.
        var annotation: String {
            switch verdict {
            case .noProfile:   return "No prop-firm profile selected"
            case .emptyProfile: return "Profile has no limits set — add your firm's caps"
            case .noSignal:    return "No sized signal to check"
            case .withinLimits:
                if maxContracts > 0 {
                    return "Within limits at \(evaluatedContracts) — max \(maxContracts) contract\(maxContracts == 1 ? "" : "s")"
                }
                return "Within limits at \(evaluatedContracts) contract\(evaluatedContracts == 1 ? "" : "s")"
            case .breach:
                let head = reasons.first ?? "breaches your profile"
                if maxContracts > 0 {
                    return "Breach: \(head) — max \(maxContracts) contract\(maxContracts == 1 ? "" : "s") within limits"
                }
                return "Breach: \(head) — 0 contracts fit these caps"
            }
        }
    }

    // Evaluate a signal (stop distance in points + $/pt/contract) at `contracts` size under `profile`.
    static func evaluate(riskPoints: Double, pointValue: Double, contracts: Int, profile: RuleProfile?) -> Decision {
        guard let p = profile else {
            return Decision(verdict: .noProfile, reasons: [], maxContracts: 0, dollarRiskAtSize: 0, evaluatedContracts: contracts)
        }
        if !p.hasLimits {
            return Decision(verdict: .emptyProfile, reasons: [], maxContracts: 0, dollarRiskAtSize: 0, evaluatedContracts: contracts)
        }
        // Prefer the profile's own $/pt (buyer's instrument); fall back to the signal's when unset.
        let ppt = p.pointValue > 0 ? p.pointValue : pointValue
        guard riskPoints > 0, ppt > 0, contracts > 0 else {
            return Decision(verdict: .noSignal, reasons: [], maxContracts: 0, dollarRiskAtSize: 0, evaluatedContracts: contracts)
        }
        let perContract = riskPoints * ppt
        let dollarAtSize = perContract * Double(contracts)
        var reasons: [String] = []

        // Position-count caps.
        if p.maxPositionSize > 0 && Double(contracts) > p.maxPositionSize {
            reasons.append("position \(contracts) > max position \(intCap(p.maxPositionSize)) contracts")
        }
        if p.contractScaling > 0 && Double(contracts) > p.contractScaling {
            reasons.append("position \(contracts) > scaling-plan cap \(intCap(p.contractScaling)) contracts")
        }
        // Dollar caps — a single stop-out at this size.
        if p.dailyLossLimit > 0 && dollarAtSize > p.dailyLossLimit {
            reasons.append("one stop-out \(money(dollarAtSize)) exceeds daily-loss limit \(money(p.dailyLossLimit))")
        }
        if p.trailingDrawdown > 0 && dollarAtSize > p.trailingDrawdown {
            reasons.append("one stop-out \(money(dollarAtSize)) exceeds trailing drawdown \(money(p.trailingDrawdown))")
        }

        // Largest contract count within EVERY set limit.
        var cap = Int.max
        if p.maxPositionSize > 0 { cap = min(cap, intCap(p.maxPositionSize)) }
        if p.contractScaling > 0 { cap = min(cap, intCap(p.contractScaling)) }
        if p.dailyLossLimit > 0 { cap = min(cap, Int((p.dailyLossLimit / perContract).rounded(.down))) }
        if p.trailingDrawdown > 0 { cap = min(cap, Int((p.trailingDrawdown / perContract).rounded(.down))) }
        let maxContracts = cap == Int.max ? 0 : max(0, cap)

        return Decision(verdict: reasons.isEmpty ? .withinLimits : .breach,
                        reasons: reasons, maxContracts: maxContracts,
                        dollarRiskAtSize: dollarAtSize, evaluatedContracts: contracts)
    }

    private static func intCap(_ v: Double) -> Int { max(0, Int(v.rounded(.down))) }

    // Whole-dollar formatting with thousands grouping (headless-safe NumberFormatter).
    private static let fmt: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0; f.minimumFractionDigits = 0
        return f
    }()
    static func money(_ v: Double) -> String { "$" + (fmt.string(from: NSNumber(value: v.rounded())) ?? String(Int(v.rounded()))) }
}

// Blank firm-named templates. NO numeric limits are shipped (company-researcher's sourced table
// had not landed at build time) — every number is 0 until the buyer enters it from the firm's own
// terms, and `sourceURL` starts empty for the buyer to paste. This is the §5.1-safe fallback: the
// editable mechanism ships; invented firm numbers do not. `note` reuses the factual FirmData text.
enum RuleProfilePresets {
    struct Template: Identifiable { let name: String; let note: String; var id: String { name } }

    // Firm names + factual qualitative notes only (mirrors Model.FirmData) — zero invented limits.
    static let templates: [Template] = [
        Template(name: "Apex Trader Funding", note: "Trailing drawdown + 30% consistency rule — confirm current numbers on the firm's site."),
        Template(name: "Topstep", note: "Daily loss limit + trailing max drawdown — confirm current numbers on the firm's site."),
        Template(name: "Take Profit Trader", note: "End-of-day trailing drawdown — confirm current numbers on the firm's site."),
        Template(name: "Earn2Trade", note: "Profit target + max drawdown — confirm current numbers on the firm's site."),
        Template(name: "MyFundedFutures", note: "Plan-dependent (some plans have no daily loss limit) — confirm current numbers on the firm's site."),
        Template(name: "Bulenox", note: "Trailing drawdown + consistency — confirm current numbers on the firm's site."),
        Template(name: "Tradeify", note: "End-of-day drawdown options — confirm current numbers on the firm's site."),
        Template(name: "Elite Trader Funding", note: "Static or trailing drawdown options — confirm current numbers on the firm's site."),
        Template(name: "Funded Futures Network", note: "Trailing drawdown + scaling — confirm current numbers on the firm's site."),
        Template(name: "Legends Trading", note: "Intraday or end-of-day drawdown choices — confirm current numbers on the firm's site."),
    ]

    // A blank profile pre-named for a firm. Buyer fills in every number from the firm's terms.
    static func profile(for name: String) -> RuleProfile {
        RuleProfile(name: name)
    }
    static func custom() -> RuleProfile { RuleProfile(name: "Custom profile") }
}
