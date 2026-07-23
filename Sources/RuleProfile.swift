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

// ─────────────────────────────────────────────────────────────────────────────
// DISCIPLINE COCKPIT — live compliance gauges computed from the buyer's OWN fills/paper ledger
// against the caps THEY entered. PURE, deterministic, no SwiftUI/network. This is the discipline
// layer no prop-firm trader's journal bundles: real-time daily-loss + trailing-drawdown meters, a
// behavioral Tiltmeter (frequency/size escalation vs the buyer's OWN baseline), risk-of-ruin on the
// buyer's OWN numbers, and an auto-mute flag that hides the signal display once a cap is breached.
//
// HONESTY (§5.1 / H1): every number here is derived from the buyer's own trades. There is NO
// aggregate win-rate, net-P&L, or performance figure exposed as a product claim — the meters report
// how much of the buyer's OWN loss caps are used (a risk quantity, not a track record), the Tiltmeter
// reports behavioral ratios, and risk-of-ruin is a probability of hitting the buyer's OWN floor. An
// empty ledger is honestly "no data"; caps unset are honestly "not set". Nothing is fabricated, and
// this never auto-trades — it only annotates and, on a breach, mutes the signal surface.

// One realized fill from the buyer's own blotter (paper) or imported journal. Decoupled from the UI
// so the cockpit math is independently testable. `contracts` is position size (0 == unknown size).
struct DisciplineFill: Codable, Hashable {
    var date: Date          // close time of the realized trade
    var pnl: Double         // realized $ (positive win, negative loss)
    var contracts: Double   // position size in contracts (>= 0; 0 == unknown)
    init(date: Date, pnl: Double, contracts: Double = 0) {
        self.date = date; self.pnl = pnl; self.contracts = max(0, contracts)
    }
}

struct DisciplineCockpit: Equatable {
    // A cap meter: how much of one of the buyer's own $ caps is used right now.
    struct Meter: Equatable {
        var used: Double        // $ consumed against the cap (>= 0)
        var limit: Double       // the buyer's own cap (0 == not set)
        var isSet: Bool { limit > 0 }
        var fraction: Double { limit > 0 ? used / limit : 0 }   // 0…>1
        var remaining: Double { limit > 0 ? limit - used : 0 }  // can go negative on breach
        var isBreached: Bool { limit > 0 && used >= limit }
    }

    enum TiltLevel: String, Equatable { case insufficient, calm, elevated, high }
    struct Tilt: Equatable {
        var level: TiltLevel = .insufficient
        var tradeCountToday: Int = 0
        var baselineTradesPerDay: Double = 0   // buyer's own median active-day count (0 == unknown)
        var freqRatio: Double = 0              // today count / baseline (0 == baseline unknown)
        var avgContractsToday: Double = 0
        var baselineContracts: Double = 0      // buyer's own median size (0 == unknown)
        var sizeRatio: Double = 0              // today size / baseline (0 == baseline unknown)
        var gauge: Double = 0                  // 0…1 escalation index (0 == at/below baseline)
        var reasons: [String] = []             // honest, specific escalation notes
    }

    enum RuinState: String, Equatable { case insufficient, noEdge, computed }
    struct Ruin: Equatable {
        var state: RuinState = .insufficient
        var probability: Double = 0    // 0…1 (1 == certain ruin on a non-positive edge)
        var unitsToFloor: Double = 0   // buyer's buffer measured in typical-loss units
        var note: String = ""
    }

    var dailyLoss = Meter(used: 0, limit: 0)
    var trailingDrawdown = Meter(used: 0, limit: 0)
    var tilt = Tilt()
    var ruin = Ruin()
    var muteSignals = false        // true once a HARD cap (daily loss / trailing DD) is breached
    var muteReason = ""
    var hasProfile = false         // an active profile with at least one cap set
    var hasData = false            // the buyer has at least one realized fill

    // Minimum prior active days for a stable Tiltmeter baseline, and minimum decided trades for RoR.
    static let minBaselineDays = 2
    static let minDecidedForRuin = 10

    // Compute the full cockpit from the buyer's own fills under their own profile.
    static func compute(fills: [DisciplineFill], profile: RuleProfile?, startingBalance: Double,
                        now: Date, calendar: Calendar = .current) -> DisciplineCockpit {
        var c = DisciplineCockpit()
        c.hasProfile = (profile?.hasLimits ?? false)
        c.hasData = !fills.isEmpty
        let sorted = fills.sorted { $0.date < $1.date }

        // Equity curve → current trailing drawdown from the running peak (includes the starting balance).
        var equity = startingBalance
        var peak = startingBalance
        for f in sorted { equity += f.pnl; peak = max(peak, equity) }
        let currentEquity = equity
        let currentDD = max(0, peak - currentEquity)

        // Today's realized loss (only losses consume the daily-loss cap).
        let today = calendar.startOfDay(for: now)
        let todayFills = sorted.filter { calendar.startOfDay(for: $0.date) == today }
        let todayNet = todayFills.reduce(0) { $0 + $1.pnl }
        let todayLoss = max(0, -todayNet)

        c.dailyLoss = Meter(used: todayLoss, limit: max(0, profile?.dailyLossLimit ?? 0))
        c.trailingDrawdown = Meter(used: currentDD, limit: max(0, profile?.trailingDrawdown ?? 0))

        c.tilt = tiltmeter(sorted: sorted, todayFills: todayFills, today: today, calendar: calendar)
        c.ruin = riskOfRuin(sorted: sorted, profile: profile,
                            trailingUsed: currentDD, todayLoss: todayLoss, currentEquity: currentEquity)

        // Auto-mute: a breached HARD prop-firm cap means the buyer is done — mute new signal display.
        if c.dailyLoss.isBreached {
            c.muteSignals = true
            c.muteReason = "Daily-loss limit reached (\(money(todayLoss)) of \(money(c.dailyLoss.limit))). Signals muted — stop for the session."
        } else if c.trailingDrawdown.isBreached {
            c.muteSignals = true
            c.muteReason = "Trailing drawdown hit (\(money(currentDD)) of \(money(c.trailingDrawdown.limit))). Signals muted — protect the account."
        }
        return c
    }

    // Behavioral escalation vs the buyer's OWN baseline. Frequency = today's trade count vs the median
    // count on prior active days; size = today's avg contracts vs the median contracts on prior fills.
    private static func tiltmeter(sorted: [DisciplineFill], todayFills: [DisciplineFill],
                                  today: Date, calendar: Calendar) -> Tilt {
        var t = Tilt()
        t.tradeCountToday = todayFills.count
        let sizedToday = todayFills.map { $0.contracts }.filter { $0 > 0 }
        t.avgContractsToday = sizedToday.isEmpty ? 0 : sizedToday.reduce(0, +) / Double(sizedToday.count)

        let prior = sorted.filter { calendar.startOfDay(for: $0.date) < today }
        let byDay = Dictionary(grouping: prior) { calendar.startOfDay(for: $0.date) }
        let priorCounts = byDay.values.map { Double($0.count) }
        guard priorCounts.count >= minBaselineDays else { t.level = .insufficient; return t }

        t.baselineTradesPerDay = median(priorCounts)
        let priorSizes = prior.map { $0.contracts }.filter { $0 > 0 }
        t.baselineContracts = priorSizes.isEmpty ? 0 : median(priorSizes)

        t.freqRatio = t.baselineTradesPerDay > 0 ? Double(t.tradeCountToday) / t.baselineTradesPerDay : 0
        t.sizeRatio = (t.baselineContracts > 0 && t.avgContractsToday > 0)
            ? t.avgContractsToday / t.baselineContracts : 0

        let escalation = max(t.freqRatio, t.sizeRatio)
        t.gauge = min(1, max(0, escalation - 1))   // ratio 1×→0, 2×→1 (capped)
        if t.freqRatio >= 1.25 {
            t.reasons.append("\(t.tradeCountToday) trades today vs ~\(trim(t.baselineTradesPerDay)) typical (\(x(t.freqRatio)))")
        }
        if t.sizeRatio >= 1.25 {
            t.reasons.append("avg \(trim(t.avgContractsToday)) contracts vs ~\(trim(t.baselineContracts)) typical (\(x(t.sizeRatio)))")
        }
        t.level = escalation >= 1.75 ? .high : (escalation >= 1.25 ? .elevated : .calm)
        return t
    }

    // Risk of ruin on the buyer's OWN trades: probability of hitting their OWN drawdown floor at the
    // current per-trade risk. Reduces exactly to the classic gambler's-ruin (q/p)^U for even-money
    // bets; the payoff-adjusted edge z = e/b generalizes it. NOT a performance claim — a risk gauge.
    private static func riskOfRuin(sorted: [DisciplineFill], profile: RuleProfile?,
                                   trailingUsed: Double, todayLoss: Double, currentEquity: Double) -> Ruin {
        var r = Ruin()
        let decided = sorted.filter { $0.pnl != 0 }
        let wins = decided.filter { $0.pnl > 0 }
        let losses = decided.filter { $0.pnl < 0 }
        // Need a real sample AND at least one loss to size per-trade risk — else honestly insufficient.
        guard decided.count >= minDecidedForRuin, !wins.isEmpty, !losses.isEmpty else {
            r.state = .insufficient
            r.note = "Needs ≥\(minDecidedForRuin) of your own decided trades (with wins and losses) to estimate."
            return r
        }
        let W = Double(wins.count) / Double(decided.count)
        let avgWin = wins.reduce(0) { $0 + $1.pnl } / Double(wins.count)
        let avgLoss = abs(losses.reduce(0) { $0 + $1.pnl } / Double(losses.count))   // > 0
        guard avgLoss > 0 else { r.state = .insufficient; r.note = "No sized loss to measure risk."; return r }
        let b = avgWin / avgLoss                      // payoff ratio in units of one average loss
        let e = W * b - (1 - W)                       // per-trade expectancy in average-loss units
        if e <= 0 {
            r.state = .noEdge
            r.probability = 1.0
            r.note = "Your own trades show no positive edge yet — risk of ruin is effectively certain over time."
            return r
        }
        // Buffer to the floor: prefer the trailing-drawdown room, else the daily-loss room, else equity.
        let buffer: Double = {
            if let td = profile?.trailingDrawdown, td > 0 { return max(0, td - trailingUsed) }
            if let dl = profile?.dailyLossLimit, dl > 0 { return max(0, dl - todayLoss) }
            return max(0, currentEquity)
        }()
        guard buffer > 0 else {
            r.state = .computed; r.probability = 1.0; r.unitsToFloor = 0
            r.note = "You are at your floor — any further loss breaches the cap."
            return r
        }
        let U = buffer / avgLoss                      // units of a typical loss to the floor
        let z = min(0.999999, max(-0.999999, e / b)) // even-money reduces to (q/p): z = 2p-1
        let ror = pow((1 - z) / (1 + z), U)
        r.state = .computed
        r.probability = min(1, max(0, ror))
        r.unitsToFloor = U
        r.note = "At your current per-trade loss (~\(money(avgLoss))) you have ~\(trim(U)) losing trades of room to your floor."
        return r
    }

    // MARK: helpers (headless-safe; no locale surprises for tests)
    private static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n/2] : (s[n/2 - 1] + s[n/2]) / 2
    }
    private static func trim(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
    private static func x(_ v: Double) -> String { String(format: "%.1f×", v) }
    private static func money(_ v: Double) -> String { RuleProfileGate.money(v) }
}

// Blank firm-named templates + SOURCED presets. Blank templates ship for firms with no fetched
// figures (buyer enters every number). SOURCED presets pre-fill only cells company-researcher
// fetched from each firm's OWN help page, refreshed 2026-07-14 (`propfirm-rules-v3-2026-07-14.md`,
// which supersedes the v2 blocked cells), each carrying that firm-primary `sourceURL`. §5.1 encoding
// rule: a cell's confidence is its own — only `[confirmed]`/`[confirmed-derived]`/`[single-source]`
// cells are encoded; `[unverified-blocked]` and tier-based cells stay 0 (user-entered). EVERY field
// remains editable in the profile editor; rules change often, so a preset is a cited starting point
// the buyer confirms, never an authority.
//
// v3 (2026-07-14) cleared prior blocks: Take Profit Trader now covers ALL five sizes (25/50/75/100/150K)
// from the firm's OWN Zendesk help center (Rule 1/2/3 articles), and Tradeify's restructured page
// (updated 2026-06-18) resolves the 25K Growth trailing drawdown = $1,000 (retiring the v2 N/A) and
// corrects Growth 100K→$3,500 / 150K→$5,000 to the firm's verbatim lock-trigger values. FundedNext
// Bolt (50K only) is added. Apex EOD + Legacy per-size dollars remain [unverified-blocked] (firm pages
// render them only as an image / Zendesk API 403) → those stay 0, never invented.
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

    // One firm program at one account size, filled ONLY from its own fetched page (2026-07-12).
    // A 0 cell is deliberately user-entered (the firm made it tier-based or hid it behind a JS tab);
    // `note` says which. maxPositionSize is the firm's mini-contract cap. contractScaling stays 0 —
    // the buyer sets it per their funded scaling tier.
    struct SourcedPreset: Identifiable {
        let firm: String            // firm + program (display + profile name stem)
        let accountLabel: String    // e.g. "50K"
        let dailyLossLimit: Double   // 0 == user-entered (firm has none, or it is tier-based)
        let trailingDrawdown: Double // 0 == user-entered (firm prints N/A or hides it)
        let maxPositionSize: Double  // mini-contract cap
        let sourceURL: String        // the firm's OWN page the value came from
        let note: String             // drawdown TYPE + which cells stay user-entered
        var id: String { "\(firm) \(accountLabel)" }
        var displayName: String { "\(firm) — \(accountLabel)" }

        // A cited, pre-filled profile. contractScaling/pointValue stay 0 (buyer's tier/instrument),
        // and every field is editable afterward.
        func makeProfile() -> RuleProfile {
            RuleProfile(name: displayName,
                        dailyLossLimit: dailyLossLimit,
                        trailingDrawdown: trailingDrawdown,
                        maxPositionSize: maxPositionSize,
                        contractScaling: 0,
                        pointValue: 0,
                        sourceURL: sourceURL)
        }
    }

    // Firm-primary source URLs — kept beside the data they cite (v2 fetch 2026-07-12; v3 2026-07-14).
    private static let urlFundedNext = "https://helpfutures.fundednext.com/en/articles/14878751-what-is-fundednext-futures-flex-challenge"
    private static let urlFundedNextBolt = "https://fundednext.com/futures/bolt"
    // TPT per-size caps come from the firm's OWN Zendesk help center (v3, 2026-07-14). Rule 3 (EOD max
    // trailing drawdown) is the source for the headline trailing cap encoded below; Rule 2 (max position
    // size) sources the contract cap. Both are firm-owned takeprofittraderhelp.zendesk.com articles.
    private static let urlTPT = "https://takeprofittraderhelp.zendesk.com/hc/en-us/articles/15170265979165-Rule-3-Do-Not-Hit-End-Of-Day-EOD-Maximum-Trailing-Drawdown"
    private static let urlTradeify = "https://help.tradeify.co/en/articles/10495897-rules-trailing-max-drawdowns"
    private static let urlApex = "https://apextraderfunding.com/help-center/intraday-trailing-drawdown-accounts/intraday-trailing-drawdown-performance-accounts-pa/"

    // Cited cells from propfirm-rules-v3-2026-07-14.md (supersedes v2 blocked cells). Grouped by
    // firm, ascending size. Every non-zero cap carries a firm-primary https sourceURL; [unverified-blocked]
    // cells (Apex EOD/Legacy $, Apex tier-based daily-loss) stay 0.
    static let sourcedPresets: [SourcedPreset] = [
        // FundedNext Futures — Flex (end-of-day trailing). Flex has NO daily-loss limit.
        SourcedPreset(firm: "FundedNext Flex", accountLabel: "50K",  dailyLossLimit: 0, trailingDrawdown: 1500, maxPositionSize: 3,
                      sourceURL: urlFundedNext, note: "Flex — end-of-day trailing drawdown; no daily-loss limit. Cap = mini contracts."),
        SourcedPreset(firm: "FundedNext Flex", accountLabel: "100K", dailyLossLimit: 0, trailingDrawdown: 2500, maxPositionSize: 5,
                      sourceURL: urlFundedNext, note: "Flex — end-of-day trailing drawdown; no daily-loss limit. Cap = mini contracts."),
        SourcedPreset(firm: "FundedNext Flex", accountLabel: "150K", dailyLossLimit: 0, trailingDrawdown: 4000, maxPositionSize: 8,
                      sourceURL: urlFundedNext, note: "Flex — end-of-day trailing drawdown; no daily-loss limit. Cap = mini contracts."),

        // FundedNext Futures — Bolt (50K ONLY). Daily-loss = soft breach; max loss = EOD trailing (hard).
        // FLAG (v3): a help-center listing indicated Bolt/Rapid may close to new purchases/resets effective
        // 2026-07-10 [unverified] — valid for existing accounts; verify buyability before surfacing as buyable.
        SourcedPreset(firm: "FundedNext Bolt", accountLabel: "50K", dailyLossLimit: 1000, trailingDrawdown: 2000, maxPositionSize: 3,
                      sourceURL: urlFundedNextBolt, note: "Bolt (50K only) — daily-loss $1,000 soft breach (pauses to EOD); max loss $2,000 EOD trailing; profit target $3,000; 3 mini / 9 micro. Verify purchasability (2026-07-10 close flag)."),

        // Take Profit Trader — no daily-loss limit on any account. v3: ALL five sizes now firm-Zendesk sourced
        // (Rule 1/2/3 articles). Trailing = EOD (Test/PRO+) or intraday (PRO); the $ is identical, only the window differs.
        SourcedPreset(firm: "Take Profit Trader", accountLabel: "25K",  dailyLossLimit: 0, trailingDrawdown: 1500, maxPositionSize: 3,
                      sourceURL: urlTPT, note: "No daily-loss limit. Trailing = EOD (Test/PRO+) or intraday (PRO). Profit target $1,500; cap = 3 minis / 30 micros."),
        SourcedPreset(firm: "Take Profit Trader", accountLabel: "50K",  dailyLossLimit: 0, trailingDrawdown: 2000, maxPositionSize: 6,
                      sourceURL: urlTPT, note: "No daily-loss limit. Trailing = EOD (Test/PRO+) or intraday (PRO). Profit target $3,000; cap = 6 minis / 60 micros."),
        SourcedPreset(firm: "Take Profit Trader", accountLabel: "75K",  dailyLossLimit: 0, trailingDrawdown: 2500, maxPositionSize: 9,
                      sourceURL: urlTPT, note: "No daily-loss limit. Trailing = EOD (Test/PRO+) or intraday (PRO). Profit target $4,500; cap = 9 minis / 90 micros."),
        SourcedPreset(firm: "Take Profit Trader", accountLabel: "100K", dailyLossLimit: 0, trailingDrawdown: 3000, maxPositionSize: 12,
                      sourceURL: urlTPT, note: "No daily-loss limit. Trailing = EOD (Test/PRO+) or intraday (PRO). Profit target $6,000; cap = 12 minis / 120 micros."),
        SourcedPreset(firm: "Take Profit Trader", accountLabel: "150K", dailyLossLimit: 0, trailingDrawdown: 4500, maxPositionSize: 15,
                      sourceURL: urlTPT, note: "No daily-loss limit. Trailing = EOD (Test/PRO+) or intraday (PRO). Profit target $9,000; cap = 15 minis / 150 micros."),

        // Tradeify — Growth (end-of-day trailing). Daily-loss = soft breach; trailing = hard breach.
        // v3 (firm page updated 2026-06-18): 25K trailing RESOLVED = $1,000 (retires v2 N/A); Growth
        // 100K→$3,500 and 150K→$5,000 corrected to the firm's verbatim lock-trigger values (start+DD+100).
        SourcedPreset(firm: "Tradeify Growth", accountLabel: "25K",  dailyLossLimit: 600,  trailingDrawdown: 1000, maxPositionSize: 1,
                      sourceURL: urlTradeify, note: "Growth — EOD trailing (hard breach); daily-loss soft breach (pauses the day). Trailing $1,000 (lock @ $26,100, v3)."),
        SourcedPreset(firm: "Tradeify Growth", accountLabel: "50K",  dailyLossLimit: 1250, trailingDrawdown: 2000, maxPositionSize: 4,
                      sourceURL: urlTradeify, note: "Growth — EOD trailing (hard breach); daily-loss soft breach (pauses the day)."),
        SourcedPreset(firm: "Tradeify Growth", accountLabel: "100K", dailyLossLimit: 2500, trailingDrawdown: 3500, maxPositionSize: 8,
                      sourceURL: urlTradeify, note: "Growth — EOD trailing (hard breach); daily-loss soft breach (pauses the day). Trailing $3,500 (firm example, v3)."),
        SourcedPreset(firm: "Tradeify Growth", accountLabel: "150K", dailyLossLimit: 3000, trailingDrawdown: 5000, maxPositionSize: 12,
                      sourceURL: urlTradeify, note: "Growth — EOD trailing (hard breach); daily-loss soft breach (pauses the day). Trailing $5,000 (lock @ $155,100, v3)."),

        // Apex Trader Funding — Intraday Trailing PA. Daily-loss is scaling-tier-based (user-entered).
        SourcedPreset(firm: "Apex Intraday PA", accountLabel: "25K",  dailyLossLimit: 0, trailingDrawdown: 1000, maxPositionSize: 2,
                      sourceURL: urlApex, note: "Intraday Trailing PA — daily-loss is scaling-tier-based, so enter your tier. Trailing stops at Max DD + $100."),
        SourcedPreset(firm: "Apex Intraday PA", accountLabel: "50K",  dailyLossLimit: 0, trailingDrawdown: 2000, maxPositionSize: 4,
                      sourceURL: urlApex, note: "Intraday Trailing PA — daily-loss is scaling-tier-based, so enter your tier. Trailing stops at Max DD + $100."),
        SourcedPreset(firm: "Apex Intraday PA", accountLabel: "100K", dailyLossLimit: 0, trailingDrawdown: 3000, maxPositionSize: 6,
                      sourceURL: urlApex, note: "Intraday Trailing PA — daily-loss is scaling-tier-based, so enter your tier. Trailing stops at Max DD + $100."),
        SourcedPreset(firm: "Apex Intraday PA", accountLabel: "150K", dailyLossLimit: 0, trailingDrawdown: 4000, maxPositionSize: 10,
                      sourceURL: urlApex, note: "Intraday Trailing PA — daily-loss is scaling-tier-based, so enter your tier. Trailing stops at Max DD + $100."),
    ]

    // Sourced presets grouped by firm, preserving size order — for a firm → size submenu.
    static var sourcedByFirm: [(firm: String, presets: [SourcedPreset])] {
        var order: [String] = []
        var groups: [String: [SourcedPreset]] = [:]
        for p in sourcedPresets {
            if groups[p.firm] == nil { order.append(p.firm) }
            groups[p.firm, default: []].append(p)
        }
        return order.map { (firm: $0, presets: groups[$0] ?? []) }
    }

    // A blank profile pre-named for a firm. Buyer fills in every number from the firm's terms.
    static func profile(for name: String) -> RuleProfile {
        RuleProfile(name: name)
    }
    static func custom() -> RuleProfile { RuleProfile(name: "Custom profile") }
}
