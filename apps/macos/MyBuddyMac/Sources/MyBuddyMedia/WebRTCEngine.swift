import Foundation
@preconcurrency import LiveKitWebRTC
import MyBuddyCore

/// The process-wide libwebrtc factory (creating one is expensive). Video only: no audio track is ever
/// created, so the microphone is never opened.
final class WebRTCEngine: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var allowLoopback = false
    nonisolated(unsafe) private static var instance: WebRTCEngine?

    let factory: LKRTCPeerConnectionFactory

    /// Test-only (interop host): also gather loopback candidates. Must be called before first use.
    static func configure(allowLoopback: Bool) {
        lock.withLock { Self.allowLoopback = allowLoopback }
    }

    static var shared: WebRTCEngine {
        lock.withLock {
            if let instance { return instance }
            let engine = WebRTCEngine(allowLoopback: allowLoopback)
            instance = engine
            return engine
        }
    }

    private init(allowLoopback: Bool) {
        LKRTCInitializeSSL()
        factory = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(), decoderFactory: LKRTCDefaultVideoDecoderFactory())
        // Ask for errors only. Note: in this M150 build stderr output follows libwebrtc's one-time internal
        // LoggingConfig (info level) and ignores this legacy setter, so info lines (with partly masked
        // addresses) still reach stderr. A Finder-launched app's stderr is not persisted; the interop host
        // and tests send it to a separate file.
        LKRTCSetMinDebugLogLevel(.error)
        if allowLoopback {
            let options = LKRTCPeerConnectionFactoryOptions()
            options.ignoreLoopbackNetworkAdapter = false
            factory.setOptions(options)
        }
    }

    /// Video codecs in preference order: H.264 (hardware VideoToolbox on Apple silicon) first — High,
    /// then Constrained Baseline, packetization-mode 1 — then everything else as fallback (VP8, VP9, AV1,
    /// plus RTX/RED/ULPFEC so retransmission and FEC keep working).
    func preferredVideoCodecs() -> [LKRTCRtpCodecCapability] {
        let codecs = factory.rtpSenderCapabilities(forKind: "video").codecs
        func rank(_ c: LKRTCRtpCodecCapability) -> Int {
            guard c.name.uppercased() == "H264" else { return 100 }
            let mode1 = c.parameters["packetization-mode"] == "1"
            let profile = (c.parameters["profile-level-id"] ?? "").lowercased()
            switch (mode1, profile.prefix(4)) {
            case (true, "640c"): return 0
            case (true, "42e0"): return 1
            case (true, _): return 2
            default: return 10
            }
        }
        return codecs.enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    static func entries(_ report: LKRTCStatisticsReport) -> [RTCStatsEntry] {
        report.statistics.values.map { s in
            var values: [String: RTCStatsEntry.Value] = [:]
            for (key, value) in s.values {
                if let n = value as? NSNumber {
                    values[key] = .number(n.doubleValue)
                } else if let str = value as? String {
                    values[key] = .string(str)
                }
            }
            return RTCStatsEntry(id: s.id, type: s.type, timestampUs: s.timestamp_us, values: values)
        }
    }
}

enum MediaError: Error, CustomStringConvertible {
    case negotiation(String)

    var description: String {
        switch self {
        case .negotiation(let why): why
        }
    }
}

/// async wrappers around libwebrtc's completion-handler API. Only Sendable values cross threads.
extension LKRTCPeerConnection {
    func makeOffer(iceRestart: Bool) async throws -> String {
        let mandatory = iceRestart ? [kLKRTCMediaConstraintsIceRestart: kLKRTCMediaConstraintsValueTrue] : [:]
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: mandatory, optionalConstraints: nil)
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, any Error>) in
            offer(for: constraints) { sdp, error in
                if let sdp { c.resume(returning: sdp.sdp) } else { c.resume(throwing: error ?? MediaError.negotiation("no offer")) }
            }
        }
    }

    func makeAnswer() async throws -> String {
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, any Error>) in
            answer(for: constraints) { sdp, error in
                if let sdp { c.resume(returning: sdp.sdp) } else { c.resume(throwing: error ?? MediaError.negotiation("no answer")) }
            }
        }
    }

    func applyLocal(type: LKRTCSdpType, sdp: String) async throws {
        let description = LKRTCSessionDescription(type: type, sdp: sdp)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            setLocalDescription(description) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    func applyRemote(type: LKRTCSdpType, sdp: String) async throws {
        let description = LKRTCSessionDescription(type: type, sdp: sdp)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            setRemoteDescription(description) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    func addCandidate(sdp: String, mLineIndex: Int32, mid: String?) async throws {
        let candidate = LKRTCIceCandidate(sdp: sdp, sdpMLineIndex: mLineIndex, sdpMid: mid)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            add(candidate) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    func statsEntries() async -> [RTCStatsEntry] {
        await withCheckedContinuation { (c: CheckedContinuation<[RTCStatsEntry], Never>) in
            statistics { report in c.resume(returning: WebRTCEngine.entries(report)) }
        }
    }
}
