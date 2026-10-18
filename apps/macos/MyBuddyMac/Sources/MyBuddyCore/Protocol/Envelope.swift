import Foundation

/// Every v1 event type. `EventCatalogTests` asserts this matches the shared catalog exactly.
public enum EventType: String, CaseIterable, Sendable, Codable {
    case pairingRequest = "pairing.request"
    case pairingApproved = "pairing.approved"
    case pairingRejected = "pairing.rejected"
    case sessionRequest = "session.request"
    case sessionApproved = "session.approved"
    case sessionRejected = "session.rejected"
    case sessionClosed = "session.closed"
    case hostHeartbeat = "host.heartbeat"
    case hostStatus = "host.status"
    case error = "error"
    case connectOffer = "connect.offer"
    case connectEnroll = "connect.enroll"
    case connectEnrolled = "connect.enrolled"
    case webrtcOffer = "webrtc.offer"
    case webrtcAnswer = "webrtc.answer"
    case webrtcIce = "webrtc.ice"
    case screenStart = "screen.start"
    case screenUpdate = "screen.update"
    case screenStop = "screen.stop"
    case screenState = "screen.state"
    case inputPointer = "input.pointer"
    case inputButton = "input.button"
    case inputScroll = "input.scroll"
    case inputKey = "input.key"
    case inputText = "input.text"
    case hostAppList = "host.app.list"
    case hostAppOpen = "host.app.open"
    case hostFileList = "host.file.list"
    case hostFileOpen = "host.file.open"
    case fileOffer = "file.offer"
    case fileRequest = "file.request"
    case fileStart = "file.start"
    case fileChunk = "file.chunk"
    case fileAck = "file.ack"
    case filePause = "file.pause"
    case fileResume = "file.resume"
    case fileCancel = "file.cancel"
    case fileComplete = "file.complete"
    case fileError = "file.error"
    case clipboardOffer = "clipboard.offer"
    case clipboardRequest = "clipboard.request"
    case clipboardContent = "clipboard.content"
    case clipboardApplied = "clipboard.applied"
    case clipboardPaused = "clipboard.paused"
    case aiProviderStatus = "ai.provider.status"
    case aiRequest = "ai.request"
    case aiDelta = "ai.delta"
    case aiComplete = "ai.complete"
    case aiError = "ai.error"
    case aiToolProposed = "ai.tool.proposed"
    case aiToolApproval = "ai.tool.approval"
    case aiToolResult = "ai.tool.result"
    case aiCancel = "ai.cancel"
    case voiceStarted = "voice.started"
    case voiceTranscript = "voice.transcript"
    case voiceIntentProposed = "voice.intent.proposed"
    case voiceIntentApproved = "voice.intent.approved"
    case voiceIntentResult = "voice.intent.result"
    case voiceCancelled = "voice.cancelled"
    case healthSnapshotRequest = "health.snapshot.request"
    case healthSnapshotResult = "health.snapshot.result"
    case healthReportExported = "health.report.exported"
    case notificationPosted = "notification.posted"
    case notificationRemoved = "notification.removed"
    case notesIndex = "notes.index"
    case notesPut = "notes.put"

    public var spec: EventSpec { EventCatalog.shared.events[rawValue]! }
    public var requiredCapability: Capability? { spec.capability.flatMap(Capability.init(rawValue:)) }
}

/// Decoder errors shared with the Kotlin implementation (`docs/PROTOCOL.md` §3).
public enum ProtocolError: Error, Equatable, Sendable, CustomStringConvertible {
    case tooLarge
    case malformedJSON
    case invalidEnvelope(String)
    case unsupportedVersion
    case unknownType(String)
    case wrongDirection
    case invalidPayload(String)
    case replayedSequence

    public var code: String {
        switch self {
        case .tooLarge: "too_large"
        case .malformedJSON: "malformed_json"
        case .invalidEnvelope: "invalid_envelope"
        case .unsupportedVersion: "unsupported_version"
        case .unknownType: "unknown_type"
        case .wrongDirection: "wrong_direction"
        case .invalidPayload: "invalid_payload"
        case .replayedSequence: "replayed_sequence"
        }
    }

    public var description: String {
        switch self {
        case .invalidEnvelope(let why), .invalidPayload(let why): "\(code): \(why)"
        case .unknownType(let type): "\(code): \(type.prefix(64))"
        default: code
        }
    }
}

/// A decoded, fully validated envelope.
public struct Envelope: Sendable, Equatable {
    public let type: EventType
    public let sessionId: String
    public let sequence: Int64
    public let sentAt: Date
    public let replyTo: Int64?
    public let payload: [String: JSONValue]

    public init(type: EventType, sessionId: String, sequence: Int64, sentAt: Date, replyTo: Int64? = nil, payload: [String: JSONValue]) {
        self.type = type
        self.sessionId = sessionId
        self.sequence = sequence
        self.sentAt = sentAt
        self.replyTo = replyTo
        self.payload = payload
    }

    /// Decodes the payload into a typed model.
    public func decodePayload<T: Decodable>(_: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(payload))
    }
}

public enum EnvelopeCodec {
    private static let typePattern = try! NSRegularExpression(pattern: #"^[a-z]+(\.[a-z]+)*$"#)
    private static let sessionPattern = try! NSRegularExpression(pattern: #"^[A-Za-z0-9_-]{8,64}$"#)
    static let maxSafeInteger: Int64 = 9_007_199_254_740_991

    private static func matches(_ regex: NSRegularExpression, _ s: String) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        return regex.firstMatch(in: s, range: range)?.range == range
    }

    /// Decodes and validates `data` as received by `receiver`.
    public static func decode(_ data: Data, receiver: ProtocolRole, catalog: EventCatalog = .shared) throws(ProtocolError) -> Envelope {
        guard data.count <= catalog.maxEnvelopeBytes else { throw .tooLarge }
        let root: JSONValue
        do {
            root = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw .malformedJSON
        }
        guard case .object(let object) = root else { throw .invalidEnvelope("not an object") }

        guard case .int(let version)? = object["version"] else { throw .invalidEnvelope("version") }
        guard version == 1 else { throw .unsupportedVersion }
        guard case .string(let typeName)? = object["type"], typeName.count <= 64, matches(typePattern, typeName) else {
            throw .invalidEnvelope("type")
        }
        guard case .string(let sessionId)? = object["sessionId"], matches(sessionPattern, sessionId) else {
            throw .invalidEnvelope("sessionId")
        }
        guard case .int(let sequence)? = object["sequence"], sequence >= 1, sequence <= maxSafeInteger else {
            throw .invalidEnvelope("sequence")
        }
        guard case .string(let sentAtString)? = object["sentAt"], let sentAt = Timestamp.parse(sentAtString) else {
            throw .invalidEnvelope("sentAt")
        }
        var replyTo: Int64?
        if let raw = object["replyTo"], raw != .null {
            guard case .int(let r) = raw, r >= 1, r <= maxSafeInteger else { throw .invalidEnvelope("replyTo") }
            replyTo = r
        }
        guard case .object(let payload)? = object["payload"] else { throw .invalidEnvelope("payload") }

        guard let spec = catalog.events[typeName], let type = EventType(rawValue: typeName) else {
            throw .unknownType(typeName)
        }
        if let limit = catalog.limits[spec.channel], data.count > limit { throw .tooLarge }
        switch (spec.dir, receiver) {
        case ("BOTH", _), ("P2M", .mac), ("M2P", .phone): break
        default: throw .wrongDirection
        }
        let fields = spec.payload ?? (receiver == .mac ? spec.payloadP2M : spec.payloadM2P) ?? [:]
        if let problem = PayloadValidator(catalog: catalog).validate(payload, against: fields) {
            throw .invalidPayload(problem)
        }
        return Envelope(type: type, sessionId: sessionId, sequence: sequence, sentAt: sentAt, replyTo: replyTo, payload: payload)
    }

    /// Encodes an envelope and validates it as the peer (`receiver`) would, so we never
    /// send something the other side must reject.
    public static func encode(_ envelope: Envelope, receiver: ProtocolRole) throws(ProtocolError) -> Data {
        var object: [String: JSONValue] = [
            "version": .int(1),
            "type": .string(envelope.type.rawValue),
            "sessionId": .string(envelope.sessionId),
            "sequence": .int(envelope.sequence),
            "sentAt": .string(Timestamp.string(from: envelope.sentAt)),
            "payload": .object(envelope.payload),
        ]
        if let replyTo = envelope.replyTo { object["replyTo"] = .int(replyTo) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(JSONValue.object(object)) else { throw .malformedJSON }
        _ = try decode(data, receiver: receiver)
        return data
    }

    /// Builds a payload dictionary from an `Encodable` model.
    public static func payload(_ value: some Encodable) -> [String: JSONValue] {
        guard let data = try? JSONEncoder().encode(value),
              case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return [:] }
        return object
    }
}

/// Enforces strictly increasing envelope sequence numbers per session (replay protection at L3).
public struct SequenceGuard: Sendable {
    public private(set) var lastSeen: Int64 = 0
    public init() {}

    public mutating func accept(_ envelope: Envelope) throws(ProtocolError) {
        guard envelope.sequence > lastSeen else { throw .replayedSequence }
        lastSeen = envelope.sequence
    }
}

/// Generates outgoing sequence numbers.
public struct SequenceCounter: Sendable {
    private var value: Int64 = 0
    public init() {}
    public mutating func next() -> Int64 {
        value += 1
        return value
    }
}
