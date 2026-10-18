import CoreGraphics
import Foundation
@preconcurrency import LiveKitWebRTC
import MyBuddyCore
import MyBuddyHost
@testable import MyBuddyMedia
import MyBuddyTestSupport
import Testing

/// Live, in-process WebRTC: the real `ScreenShareController` (test-pattern frames → VideoToolbox H.264)
/// streams over loopback to a minimal libwebrtc "phone" that answers, decodes and counts frames.
/// Proves the media engine, negotiation, ICE, encode and decode on this Mac without any permission
/// prompt (no screen capture, no microphone).
@Suite("Screen share (live WebRTC loopback)", .serialized)
struct ScreenShareLoopbackTests {
    static let session = "s_loopback0001"

    static func env(_ type: EventType, _ payload: [String: JSONValue], session: String = session, seq: Int64) -> Envelope {
        Envelope(type: type, sessionId: session, sequence: seq, sentAt: Date(), payload: payload)
    }

    @Test(.timeLimit(.minutes(1)))
    func streamsTestPatternAsH264AndFollowsQualityChanges() async throws {
        let phone = FakePhone()
        let (events, sink) = AsyncStream<OutgoingEvent>.makeStream()
        let snapshots = Recorder<ScreenShareSnapshot?>()
        var options = ScreenShareOptions()
        options.loopbackAlias = "127.0.0.1"
        let controller = ScreenShareController(options: options, permission: { true }, makeSource: { TestPatternSource() },
                                               send: { event, _ in sink.yield(event) }, onSnapshot: { snapshots.append($0) },
                                               log: { print("controller: \($0)") })
        let states = Recorder<[String: JSONValue]>()
        let seq = Counter()

        // The phone side of signaling.
        phone.onCandidate = { sdp, index, mid in
            var p: [String: JSONValue] = ["candidate": .string(sdp), "sdpMLineIndex": .int(Int64(index))]
            if let mid { p["sdpMid"] = .string(mid) }
            Task { _ = await controller.handle(Self.env(.webrtcIce, p, seq: seq.next()), deviceName: "Test phone") }
        }
        let pump = Task {
            for await event in events {
                switch event.type {
                case .webrtcOffer:
                    let answer: String
                    do { answer = try await phone.answer(offer: event.payload["sdp"]!.stringValue!) } catch { print("phone: answer failed \(error)"); continue }
                    _ = await controller.handle(Self.env(.webrtcAnswer, ["sdp": .string(answer)], seq: seq.next()), deviceName: "Test phone")
                case .webrtcIce:
                    if let c = event.payload["candidate"]?.stringValue {
                        try? await phone.add(candidate: c, index: Int32(event.payload["sdpMLineIndex"]?.intValue ?? 0), mid: event.payload["sdpMid"]?.stringValue)
                    }
                case .screenState:
                    states.append(event.payload)
                default:
                    break
                }
            }
        }
        defer { pump.cancel() }

        let replies = await controller.handle(Self.env(.screenStart, ["quality": .string("balanced")], seq: seq.next()), deviceName: "Test phone")
        #expect(replies.isEmpty, "state changes are pushed, not returned")
        #expect(await controller.isStreaming)

        try await waitUntil("live state + 15 decoded frames") { states.all.contains { $0["state"]?.stringValue == "live" } && phone.frameCount >= 15 }
        #expect(states.all.first?["state"]?.stringValue == "starting")
        let live = try #require(states.all.first { $0["state"]?.stringValue == "live" })
        #expect(live["width"]?.intValue == 1280 && live["height"]?.intValue == 800, "2560×1600 test pattern fitted to the balanced tier")
        #expect(live["source"]?.stringValue == "test_pattern")
        #expect(phone.lastSize == CGSize(width: 1280, height: 800))

        // What the phone actually negotiated and decoded, from its own stats.
        var inbound = StreamStatsParser(direction: .inbound)
        let received = inbound.sample(await phone.statsEntries())
        #expect(received.codec == "H264", "H.264 is preferred and supported on both ends")
        try await waitUntil("sender stats") { snapshots.all.last??.stats?.codec != nil }
        let sent = try #require(snapshots.all.last??.stats)
        #expect(sent.codec == "H264")
        print("loopback stream: sent \(sent.dimensions?.description ?? "?") \(sent.codec ?? "?") via \(sent.implementation ?? "?") " +
              "(hardware: \(sent.hardwareAccelerated.map(String.init) ?? "unknown")), path \(sent.path.rawValue); " +
              "received \(received.codec ?? "?") via \(received.implementation ?? "?")")

        // Quality change while live: the next frames arrive at the low tier's size.
        _ = await controller.handle(Self.env(.screenUpdate, ["quality": .string("low")], seq: seq.next()), deviceName: "Test phone")
        try await waitUntil("frames at the low tier") { phone.lastSize == CGSize(width: 960, height: 600) }
        #expect(states.all.last?["tier"]?.stringValue == "low")

        let stop = await controller.handle(Self.env(.screenStop, ["reason": .string("user")], seq: seq.next()), deviceName: "Test phone")
        #expect(stop.first?.payload["state"]?.stringValue == "stopped")
        #expect(await controller.isStreaming == false)
        #expect(snapshots.all.last! == nil, "the Mac UI is told sharing ended")
        phone.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func dataChannelInputIsValidatedAuthorizedAndDelivered() async throws {
        let phone = FakePhone()
        let (events, sink) = AsyncStream<OutgoingEvent>.makeStream()
        let received = Recorder<(EventType, InputTarget)>()
        let authorized = Recorder<Bool>()
        authorized.append(true)
        let ended = Recorder<Bool>()
        var options = ScreenShareOptions()
        options.loopbackAlias = "127.0.0.1"
        let controller = ScreenShareController(options: options, permission: { true }, makeSource: { TestPatternSource() },
                                               send: { event, _ in sink.yield(event) },
                                               authorizeInput: { _ in authorized.all.last ?? false },
                                               onInput: { e, target in received.append((e.type, target)) },
                                               onInputEnded: { ended.append(true) })
        let seq = Counter()
        phone.onCandidate = { sdp, index, mid in
            var p: [String: JSONValue] = ["candidate": .string(sdp), "sdpMLineIndex": .int(Int64(index))]
            if let mid { p["sdpMid"] = .string(mid) }
            Task { _ = await controller.handle(Self.env(.webrtcIce, p, seq: seq.next()), deviceName: "Test phone") }
        }
        let pump = Task {
            for await event in events {
                if event.type == .webrtcOffer, let answer = try? await phone.answer(offer: event.payload["sdp"]!.stringValue!) {
                    _ = await controller.handle(Self.env(.webrtcAnswer, ["sdp": .string(answer)], seq: seq.next()), deviceName: "Test phone")
                } else if event.type == .webrtcIce, let c = event.payload["candidate"]?.stringValue {
                    try? await phone.add(candidate: c, index: Int32(event.payload["sdpMLineIndex"]?.intValue ?? 0), mid: event.payload["sdpMid"]?.stringValue)
                }
            }
        }
        defer { pump.cancel() }
        _ = await controller.handle(Self.env(.screenStart, [:], seq: seq.next()), deviceName: "Test phone")
        try await waitUntil("both input channels open") { phone.isOpen("mb-input") && phone.isOpen("mb-input-rel") }
        #expect(controller.inputTarget(for: Self.session)?.source == .testPattern)
        #expect(controller.inputTarget(for: "s_someoneelse") == nil)

        func envelope(_ type: EventType, _ payload: [String: JSONValue], _ n: Int64) -> Data {
            try! EnvelopeCodec.encode(Envelope(type: type, sessionId: Self.session, sequence: n, sentAt: Date(), payload: payload), receiver: .mac)
        }
        let pointer: [String: JSONValue] = ["x": .double(0.5), "y": .double(0.5), "displayId": .string("test"), "action": .string("move")]
        let click: [String: JSONValue] = ["button": .string("left"), "action": .string("click"), "x": .double(0.5), "y": .double(0.5), "displayId": .string("test")]
        let key: [String: JSONValue] = ["code": .string("KeyA"), "action": .string("press"), "modifiers": .array([])]
        phone.send(envelope(.inputPointer, pointer, 1), on: "mb-input")
        phone.send(envelope(.inputButton, click, 1), on: "mb-input-rel")
        phone.send(envelope(.inputKey, key, 2), on: "mb-input")            // wrong channel: refused
        phone.send(Data("{\"version\":1,\"type\":\"screen.start\"}".utf8), on: "mb-input-rel")  // not input: refused
        try await waitUntil("two accepted input events") { received.all.count >= 2 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(received.all.map(\.0) == [.inputPointer, .inputButton])
        #expect(received.all.allSatisfy { $0.1.sessionId == Self.session })

        // Grants are re-checked on every message: once input.control is gone, nothing more is delivered.
        authorized.append(false)
        phone.send(envelope(.inputPointer, pointer, 2), on: "mb-input")
        try await Task.sleep(for: .milliseconds(400))
        #expect(received.all.count == 2)

        _ = await controller.handle(Self.env(.screenStop, [:], seq: seq.next()), deviceName: "Test phone")
        #expect(ended.all == [true], "everything is released when the input channels go away")
        #expect(controller.inputTarget(for: Self.session) == nil)
        phone.close()
    }

    @Test func refusesWithoutScreenRecordingPermission() async {
        let controller = ScreenShareController(permission: { false }, makeSource: { TestPatternSource() }, send: { _, _ in })
        let replies = await controller.handle(Self.env(.screenStart, [:], seq: 1), deviceName: "Test phone")
        #expect(replies.first?.type == .screenState)
        #expect(replies.first?.payload["state"]?.stringValue == "failed")
        #expect(replies.first?.payload["reason"]?.stringValue == "not_authorized")
        #expect(replies.first?.replyTo == 1)
        #expect(await controller.isStreaming == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func oneViewerAtATimeAndSessionEndStopsTheStream() async throws {
        let sent = Recorder<OutgoingEvent>()
        var options = ScreenShareOptions()
        options.loopbackAlias = "127.0.0.1"
        let controller = ScreenShareController(options: options, permission: { true }, makeSource: { TestPatternSource() },
                                               send: { event, _ in sent.append(event) })
        _ = await controller.handle(Self.env(.screenStart, [:], session: "s_phoneA00001", seq: 1), deviceName: "Phone A")
        try await waitUntil("offer for phone A") { sent.all.contains { $0.type == .webrtcOffer } }
        let other = await controller.handle(Self.env(.screenStart, [:], session: "s_phoneB00001", seq: 1), deviceName: "Phone B")
        #expect(other.first?.payload["reason"]?.stringValue == "busy")
        // An answer or candidate from a session that does not own the stream is ignored.
        let stray = await controller.handle(Self.env(.webrtcAnswer, ["sdp": .string("v=0\r\n")], session: "s_phoneB00001", seq: 2), deviceName: "Phone B")
        #expect(stray.first?.payload["code"]?.stringValue == "unexpected_answer")
        await controller.sessionEnded("s_phoneA00001")
        #expect(await controller.isStreaming == false)
    }

    @Test func updateWithoutAStreamIsRejected() async {
        let controller = ScreenShareController(permission: { true }, makeSource: { TestPatternSource() }, send: { _, _ in })
        let replies = await controller.handle(Self.env(.screenUpdate, ["quality": .string("low")], seq: 1), deviceName: "Test phone")
        #expect(replies.first?.payload["code"]?.stringValue == "not_streaming")
    }
}

// MARK: - Test doubles

/// A minimal receiving peer: answers offers, adds candidates, renders (counts) frames.
final class FakePhone: NSObject, LKRTCPeerConnectionDelegate, LKRTCVideoRenderer, @unchecked Sendable {
    private let factory: LKRTCPeerConnectionFactory
    private var pc: LKRTCPeerConnection!
    private let lock = NSLock()
    private var frames = 0
    private var size = CGSize.zero
    /// Must be retained: releasing the track wrapper detaches its renderers.
    private var receivedTrack: LKRTCVideoTrack?
    private var channels: [String: LKRTCDataChannel] = [:]

    func isOpen(_ label: String) -> Bool { lock.withLock { channels[label]?.readyState == .open } }

    func send(_ data: Data, on label: String) {
        let channel = lock.withLock { channels[label] }
        _ = channel?.sendData(LKRTCDataBuffer(data: data, isBinary: false))
    }
    var onCandidate: (@Sendable (String, Int32, String?) -> Void)?

    override init() {
        factory = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(), decoderFactory: LKRTCDefaultVideoDecoderFactory())
        let options = LKRTCPeerConnectionFactoryOptions()
        options.ignoreLoopbackNetworkAdapter = false
        factory.setOptions(options)
        super.init()
        let config = LKRTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        pc = factory.peerConnection(with: config, constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
    }

    var frameCount: Int { lock.withLock { frames } }
    var lastSize: CGSize { lock.withLock { size } }

    func answer(offer: String) async throws -> String {
        try await pc.applyRemote(type: .offer, sdp: offer)
        if let track = pc.transceivers.compactMap({ $0.receiver.track as? LKRTCVideoTrack }).first {
            receivedTrack = track
            track.add(self)
        }
        let answer = try await pc.makeAnswer()
        try await pc.applyLocal(type: .answer, sdp: answer)
        return answer
    }

    func add(candidate: String, index: Int32, mid: String?) async throws {
        try await pc.addCandidate(sdp: candidate, mLineIndex: index, mid: mid)
    }

    func statsEntries() async -> [RTCStatsEntry] { await pc.statsEntries() }

    func close() { pc.close() }

    // LKRTCVideoRenderer
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame else { return }
        lock.withLock {
            frames += 1
            size = CGSize(width: Int(frame.width), height: Int(frame.height))
        }
    }

    // LKRTCPeerConnectionDelegate
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        onCandidate?(candidate.sdp, candidate.sdpMLineIndex, candidate.sdpMid)
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {
        lock.withLock { channels[dataChannel.label] = dataChannel }
    }
}

final class Recorder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 100
    func next() -> Int64 { lock.withLock { value += 1; return value } }
}

struct TimedOut: Error, CustomStringConvertible {
    let what: String
    var description: String { "timed out waiting for \(what)" }
}

func waitUntil(_ what: String, timeout: TimeInterval = 20, _ condition: @Sendable () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { throw TimedOut(what: what) }
        try await Task.sleep(for: .milliseconds(50))
    }
}
