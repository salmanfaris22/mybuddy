import Foundation

/// The WebRTC data channels that carry remote input while a screen stream is running (PROTOCOL §4).
public enum InputDataChannel: String, Sendable, CaseIterable {
    /// Unordered, no retransmits: pointer moves and scrolling — a late move is worthless, so it is dropped.
    case pointer = "mb-input"
    /// Reliable and ordered: clicks, keys and text are never dropped or reordered.
    case reliable = "mb-input-rel"

    public var allowedTypes: Set<EventType> {
        switch self {
        case .pointer: [.inputPointer, .inputScroll]
        case .reliable: [.inputButton, .inputKey, .inputText]
        }
    }

    public static func channel(for type: EventType) -> InputDataChannel? {
        allCases.first { $0.allowedTypes.contains(type) }
    }
}

/// Checks every message that arrives on an input data channel exactly like an MBH1 frame: the DTLS channel is
/// encrypted and bound to the session (its fingerprint travelled inside MBH1), but contents are still
/// untrusted — schema, type allowlist per channel, session id, strictly increasing sequence per channel, and
/// rate limits. Capability checks (`input.control`) stay with the host, which knows the current grants.
public struct DataChannelInputGate: Sendable {
    public enum Rejection: Error, Equatable, Sendable {
        case malformed(String)
        case notInput
        case wrongChannel
        case wrongSession
        case replayed
        case rateLimited
    }

    public let sessionId: String
    private var guards: [InputDataChannel: SequenceGuard] = [:]
    private var limiter = InputRateLimiter()

    public init(sessionId: String) { self.sessionId = sessionId }

    public mutating func accept(_ data: Data, on channel: InputDataChannel, now: Date = Date()) -> Result<Envelope, Rejection> {
        let envelope: Envelope
        do {
            envelope = try EnvelopeCodec.decode(data, receiver: .mac)
        } catch {
            return .failure(.malformed(error.code))
        }
        guard envelope.type.spec.channel == "input" else { return .failure(.notInput) }
        guard channel.allowedTypes.contains(envelope.type) else { return .failure(.wrongChannel) }
        guard envelope.sessionId == sessionId else { return .failure(.wrongSession) }
        var sequenceGuard = guards[channel] ?? SequenceGuard()
        do {
            try sequenceGuard.accept(envelope)
        } catch {
            return .failure(.replayed)
        }
        guards[channel] = sequenceGuard
        guard limiter.allow(envelope.type, now: now) else { return .failure(.rateLimited) }
        return .success(envelope)
    }
}
