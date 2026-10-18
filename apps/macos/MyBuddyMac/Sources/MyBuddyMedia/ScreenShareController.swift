import AppKit
import Foundation
@preconcurrency import LiveKitWebRTC
import MyBuddyCore
import MyBuddyHost

/// A STUN/TURN server for internet mode (LAN streaming needs none).
public struct ICEServerConfig: Sendable, Equatable {
    public var urls: [String]
    public var username: String?
    public var credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }
}

public struct ScreenShareOptions: Sendable {
    public var iceServers: [ICEServerConfig] = []
    /// STUN/TURN servers for one session (internet sessions through MyBuddy Connect); nil → `iceServers`.
    public var iceProvider: (@Sendable (_ sessionId: String) async -> [ICEServerConfig])?
    /// Where an `auto` stream starts for a session: `high` on direct paths (the default), `balanced` when relayed.
    public var autoStartTier: (@Sendable (_ sessionId: String) -> StreamTier)?
    /// Test-only (interop host + Android emulator): gather loopback candidates and advertise them under
    /// this address (the emulator reaches the host's 127.0.0.1 as 10.0.2.2).
    public var loopbackAlias: String?
    public init() {}
}

/// Where remote input for the streaming session should land.
public struct InputTarget: Sendable, Equatable {
    public let sessionId: String
    public let displayId: String?
    public let source: StreamSourceKind
}

/// What the Mac UI shows about the current screen share.
public struct ScreenShareSnapshot: Sendable, Equatable {
    public var status: ScreenStreamStatus
    public var sessionId: String
    public var deviceName: String
    public var startedAt: Date
    public var stats: StreamStatsSample?
}

/// Runs one screen stream at a time for an authorized session: capture → WebRTC (H.264) → the phone.
///
/// Signaling (`webrtc.offer/answer/ice`) travels inside the MBH1 session, so the DTLS fingerprints in the
/// SDP — and with them the media and its encryption keys — are bound to the authenticated phone.
/// The Mac is the offerer because it owns the media. Capability checks (`screen.view`) happen in the
/// LAN host before anything reaches this type; Screen Recording permission is checked here.
public actor ScreenShareController {
    public typealias Send = @Sendable (OutgoingEvent, _ sessionId: String) -> Void

    private let options: ScreenShareOptions
    private let permission: @Sendable () -> Bool
    private let makeSource: @Sendable () -> any FrameSource
    private let send: Send
    private let onSnapshot: @Sendable (ScreenShareSnapshot?) -> Void
    private let log: @Sendable (String) -> Void
    private let authorizeInput: @Sendable (String) -> Bool
    private let onInput: @Sendable (Envelope, InputTarget) -> Void
    private let onInputEnded: @Sendable () -> Void
    private let preview = PreviewHub()
    private let target = TargetBox()
    private var stream: ActiveStream?
    private var generation = 0

    public init(options: ScreenShareOptions = ScreenShareOptions(),
                permission: @escaping @Sendable () -> Bool,
                makeSource: @escaping @Sendable () -> any FrameSource,
                send: @escaping Send,
                onSnapshot: @escaping @Sendable (ScreenShareSnapshot?) -> Void = { _ in },
                log: @escaping @Sendable (String) -> Void = { _ in },
                authorizeInput: @escaping @Sendable (String) -> Bool = { _ in false },
                onInput: @escaping @Sendable (Envelope, InputTarget) -> Void = { _, _ in },
                onInputEnded: @escaping @Sendable () -> Void = {}) {
        self.options = options
        self.permission = permission
        self.makeSource = makeSource
        self.send = send
        self.onSnapshot = onSnapshot
        self.log = log
        self.authorizeInput = authorizeInput
        self.onInput = onInput
        self.onInputEnded = onInputEnded
        if options.loopbackAlias != nil { WebRTCEngine.configure(allowLoopback: true) }
    }

    /// Handles `screen.*` and `webrtc.*` from an authorized session. Replies that answer the request are
    /// returned; later state changes are pushed through `send`.
    public func handle(_ e: Envelope, deviceName: String) async -> [OutgoingEvent] {
        switch e.type {
        case .screenStart: return await start(e, deviceName: deviceName)
        case .screenUpdate: return await update(e)
        case .screenStop:
            guard let s = stream, s.sessionId == e.sessionId else {
                return [Self.state(ScreenStreamStatus(phase: .stopped, reason: ScreenStreamReason.user), replyTo: e.sequence)]
            }
            let reason = e.payload["reason"]?.stringValue == "background" ? ScreenStreamReason.background : ScreenStreamReason.user
            await teardown(s)
            log("stream stopped by the phone (\(reason))")
            return [Self.state(ScreenStreamStatus(phase: .stopped, reason: reason, quality: s.quality), replyTo: e.sequence)]
        case .webrtcAnswer: return await answer(e)
        case .webrtcIce: return await remoteCandidate(e)
        default: return []
        }
    }

    /// The session ended (disconnect, revoke, emergency stop): stop without notifying (nobody to tell).
    public func sessionEnded(_ sessionId: String) async {
        guard let s = stream, s.sessionId == sessionId else { return }
        await teardown(s)
        log("stream ended with the session")
    }

    /// Stop from the Mac (UI button or emergency stop); the phone is told why.
    public func stopFromMac(emergency: Bool = false) async {
        guard let s = stream else { return }
        let reason = emergency ? ScreenStreamReason.emergencyStop : ScreenStreamReason.stoppedOnMac
        send(Self.state(ScreenStreamStatus(phase: .stopped, reason: reason, message: "Screen sharing was stopped on the Mac.", quality: s.quality)), s.sessionId)
        await teardown(s)
        log("stream stopped on the Mac (\(reason))")
    }

    public var isStreaming: Bool { stream != nil }

    /// Where `sessionId`'s input should land while it is viewing the screen (thread-safe; nil when not streaming).
    public nonisolated func inputTarget(for sessionId: String) -> InputTarget? {
        target.current.flatMap { $0.sessionId == sessionId ? $0 : nil }
    }

    /// Re-plans the capture (e.g. after the system picker changed what is shared on the Mac).
    public func refreshSource() async {
        guard let s = stream, s.info != nil else { return }
        await reconfigure(s, reason: "source_changed")
    }

    // MARK: Preview (the Mac shows exactly what is being sent)

    /// A view that renders the outgoing stream. Release it with `releasePreviewView(_:)`.
    @MainActor public func makePreviewView() -> NSView {
        let view = LKRTCMTLVideoView(frame: .zero)
        preview.add(view)
        return view
    }

    @MainActor public func releasePreviewView(_ view: NSView) {
        if let renderer = view as? LKRTCMTLVideoView { preview.remove(renderer) }
    }

    // MARK: Start

    private func start(_ e: Envelope, deviceName: String) async -> [OutgoingEvent] {
        let quality = e.payload["quality"]?.stringValue.flatMap(StreamQuality.init(rawValue:)) ?? .auto
        let maxFps = e.payload["maxFps"]?.intValue.map { Int($0) }
        let displayId = e.payload["displayId"]?.stringValue
        if let current = stream, current.sessionId != e.sessionId {
            return [Self.state(ScreenStreamStatus(phase: .failed, reason: ScreenStreamReason.busy,
                                                  message: "\(current.deviceName) is already viewing this Mac."), replyTo: e.sequence)]
        }
        guard permission() else {
            log("refused: Screen Recording not allowed")
            return [Self.state(ScreenStreamStatus(phase: .failed, reason: ScreenStreamReason.notAuthorized,
                                                  message: "Allow Screen Recording for MyBuddy on your Mac: System Settings → Privacy & Security → Screen & System Audio Recording."),
                               replyTo: e.sequence)]
        }
        if let current = stream { await teardown(current) }  // the same phone restarting

        generation += 1
        let s = ActiveStream(generation: generation, sessionId: e.sessionId, deviceName: deviceName, quality: quality,
                             maxFps: maxFps, displayId: displayId, source: makeSource(),
                             autoStartTier: options.autoStartTier?(e.sessionId) ?? .high)
        stream = s
        send(Self.state(s.status, replyTo: e.sequence), s.sessionId)
        publish()
        log("stream requested by \(deviceName) (quality \(quality.rawValue))")
        do {
            try await bringUp(s)
        } catch let error as FrameSourceError {
            let reason = switch error {
            case .notAuthorized: ScreenStreamReason.notAuthorized
            case .noDisplay: ScreenStreamReason.noDisplay
            case .failed: ScreenStreamReason.captureFailed
            }
            await fail(s, reason: reason, message: error.description)
        } catch {
            await fail(s, reason: ScreenStreamReason.negotiationFailed, message: "Couldn’t set up the video connection (\(error)).")
        }
        return []
    }

    private func bringUp(_ s: ActiveStream) async throws {
        let engine = WebRTCEngine.shared
        let videoSource = engine.factory.videoSource(forScreenCast: true)
        let sink = FrameSink(source: videoSource)
        let track = engine.factory.videoTrack(with: videoSource, trackId: "mybuddy-screen-\(s.generation)")
        s.track = track
        let gen = s.generation

        let info = try await s.source.start(s.request, onFrame: { frame in sink.push(frame) },
                                            onStop: { [weak self] message in Task { await self?.captureStopped(gen, message) } })
        guard isCurrent(s) else { return await s.source.stop() }
        s.info = info
        s.status = ScreenStreamStatus(phase: .starting, quality: s.quality, tier: s.adaptive.tier, displayId: info.displayId,
                                      dimensions: info.dimensions, fps: info.fps, source: info.source, displays: info.displays)
        preview.setTrack(track)
        target.current = InputTarget(sessionId: s.sessionId, displayId: info.displayId, source: info.source)

        let observer = PeerObserver(generation: gen, sessionId: s.sessionId, send: send, loopbackAlias: options.loopbackAlias) { [weak self] g, state in
            Task { await self?.connectionChanged(g, state) }
        }
        observer.onLog = log
        s.observer = observer
        let config = LKRTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherOnce
        config.keyType = .ECDSA
        let servers = await options.iceProvider?(s.sessionId) ?? options.iceServers
        config.iceServers = servers.map { LKRTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        guard let pc = engine.factory.peerConnection(with: config, constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
                                                     delegate: observer)
        else { throw MediaError.negotiation("Couldn’t create the peer connection.") }
        s.pc = pc

        let initial = LKRTCRtpTransceiverInit()
        initial.direction = .sendOnly
        initial.streamIds = ["mybuddy-screen"]
        guard let transceiver = pc.addTransceiver(with: track, init: initial) else { throw MediaError.negotiation("Couldn’t add the video track.") }
        // Remote input rides the same DTLS connection: unordered/lossy for pointer moves, reliable for the rest.
        let inputObserver = InputChannelObserver(sessionId: s.sessionId, authorize: authorizeInput, target: target, onInput: onInput) { [weak self] line in
            self?.log(line)
        }
        for channel in InputDataChannel.allCases {
            let config = LKRTCDataChannelConfiguration()
            config.isOrdered = channel == .reliable
            if channel == .pointer { config.maxRetransmits = 0 }
            if let dc = pc.dataChannel(forLabel: channel.rawValue, configuration: config) {
                dc.delegate = inputObserver
                s.dataChannels.append(dc)
            }
        }
        s.inputObserver = inputObserver
        // Preference order is a request; the phone's answer decides. The negotiated codec is shown from stats.
        try? transceiver.setCodecPreferences(engine.preferredVideoCodecs(), error: ())
        s.sender = transceiver.sender
        applyEncoding(s)

        let offer = try await pc.makeOffer(iceRestart: false)
        guard isCurrent(s) else { return }
        try await pc.applyLocal(type: .offer, sdp: offer)
        guard isCurrent(s) else { return }
        send(OutgoingEvent(.webrtcOffer, ["sdp": .string(offer)]), s.sessionId)
        publish()
        log("offer sent (\(info.dimensions) @ \(info.fps) fps, \(info.source.rawValue))")
        startStats(s)
    }

    /// Bitrate / frame-rate caps for the current tier. Screen content keeps its resolution (text must stay
    /// legible) and gives up frame rate first under pressure.
    private func applyEncoding(_ s: ActiveStream) {
        guard let sender = s.sender else { return }
        let parameters = sender.parameters
        for encoding in parameters.encodings {
            encoding.maxBitrateBps = NSNumber(value: s.adaptive.tier.maxBitrateBps)
            encoding.maxFramerate = NSNumber(value: StreamGeometry.fps(tier: s.adaptive.tier, maxFps: s.maxFps))
        }
        // Smooth keeps its 60 fps and gives up resolution under load; the others balance both, so pressure no longer
        // turns the picture into a slideshow (the old "maintain resolution" dropped frame rate first).
        let preference: LKRTCDegradationPreference = s.adaptive.tier == .smooth ? .maintainFramerate : .balanced
        parameters.degradationPreference = NSNumber(value: preference.rawValue)
        sender.parameters = parameters
    }

    // MARK: Signaling from the phone

    private func answer(_ e: Envelope) async -> [OutgoingEvent] {
        guard let s = stream, s.sessionId == e.sessionId, let pc = s.pc, pc.signalingState == .haveLocalOffer,
              let sdp = e.payload["sdp"]?.stringValue
        else { return [Self.error("unexpected_answer", "No video offer is waiting for an answer.", e)] }
        do {
            try await pc.applyRemote(type: .answer, sdp: sdp)
        } catch {
            await fail(s, reason: ScreenStreamReason.negotiationFailed, message: "The phone’s video answer was not accepted.")
            return []
        }
        guard isCurrent(s) else { return [] }
        let pending = s.pendingCandidates
        s.pendingCandidates = []
        for c in pending { try? await pc.addCandidate(sdp: c.sdp, mLineIndex: c.mLineIndex, mid: c.mid) }
        log("answer applied")
        return []
    }

    private func remoteCandidate(_ e: Envelope) async -> [OutgoingEvent] {
        guard let s = stream, s.sessionId == e.sessionId, let pc = s.pc else { return [] }
        if e.payload["endOfCandidates"]?.boolValue == true { return [] }
        guard let sdp = e.payload["candidate"]?.stringValue, !sdp.isEmpty else { return [] }
        let candidate = PendingCandidate(sdp: sdp, mLineIndex: Int32(e.payload["sdpMLineIndex"]?.intValue ?? 0), mid: e.payload["sdpMid"]?.stringValue)
        if pc.signalingState == .haveLocalOffer || pc.remoteDescription == nil {
            if s.pendingCandidates.count < 64 { s.pendingCandidates.append(candidate) }
            return []
        }
        try? await pc.addCandidate(sdp: candidate.sdp, mLineIndex: candidate.mLineIndex, mid: candidate.mid)
        return []
    }

    // MARK: Changes while streaming

    private func update(_ e: Envelope) async -> [OutgoingEvent] {
        guard let s = stream, s.sessionId == e.sessionId, s.info != nil else {
            return [Self.error("not_streaming", "Start viewing the screen first.", e)]
        }
        if let q = e.payload["quality"]?.stringValue.flatMap(StreamQuality.init(rawValue:)) { s.reset(quality: q) }
        if let fps = e.payload["maxFps"]?.intValue { s.maxFps = Int(fps) }
        if let id = e.payload["displayId"]?.stringValue { s.displayId = id }
        await reconfigure(s, reason: ScreenStreamReason.qualityChanged)
        return []
    }

    private func reconfigure(_ s: ActiveStream, reason: String) async {
        do {
            let info = try await s.source.reconfigure(s.request)
            guard isCurrent(s) else { return }
            s.info = info
            target.current = InputTarget(sessionId: s.sessionId, displayId: info.displayId, source: info.source)
            applyEncoding(s)
            s.status.quality = s.quality
            s.status.tier = s.adaptive.tier
            s.status.displayId = info.displayId
            s.status.dimensions = info.dimensions
            s.status.fps = info.fps
            s.status.source = info.source
            s.status.displays = info.displays
            if s.status.phase == .live {
                var pushed = s.status
                pushed.reason = reason
                send(Self.state(pushed), s.sessionId)
            }
            publish()
            log("reconfigured: \(info.dimensions) @ \(info.fps) fps, tier \(s.adaptive.tier.rawValue)")
        } catch {
            await fail(s, reason: ScreenStreamReason.captureFailed, message: "Couldn’t change the stream (\(error)).")
        }
    }

    // MARK: Connection + stats

    fileprivate func connectionChanged(_ gen: Int, _ state: LKRTCPeerConnectionState) async {
        guard let s = stream, s.generation == gen else { return }
        switch state {
        case .connected:
            s.disconnectedAt = nil
            if s.status.phase != .live {
                s.status.phase = .live
                s.status.reason = nil
                send(Self.state(s.status), s.sessionId)
                publish()
                log("live")
            }
        case .disconnected:
            s.disconnectedAt = Date()
            let token = s.disconnectedAt
            Task {
                try? await Task.sleep(for: .seconds(6))
                await self.restartIfStillDisconnected(gen, since: token)
            }
        case .failed:
            await restartIce(s)
        default:
            break
        }
    }

    private func restartIfStillDisconnected(_ gen: Int, since: Date?) async {
        guard let s = stream, s.generation == gen, s.disconnectedAt != nil, s.disconnectedAt == since else { return }
        await restartIce(s)
    }

    /// Recovers a broken path with an ICE restart (new offer over the same MBH1 session), twice at most.
    private func restartIce(_ s: ActiveStream) async {
        guard let pc = s.pc, isCurrent(s) else { return }
        guard s.iceRestarts < 2 else {
            return await fail(s, reason: ScreenStreamReason.connectionFailed, message: "The video connection to the phone was lost.")
        }
        s.iceRestarts += 1
        log("ICE restart \(s.iceRestarts)")
        do {
            let offer = try await pc.makeOffer(iceRestart: true)
            guard isCurrent(s) else { return }
            try await pc.applyLocal(type: .offer, sdp: offer)
            guard isCurrent(s) else { return }
            send(OutgoingEvent(.webrtcOffer, ["sdp": .string(offer)]), s.sessionId)
        } catch {
            await fail(s, reason: ScreenStreamReason.connectionFailed, message: "The video connection to the phone was lost.")
        }
    }

    private func startStats(_ s: ActiveStream) {
        let gen = s.generation
        s.statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, await self.sampleStats(gen) else { return }
            }
        }
    }

    /// One stats tick: updates the Mac UI and lets `auto` quality move between tiers. Returns false once
    /// the stream is gone.
    private func sampleStats(_ gen: Int) async -> Bool {
        guard let s = stream, s.generation == gen, let pc = s.pc else { return false }
        let entries = await pc.statsEntries()
        guard isCurrent(s) else { return false }
        let sample = s.parser.sample(entries)
        s.stats = sample
        publish()
        if s.status.phase == .live,
           let tier = s.adaptive.observe(limitation: sample.qualityLimitation ?? .none, availableOutgoingBitrateBps: sample.availableOutgoingBitrateBps) {
            log("adaptive quality → \(tier.rawValue) (\(sample.qualityLimitation?.rawValue ?? "none"))")
            await reconfigure(s, reason: ScreenStreamReason.qualityChanged)
        }
        return true
    }

    // MARK: Failure + teardown

    private func captureStopped(_ gen: Int, _ message: String) async {
        guard let s = stream, s.generation == gen else { return }
        await fail(s, reason: ScreenStreamReason.captureStopped, message: message)
    }

    private func fail(_ s: ActiveStream, reason: String, message: String) async {
        guard isCurrent(s) else { return }
        send(Self.state(ScreenStreamStatus(phase: .failed, reason: reason, message: message, quality: s.quality)), s.sessionId)
        await teardown(s)
        log("stream failed: \(reason) — \(message)")
    }

    private func teardown(_ s: ActiveStream) async {
        if stream === s {
            stream = nil
            target.current = nil
        }
        s.statsTask?.cancel()
        s.observer?.invalidate()
        s.inputObserver?.invalidate()
        s.dataChannels.forEach { $0.close() }
        s.dataChannels = []
        // Nothing may stay pressed once the input channels are gone.
        if s.inputObserver?.receivedInput == true { onInputEnded() }
        preview.setTrack(nil)
        s.pc?.close()
        s.pc = nil
        await s.source.stop()
        publish()
    }

    private func isCurrent(_ s: ActiveStream) -> Bool { stream === s }

    private func publish() {
        guard let s = stream else { return onSnapshot(nil) }
        onSnapshot(ScreenShareSnapshot(status: s.status, sessionId: s.sessionId, deviceName: s.deviceName, startedAt: s.startedAt, stats: s.stats))
    }

    static func state(_ status: ScreenStreamStatus, replyTo: Int64? = nil) -> OutgoingEvent {
        OutgoingEvent(.screenState, status.payload, replyTo: replyTo)
    }

    static func error(_ code: String, _ message: String, _ e: Envelope) -> OutgoingEvent {
        OutgoingEvent(.error, ["code": .string(code), "message": .string(message), "retryable": .bool(false)], replyTo: e.sequence)
    }
}

struct PendingCandidate: Sendable {
    let sdp: String
    let mLineIndex: Int32
    let mid: String?
}

/// State of the one active stream. Only touched from the controller actor.
final class ActiveStream {
    let generation: Int
    let sessionId: String
    let deviceName: String
    let source: any FrameSource
    let startedAt = Date()
    private(set) var quality: StreamQuality
    var adaptive: AdaptiveQualityController
    var maxFps: Int?
    var displayId: String?
    var status: ScreenStreamStatus
    var info: FrameSourceInfo?
    var stats: StreamStatsSample?
    var parser = StreamStatsParser(direction: .outbound)
    var track: LKRTCVideoTrack?
    var pc: LKRTCPeerConnection?
    var sender: LKRTCRtpSender?
    var observer: PeerObserver?
    var inputObserver: InputChannelObserver?
    var dataChannels: [LKRTCDataChannel] = []
    var pendingCandidates: [PendingCandidate] = []
    var statsTask: Task<Void, Never>?
    var iceRestarts = 0
    var disconnectedAt: Date?

    let autoStartTier: StreamTier

    init(generation: Int, sessionId: String, deviceName: String, quality: StreamQuality, maxFps: Int?, displayId: String?, source: any FrameSource,
         autoStartTier: StreamTier = .high) {
        self.generation = generation
        self.sessionId = sessionId
        self.deviceName = deviceName
        self.quality = quality
        self.maxFps = maxFps
        self.displayId = displayId
        self.source = source
        self.autoStartTier = autoStartTier
        adaptive = AdaptiveQualityController(quality: quality, startTier: autoStartTier)
        status = ScreenStreamStatus(phase: .starting, quality: quality)
    }

    var request: FrameSourceRequest { FrameSourceRequest(displayId: displayId, tier: adaptive.tier, maxFps: maxFps) }

    func reset(quality: StreamQuality) {
        self.quality = quality
        adaptive = AdaptiveQualityController(quality: quality, startTier: autoStartTier)
    }
}

/// Pushes captured frames into libwebrtc (thread-safe; called on the capture queue).
final class FrameSink: @unchecked Sendable {
    private let source: LKRTCVideoSource
    private let capturer: LKRTCVideoCapturer

    init(source: LKRTCVideoSource) {
        self.source = source
        capturer = LKRTCVideoCapturer(delegate: source)
    }

    func push(_ frame: CapturedFrame) {
        let buffer = LKRTCCVPixelBuffer(pixelBuffer: frame.pixelBuffer)
        source.capturer(capturer, didCapture: LKRTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: frame.timestampNs))
    }
}

/// Peer-connection callbacks (libwebrtc's signaling thread). Local ICE candidates are sent from here,
/// directly and in order; state changes hop to the controller actor.
final class PeerObserver: NSObject, LKRTCPeerConnectionDelegate, @unchecked Sendable {
    private let generation: Int
    private let sessionId: String
    private let send: ScreenShareController.Send
    private let loopbackAlias: String?
    private let onState: @Sendable (Int, LKRTCPeerConnectionState) -> Void
    /// Diagnostics only (ICE state names).
    var onLog: (@Sendable (String) -> Void)?
    private let lock = NSLock()
    private var valid = true

    init(generation: Int, sessionId: String, send: @escaping ScreenShareController.Send, loopbackAlias: String?,
         onState: @escaping @Sendable (Int, LKRTCPeerConnectionState) -> Void) {
        self.generation = generation
        self.sessionId = sessionId
        self.send = send
        self.loopbackAlias = loopbackAlias
        self.onState = onState
    }

    func invalidate() { lock.withLock { valid = false } }
    private var isValid: Bool { lock.withLock { valid } }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        guard isValid else { return }
        var sdp = candidate.sdp
        if let alias = loopbackAlias {
            // Test-only: the emulator reaches the host's loopback through its NAT alias.
            sdp = sdp.replacingOccurrences(of: " 127.0.0.1 ", with: " \(alias) ")
        }
        var payload: [String: JSONValue] = ["candidate": .string(sdp), "sdpMLineIndex": .int(Int64(candidate.sdpMLineIndex))]
        if let mid = candidate.sdpMid { payload["sdpMid"] = .string(mid) }
        send(OutgoingEvent(.webrtcIce, payload), sessionId)
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {
        guard isValid, newState == .complete else { return }
        send(OutgoingEvent(.webrtcIce, ["endOfCandidates": .bool(true)]), sessionId)
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) {
        guard isValid else { return }
        onState(generation, newState)
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        guard isValid else { return }
        let name = switch newState {
        case .new: "new"
        case .checking: "checking"
        case .connected: "connected"
        case .completed: "completed"
        case .failed: "failed"
        case .disconnected: "disconnected"
        case .closed: "closed"
        case .count: "count"
        @unknown default: "unknown"
        }
        onLog?("ICE \(name)")
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {
        // Only the channels this Mac created carry input; anything the phone opens is refused.
        dataChannel.close()
    }
}

/// The current input target, readable from any thread.
final class TargetBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: InputTarget?
    var current: InputTarget? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Input arriving on `mb-input` / `mb-input-rel` (libwebrtc's thread): validated by `DataChannelInputGate`,
/// authorized against the session's current grants, then handed to the host. Rejections are counted, never
/// executed.
final class InputChannelObserver: NSObject, LKRTCDataChannelDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var gate: DataChannelInputGate
    private var valid = true
    private var rejections = 0
    private var receivedAny = false
    /// True once any input was applied (then everything is released when the stream ends).
    var receivedInput: Bool { lock.withLock { receivedAny } }
    private let sessionId: String
    private let authorize: @Sendable (String) -> Bool
    private let target: TargetBox
    private let onInput: @Sendable (Envelope, InputTarget) -> Void
    private let log: @Sendable (String) -> Void

    init(sessionId: String, authorize: @escaping @Sendable (String) -> Bool, target: TargetBox,
         onInput: @escaping @Sendable (Envelope, InputTarget) -> Void, log: @escaping @Sendable (String) -> Void) {
        self.sessionId = sessionId
        gate = DataChannelInputGate(sessionId: sessionId)
        self.authorize = authorize
        self.target = target
        self.onInput = onInput
        self.log = log
    }

    func invalidate() { lock.withLock { valid = false } }

    func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        guard let channel = InputDataChannel(rawValue: dataChannel.label) else { return }
        let result: Result<Envelope, DataChannelInputGate.Rejection>? = lock.withLock {
            guard valid else { return nil }
            return gate.accept(buffer.data, on: channel)
        }
        switch result {
        case .success(let envelope)?:
            guard authorize(sessionId), let target = target.current, target.sessionId == sessionId else {
                return reject("not authorized")
            }
            lock.withLock { receivedAny = true }
            onInput(envelope, target)
        case .failure(let why)?:
            reject("\(why)")
        case nil:
            break
        }
    }

    private func reject(_ why: String) {
        let count = lock.withLock { () -> Int in
            rejections += 1
            return rejections
        }
        if count == 1 || count % 100 == 0 { log("input rejected on a data channel (\(why)); \(count) so far") }
    }

    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        if dataChannel.readyState == .open { log("input channel \(dataChannel.label) open") }
    }
}

/// Renderers that mirror the outgoing track on the Mac (thread-safe).
final class PreviewHub: @unchecked Sendable {
    private let lock = NSLock()
    private var track: LKRTCVideoTrack?
    private var renderers: [ObjectIdentifier: any LKRTCVideoRenderer] = [:]

    func setTrack(_ new: LKRTCVideoTrack?) {
        let (old, all) = lock.withLock { () -> (LKRTCVideoTrack?, [any LKRTCVideoRenderer]) in
            defer { track = new }
            return (track, Array(renderers.values))
        }
        for r in all {
            old?.remove(r)
            new?.add(r)
        }
    }

    func add(_ renderer: any LKRTCVideoRenderer) {
        let current = lock.withLock { () -> LKRTCVideoTrack? in
            renderers[ObjectIdentifier(renderer)] = renderer
            return track
        }
        current?.add(renderer)
    }

    func remove(_ renderer: any LKRTCVideoRenderer) {
        let current = lock.withLock { () -> LKRTCVideoTrack? in
            renderers[ObjectIdentifier(renderer)] = nil
            return track
        }
        current?.remove(renderer)
    }
}
