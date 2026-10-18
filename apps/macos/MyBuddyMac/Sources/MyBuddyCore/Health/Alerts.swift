import Foundation

/// When to tell the phone that the Mac's battery is low: once per discharge, at or below `threshold`, and again
/// only after the Mac charged (or climbed back above `rearm`). Unknown readings never alert.
public struct BatteryAlertPolicy: Sendable, Equatable {
    public let threshold: Int
    public let rearm: Int
    private(set) var armed = true

    public init(threshold: Int = 15, rearm: Int = 25) {
        self.threshold = threshold
        self.rearm = rearm
    }

    /// Returns true exactly when an alert should be sent for this reading.
    public mutating func evaluate(level: Int?, charging: Bool?) -> Bool {
        guard let level, let charging else { return false }
        if charging || level >= rearm {
            armed = true
            return false
        }
        guard armed, level <= threshold else { return false }
        armed = false
        return true
    }
}
