import Foundation
import IOKit.pwr_mgt

/// Keeps this Mac and its display from idle-sleeping while a phone is connected (the same power assertions as
/// `caffeinate -di`), so the phone keeps a live picture and a reachable Mac. It never overrides closing the lid:
/// a MacBook still sleeps on lid close unless it is in clamshell mode (external display + power), and macOS has no
/// public API to change that.
public final class StayAwake: @unchecked Sendable {
    private let lock = NSLock()
    private var assertions: [IOPMAssertionID] = []

    public init() {}

    deinit { release() }

    /// True while the assertions are held.
    public var isHolding: Bool { lock.withLock { !assertions.isEmpty } }

    /// Holds or releases both assertions. Idempotent.
    public func set(_ hold: Bool, reason: String = "A paired phone is connected to MyBuddy") {
        hold ? acquire(reason: reason) : release()
    }

    private func acquire(reason: String) {
        lock.withLock {
            guard assertions.isEmpty else { return }
            for type in [kIOPMAssertionTypePreventUserIdleSystemSleep, kIOPMAssertionTypePreventUserIdleDisplaySleep] {
                var id = IOPMAssertionID(0)
                if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id) == kIOReturnSuccess {
                    assertions.append(id)
                }
            }
        }
    }

    private func release() {
        lock.withLock {
            for id in assertions { IOPMAssertionRelease(id) }
            assertions.removeAll()
        }
    }
}
