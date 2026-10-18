import Foundation

/// Connection states shared by Mac and Android (docs/ARCHITECTURE.md §5).
public enum ConnectionState: Sendable, Equatable {
    case offline
    case discovering
    case pairing
    case awaitingApproval(code: String)
    case connecting
    case directConnected
    case relayedConnected
    case reconnecting(attempt: Int, nextRetry: TimeInterval)
    case suspended
    case failed(reason: String)
    case disconnected

    public var isConnected: Bool {
        switch self {
        case .directConnected, .relayedConnected: true
        default: false
        }
    }

    public var title: String {
        switch self {
        case .offline: "Offline"
        case .discovering: "Looking for your devices"
        case .pairing: "Pairing"
        case .awaitingApproval: "Waiting for approval"
        case .connecting: "Connecting"
        case .directConnected: "Connected · direct"
        case .relayedConnected: "Connected · relayed"
        case .reconnecting(let attempt, _): "Reconnecting (attempt \(attempt))"
        case .suspended: "Suspended"
        case .failed: "Connection failed"
        case .disconnected: "Disconnected"
        }
    }

    public enum Tone: Sendable { case neutral, live, info, warning, danger }

    public var tone: Tone {
        switch self {
        case .directConnected: .live
        case .relayedConnected: .info
        case .discovering, .pairing, .awaitingApproval, .connecting, .reconnecting: .warning
        case .failed: .danger
        case .offline, .suspended, .disconnected: .neutral
        }
    }
}

/// Bounded exponential backoff with full jitter. Never retries forever.
public struct Backoff: Sendable {
    public let base: TimeInterval
    public let cap: TimeInterval
    public let maxAttempts: Int
    public private(set) var attempt = 0

    public init(base: TimeInterval = 0.5, cap: TimeInterval = 30, maxAttempts: Int = 8) {
        self.base = base
        self.cap = cap
        self.maxAttempts = maxAttempts
    }

    /// The upper bound of the delay for a given 1-based attempt.
    public func ceiling(forAttempt n: Int) -> TimeInterval {
        min(cap, base * pow(2, Double(max(0, n - 1))))
    }

    /// Returns the next delay, or nil when attempts are exhausted (surface `.failed`).
    public mutating func nextDelay(random: (ClosedRange<Double>) -> Double = { Double.random(in: $0) }) -> TimeInterval? {
        guard attempt < maxAttempts else { return nil }
        attempt += 1
        return random(0...ceiling(forAttempt: attempt))
    }

    public mutating func reset() { attempt = 0 }
}
