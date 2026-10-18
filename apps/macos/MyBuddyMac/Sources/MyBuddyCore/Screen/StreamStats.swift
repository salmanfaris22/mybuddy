import Foundation

/// One W3C webrtc-stats object reduced to plain values, so the parsing below is testable without libwebrtc.
public struct RTCStatsEntry: Sendable, Equatable {
    public enum Value: Sendable, Equatable {
        case number(Double)
        case string(String)
    }

    public let id: String
    public let type: String
    public let timestampUs: Double
    public let values: [String: Value]

    public init(id: String, type: String, timestampUs: Double, values: [String: Value]) {
        self.id = id
        self.type = type
        self.timestampUs = timestampUs
        self.values = values
    }

    func number(_ key: String) -> Double? {
        if case .number(let n)? = values[key] { return n }
        return nil
    }

    func string(_ key: String) -> String? {
        if case .string(let s)? = values[key] { return s }
        return nil
    }
}

/// Whether media flows host-to-host or through a TURN relay — read from the selected ICE pair, never guessed.
public enum MediaPath: String, Sendable, Equatable {
    case direct, relayed, unknown
}

/// A one-second view of a video stream, measured by WebRTC.
public struct StreamStatsSample: Sendable, Equatable {
    public var framesPerSecond: Double?
    public var bitrateKbps: Double?
    public var dimensions: StreamDimensions?
    /// e.g. "H264", "VP8" (from the negotiated codec's MIME type).
    public var codec: String?
    /// e.g. "VideoToolbox" — what libwebrtc reports as the encoder/decoder implementation.
    public var implementation: String?
    public var hardwareAccelerated: Bool?
    public var roundTripMs: Double?
    public var path: MediaPath = .unknown
    public var localCandidateType: String?
    public var remoteCandidateType: String?
    public var qualityLimitation: QualityLimitation?
    public var availableOutgoingBitrateBps: Double?
    public var packetsLost: Int?

    public init() {}
}

/// Turns successive `getStats()` reports into samples. Keeps the previous byte counter to compute the
/// bitrate over the real interval between reports.
public struct StreamStatsParser: Sendable {
    public enum Direction: Sendable { case outbound, inbound }

    public let direction: Direction
    private var lastBytes: Double?
    private var lastTimestampUs: Double?

    public init(direction: Direction) { self.direction = direction }

    public mutating func sample(_ entries: [RTCStatsEntry]) -> StreamStatsSample {
        var s = StreamStatsSample()
        let byId = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let rtpType = direction == .outbound ? "outbound-rtp" : "inbound-rtp"
        let rtp = entries.filter { $0.type == rtpType && ($0.string("kind") ?? $0.string("mediaType")) == "video" }
            .max { ($0.number(direction == .outbound ? "bytesSent" : "bytesReceived") ?? 0) < ($1.number(direction == .outbound ? "bytesSent" : "bytesReceived") ?? 0) }
        if let rtp {
            s.framesPerSecond = rtp.number("framesPerSecond")
            if let w = rtp.number("frameWidth"), let h = rtp.number("frameHeight"), w > 0, h > 0 {
                s.dimensions = StreamDimensions(width: Int(w), height: Int(h))
            }
            let bytes = rtp.number(direction == .outbound ? "bytesSent" : "bytesReceived")
            if let bytes, let lastBytes, let lastTimestampUs, rtp.timestampUs > lastTimestampUs, bytes >= lastBytes {
                s.bitrateKbps = (bytes - lastBytes) * 8 / ((rtp.timestampUs - lastTimestampUs) / 1_000_000) / 1000
            }
            lastBytes = bytes
            lastTimestampUs = rtp.timestampUs
            if let codecId = rtp.string("codecId"), let mime = byId[codecId]?.string("mimeType") {
                s.codec = mime.split(separator: "/").last.map(String.init)
            }
            switch direction {
            case .outbound:
                s.implementation = rtp.string("encoderImplementation")
                s.hardwareAccelerated = rtp.number("powerEfficientEncoder").map { $0 != 0 }
                s.qualityLimitation = rtp.string("qualityLimitationReason").map { QualityLimitation(rawValue: $0) ?? .other }
            case .inbound:
                s.implementation = rtp.string("decoderImplementation")
                s.hardwareAccelerated = rtp.number("powerEfficientDecoder").map { $0 != 0 }
                s.packetsLost = rtp.number("packetsLost").map { Int($0) }
            }
        }
        if let pair = selectedPair(entries, byId: byId) {
            s.roundTripMs = pair.number("currentRoundTripTime").map { $0 * 1000 }
            s.availableOutgoingBitrateBps = pair.number("availableOutgoingBitrate")
            s.localCandidateType = pair.string("localCandidateId").flatMap { byId[$0]?.string("candidateType") }
            s.remoteCandidateType = pair.string("remoteCandidateId").flatMap { byId[$0]?.string("candidateType") }
            if s.localCandidateType == nil && s.remoteCandidateType == nil {
                s.path = .unknown
            } else {
                s.path = (s.localCandidateType == "relay" || s.remoteCandidateType == "relay") ? .relayed : .direct
            }
        }
        if s.roundTripMs == nil, direction == .outbound,
           let remote = entries.first(where: { $0.type == "remote-inbound-rtp" && $0.string("kind") == "video" }) {
            s.roundTripMs = remote.number("roundTripTime").map { $0 * 1000 }
        }
        return s
    }

    private func selectedPair(_ entries: [RTCStatsEntry], byId: [String: RTCStatsEntry]) -> RTCStatsEntry? {
        if let id = entries.first(where: { $0.type == "transport" && $0.string("selectedCandidatePairId") != nil })?.string("selectedCandidatePairId"),
           let pair = byId[id] {
            return pair
        }
        return entries.first { $0.type == "candidate-pair" && $0.string("state") == "succeeded" && $0.number("nominated") == 1 }
    }
}
