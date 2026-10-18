import Testing
@testable import MyBuddyCore

@Suite("Mac alerts to the phone")
struct AlertsTests {
    /// Feeds readings through the policy and returns which ones alerted.
    private func run(_ readings: [(Int?, Bool?)], policy: BatteryAlertPolicy = BatteryAlertPolicy(threshold: 15, rearm: 25)) -> [Bool] {
        var p = policy
        return readings.map { p.evaluate(level: $0.0, charging: $0.1) }
    }

    @Test func batteryLowAlertsOncePerDischargeAndRearmsAfterCharging() {
        // 40 → 15 (alert) → 12 → 9 → charging (re-arm) → 14 on battery again (alert)
        #expect(run([(40, false), (15, false), (12, false), (9, false), (9, true), (14, false)]) == [false, true, false, false, false, true])
    }

    @Test func climbingAboveTheRearmLevelAlsoRearms() {
        #expect(run([(10, false), (20, false), (26, false), (15, false)]) == [true, false, false, true])
    }

    @Test func unknownReadingsNeverAlert() {
        #expect(run([(nil, false), (5, nil)]) == [false, false])
    }
}
