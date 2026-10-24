import Foundation

@main
struct AlertRiskRegression {
    static func main() {
        let untouched = AlertConfigPatch.make(enabled: true, provider: "pushover", endpoint: nil,
                                               pushoverToken: "", pushoverUser: "  ")
        precondition(untouched["alertEndpoint"] == nil)
        precondition(untouched["alertPushoverToken"] == nil && untouched["alertPushoverUser"] == nil)
        var saved: [String: Any] = ["alertEndpoint": "http://localhost:2586/topic?auth=secret",
                                   "alertPushoverToken": "saved-token", "alertPushoverUser": "saved-user"]
        saved.merge(untouched) { _, new in new }
        precondition(saved["alertEndpoint"] as? String == "http://localhost:2586/topic?auth=secret")
        precondition(saved["alertPushoverToken"] as? String == "saved-token")
        let edited = AlertConfigPatch.make(enabled: false, provider: "ntfy", endpoint: "",
                                            pushoverToken: " new-token ", pushoverUser: "new-user")
        precondition(edited["alertEndpoint"] as? String == "")
        precondition(edited["alertPushoverToken"] as? String == "new-token")
        let normal = RuleProfile(dailyLossLimit: 500, trailingDrawdown: 2000, maxPositionSize: 10, pointValue: 50)
        let normalDecision = RuleProfileGate.evaluate(riskPoints: 2, pointValue: 50, contracts: 1, profile: normal)
        precondition(normalDecision.verdict == .withinLimits && normalDecision.maxContracts == 5)
        precondition(RuleProfileGate.evaluate(riskPoints: 2, pointValue: 50, contracts: 6, profile: normal).isBreach)
        for bad in [Double.infinity, -Double.infinity, Double.nan, -1] {
            let invalid = RuleProfile(dailyLossLimit: bad, pointValue: 50)
            precondition(RuleProfileGate.evaluate(riskPoints: 2, pointValue: 50, contracts: 1, profile: invalid).verdict == .invalidProfile)
        }
        for large in [1e20, Double.greatestFiniteMagnitude, Double(Int.max)] {
            let huge = RuleProfile(dailyLossLimit: large, maxPositionSize: large, pointValue: 50)
            precondition(RuleProfileGate.evaluate(riskPoints: 2, pointValue: 50, contracts: 1, profile: huge).verdict == .withinLimits)
            precondition(!RuleProfileGate.money(large).isEmpty)
        }
        let overflow = RuleProfile(dailyLossLimit: 100, pointValue: 1e308)
        precondition(RuleProfileGate.evaluate(riskPoints: 1e308, pointValue: 1, contracts: 1, profile: overflow).verdict == .noSignal)
        print("alert settings preservation and risk numeric-boundary regression PASS")
    }
}
