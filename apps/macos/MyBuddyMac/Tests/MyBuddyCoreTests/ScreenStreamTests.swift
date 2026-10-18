import Foundation
@testable import MyBuddyCore
import Testing

@Suite("Screen stream policy")
struct ScreenStreamPolicyTests {
    @Test func fitsRetinaDisplayIntoEachTier() {
        let retina = (2560, 1600)
        #expect(StreamGeometry.fit(sourceWidth: retina.0, sourceHeight: retina.1, box: StreamTier.balanced.box) == StreamDimensions(width: 1280, height: 800))
        #expect(StreamGeometry.fit(sourceWidth: retina.0, sourceHeight: retina.1, box: StreamTier.low.box) == StreamDimensions(width: 960, height: 600))
        #expect(StreamGeometry.fit(sourceWidth: retina.0, sourceHeight: retina.1, box: StreamTier.high.box) == StreamDimensions(width: 1920, height: 1200))
    }

    @Test func neverUpscalesAndKeepsEvenDimensions() {
        #expect(StreamGeometry.fit(sourceWidth: 1280, sourceHeight: 720, box: StreamTier.high.box) == StreamDimensions(width: 1280, height: 720))
        let odd = StreamGeometry.fit(sourceWidth: 1001, sourceHeight: 777, box: StreamTier.high.box)
        #expect(odd.width % 2 == 0 && odd.height % 2 == 0 && odd.width <= 1001 && odd.height <= 777)
        // Ultrawide: width-limited, aspect preserved within rounding.
        let wide = StreamGeometry.fit(sourceWidth: 5120, sourceHeight: 1440, box: StreamTier.balanced.box)
        #expect(wide.width == 1280 && wide.height == 360)
        #expect(StreamGeometry.fit(sourceWidth: 0, sourceHeight: 0, box: StreamTier.low.box) == StreamDimensions(width: 2, height: 2))
    }

    @Test func frameRateHonoursPhoneCap() {
        #expect(StreamGeometry.fps(tier: .balanced, maxFps: nil) == 30)
        #expect(StreamGeometry.fps(tier: .balanced, maxFps: 10) == 10)
        #expect(StreamGeometry.fps(tier: .low, maxFps: 60) == 15, "a cap never raises the tier's rate")
    }

    @Test func statePayloadIsValidOnTheWire() throws {
        let status = ScreenStreamStatus(phase: .live, quality: .auto, tier: .balanced, displayId: "1", dimensions: StreamDimensions(width: 1280, height: 800),
                                        fps: 30, source: .display,
                                        displays: [StreamDisplay(id: "1", name: "Built-in Retina Display", width: 2560, height: 1600, isMain: true)])
        let envelope = Envelope(type: .screenState, sessionId: "s_test000001", sequence: 1, sentAt: Date(), payload: status.payload)
        let data = try EnvelopeCodec.encode(envelope, receiver: .phone)
        let decoded = try EnvelopeCodec.decode(data, receiver: .phone)
        #expect(decoded.payload["state"]?.stringValue == "live")
        #expect(decoded.payload["width"]?.intValue == 1280)
        #expect(decoded.payload["displays"]?.arrayValue?.count == 1)
    }

    @Test func statePayloadDropsInvalidReasonAndClampsMessage() throws {
        let status = ScreenStreamStatus(phase: .failed, reason: "Not Authorized!", message: String(repeating: "x", count: 500))
        let p = status.payload
        #expect(p["reason"] == nil)
        #expect(p["message"]?.stringValue?.count == 300)
        _ = try EnvelopeCodec.encode(Envelope(type: .screenState, sessionId: "s_test000001", sequence: 1, sentAt: Date(), payload: p), receiver: .phone)
    }

    @Test func screenEventsNeedScreenViewAndHaveTheRightDirection() {
        for type in [EventType.screenStart, .screenUpdate, .screenStop, .screenState] {
            #expect(type.requiredCapability == .screenView)
        }
        #expect(EventType.screenState.spec.dir == "M2P")
        #expect(EventType.screenStart.spec.dir == "P2M")
    }
}

@Suite("Adaptive quality")
struct AdaptiveQualityTests {
    @Test func fixedQualityNeverChanges() {
        var c = AdaptiveQualityController(quality: .high)
        for _ in 0..<60 { #expect(c.observe(limitation: .bandwidth, availableOutgoingBitrateBps: 100_000) == nil) }
        #expect(c.tier == .high)
    }

    @Test func stepsDownAfterSustainedLimitationThenHolds() {
        var c = AdaptiveQualityController(quality: .auto)
        #expect(c.tier == .balanced)
        for _ in 0..<(AdaptiveQualityController.downAfter - 1) { #expect(c.observe(limitation: .bandwidth, availableOutgoingBitrateBps: nil) == nil) }
        #expect(c.observe(limitation: .bandwidth, availableOutgoingBitrateBps: nil) == .low)
        // Held: even sustained headroom cannot change it during the hold window.
        for _ in 0..<AdaptiveQualityController.holdAfterChange { #expect(c.observe(limitation: .none, availableOutgoingBitrateBps: 50_000_000) == nil) }
        #expect(c.tier == .low)
    }

    @Test func briefLimitationDoesNotFlap() {
        var c = AdaptiveQualityController(quality: .auto)
        for i in 0..<40 {
            let limitation: QualityLimitation = i % 3 == 0 ? .cpu : .none
            #expect(c.observe(limitation: limitation, availableOutgoingBitrateBps: 1_000_000) == nil)
        }
        #expect(c.tier == .balanced)
    }

    @Test func stepsUpOnlyWhenTheNetworkEstimateFits() {
        var c = AdaptiveQualityController(quality: .auto)
        for _ in 0..<60 { #expect(c.observe(limitation: .none, availableOutgoingBitrateBps: 3_000_000) == nil) }
        #expect(c.tier == .balanced, "3 Mbps does not fit the 6 Mbps tier with headroom")
        var changed: StreamTier?
        for _ in 0..<AdaptiveQualityController.upAfter { changed = c.observe(limitation: .none, availableOutgoingBitrateBps: 9_000_000) ?? changed }
        #expect(changed == .high && c.tier == .high)
    }

    @Test func autoCanStartHighAndSmoothIsAFixedSixtyFpsChoice() {
        var c = AdaptiveQualityController(quality: .auto, startTier: .high)
        #expect(c.tier == .high)
        for _ in 0..<(AdaptiveQualityController.downAfter - 1) { #expect(c.observe(limitation: .bandwidth, availableOutgoingBitrateBps: nil) == nil) }
        #expect(c.observe(limitation: .bandwidth, availableOutgoingBitrateBps: nil) == .balanced)
        var s = AdaptiveQualityController(quality: .smooth)
        #expect(s.tier == .smooth && s.tier.fps == 60)
        for _ in 0..<60 { #expect(s.observe(limitation: .bandwidth, availableOutgoingBitrateBps: 100_000) == nil) }
        #expect(StreamTier.balanced.higher == .high, "auto never climbs into smooth")
        #expect(StreamTier.smooth.lower == .balanced)
    }

    @Test func otherLimitationIsIgnored() {
        var c = AdaptiveQualityController(quality: .auto)
        for _ in 0..<30 { #expect(c.observe(limitation: .other, availableOutgoingBitrateBps: nil) == nil) }
        #expect(c.tier == .balanced)
    }
}

@Suite("Stream statistics")
struct StreamStatsTests {
    private func outbound(bytes: Double, at us: Double, pairLocal: String = "host", pairRemote: String = "prflx") -> [RTCStatsEntry] {
        [
            RTCStatsEntry(id: "OT1", type: "outbound-rtp", timestampUs: us, values: [
                "kind": .string("video"), "bytesSent": .number(bytes), "framesPerSecond": .number(29.5), "frameWidth": .number(1280),
                "frameHeight": .number(800), "codecId": .string("C1"), "encoderImplementation": .string("VideoToolbox"),
                "powerEfficientEncoder": .number(1), "qualityLimitationReason": .string("bandwidth"),
            ]),
            RTCStatsEntry(id: "C1", type: "codec", timestampUs: us, values: ["mimeType": .string("video/H264")]),
            RTCStatsEntry(id: "T1", type: "transport", timestampUs: us, values: ["selectedCandidatePairId": .string("CP1")]),
            RTCStatsEntry(id: "CP1", type: "candidate-pair", timestampUs: us, values: [
                "localCandidateId": .string("L1"), "remoteCandidateId": .string("R1"), "currentRoundTripTime": .number(0.012),
                "availableOutgoingBitrate": .number(4_000_000), "state": .string("succeeded"), "nominated": .number(1),
            ]),
            RTCStatsEntry(id: "L1", type: "local-candidate", timestampUs: us, values: ["candidateType": .string(pairLocal)]),
            RTCStatsEntry(id: "R1", type: "remote-candidate", timestampUs: us, values: ["candidateType": .string(pairRemote)]),
        ]
    }

    @Test func parsesOutboundVideoAndComputesBitrateOverTheRealInterval() {
        var parser = StreamStatsParser(direction: .outbound)
        let first = parser.sample(outbound(bytes: 1_000_000, at: 1_000_000))
        #expect(first.bitrateKbps == nil, "no rate from a single report")
        let s = parser.sample(outbound(bytes: 1_250_000, at: 2_000_000))
        #expect(s.bitrateKbps == 2000)
        #expect(s.framesPerSecond == 29.5)
        #expect(s.dimensions == StreamDimensions(width: 1280, height: 800))
        #expect(s.codec == "H264")
        #expect(s.implementation == "VideoToolbox" && s.hardwareAccelerated == true)
        #expect(s.qualityLimitation == .bandwidth)
        #expect(s.roundTripMs == 12)
        #expect(s.path == .direct)
        #expect(s.availableOutgoingBitrateBps == 4_000_000)
    }

    @Test func relayCandidateMeansRelayedPath() {
        var parser = StreamStatsParser(direction: .outbound)
        #expect(parser.sample(outbound(bytes: 10, at: 1, pairLocal: "relay", pairRemote: "srflx")).path == .relayed)
    }

    @Test func noSelectedPairMeansUnknownPath() {
        var parser = StreamStatsParser(direction: .inbound)
        let s = parser.sample([RTCStatsEntry(id: "I1", type: "inbound-rtp", timestampUs: 1, values: ["kind": .string("video"), "packetsLost": .number(3)])])
        #expect(s.path == .unknown && s.roundTripMs == nil && s.packetsLost == 3)
    }

    @Test func counterResetDoesNotProduceANegativeBitrate() {
        var parser = StreamStatsParser(direction: .outbound)
        _ = parser.sample(outbound(bytes: 5_000_000, at: 1_000_000))
        #expect(parser.sample(outbound(bytes: 1_000, at: 2_000_000)).bitrateKbps == nil)
    }
}

@Suite("Tailscale address rules")
struct TailnetTests {
    @Test func ipv4RangeIs100_64Slash10() {
        for yes in ["100.64.0.1", "100.101.102.103", "100.127.255.254"] { #expect(Tailnet.isTailnetIPv4(yes), "\(yes)") }
        for no in ["100.63.255.255", "100.128.0.1", "10.0.0.1", "192.168.1.2", "1.2.3", "garbage", ""] { #expect(!Tailnet.isTailnetIPv4(no), "\(no)") }
    }

    @Test func ipv6RangeIsFd7a115cA1e0Slash48() {
        for yes in ["fd7a:115c:a1e0::1", "fd7a:115c:a1e0:ab12:4843:cd96:627e:9975", "[fd7a:115c:a1e0::5]", "FD7A:115C:A1E0::9"] { #expect(Tailnet.isTailnetIPv6(yes), "\(yes)") }
        for no in ["fd7a:115c:a1e1::1", "fd12:3456::1", "fe80::1%utun4", "::1", "100.101.102.103"] { #expect(!Tailnet.isTailnetIPv6(no), "\(no)") }
    }

    @Test func magicDNSNamesNeedMachineAndTailnetLabels() {
        #expect(Tailnet.isMagicDNSName("macbook-air.tail1234.ts.net"))
        #expect(Tailnet.isMagicDNSName("MacBook-Air.Tail1234.TS.NET"))
        for no in ["ts.net", "x.ts.net", "evil.ts.net.attacker.com", "-bad.tail.ts.net", "a..b.ts.net", "mac.local", "under_score.tail.ts.net"] {
            #expect(!Tailnet.isMagicDNSName(no), "\(no)")
        }
    }

    @Test func detectsTheTailnetInterfacePreferringAConfirmedOne() {
        let found = Tailnet.detect(["en0": ["192.168.1.231"], "utun3": ["100.70.1.2"],
                                    "utun4": ["100.101.102.103", "fd7a:115c:a1e0::4f2b", "fe80::1%utun4"]])
        #expect(found == Tailnet.Interface(name: "utun4", ipv4: "100.101.102.103", ipv6: "fd7a:115c:a1e0::4f2b"))
        #expect(found?.confirmed == true)
        #expect(Tailnet.detect(["en0": ["192.168.1.231", "fe80::1%en0"]]) == nil)
        #expect(Tailnet.detect(["utun9": ["100.70.1.2"]])?.confirmed == false)
    }
}

@Suite("Input data channels")
struct DataChannelInputGateTests {
    static let session = "s_inputgate01"

    static func data(_ type: EventType, _ payload: [String: JSONValue], seq: Int64, session: String = session) -> Data {
        // Built by hand (not via the encoder) so invalid messages can be sent too.
        let object: JSONValue = .object(["version": .int(1), "type": .string(type.rawValue), "sessionId": .string(session), "sequence": .int(seq),
                                         "sentAt": .string("2026-10-16T08:30:00.000Z"), "payload": .object(payload)])
        return try! JSONEncoder().encode(object)
    }

    static let pointer: [String: JSONValue] = ["x": .double(0.5), "y": .double(0.25), "displayId": .string("1"), "action": .string("move")]

    @Test func acceptsInputOnItsChannelOnly() throws {
        var gate = DataChannelInputGate(sessionId: Self.session)
        #expect(try gate.accept(Self.data(.inputPointer, Self.pointer, seq: 1), on: .pointer).get().type == .inputPointer)
        let key: [String: JSONValue] = ["code": .string("KeyA"), "action": .string("press"), "modifiers": .array([])]
        #expect(gate.accept(Self.data(.inputKey, key, seq: 2), on: .pointer) == .failure(.wrongChannel), "keys must never ride the lossy channel")
        #expect(try gate.accept(Self.data(.inputKey, key, seq: 1), on: .reliable).get().type == .inputKey)
        #expect(InputDataChannel.channel(for: .inputText) == .reliable && InputDataChannel.channel(for: .inputScroll) == .pointer)
    }

    @Test func rejectsNonInputWrongSessionReplayAndGarbage() {
        var gate = DataChannelInputGate(sessionId: Self.session)
        #expect(gate.accept(Self.data(.screenStart, [:], seq: 1), on: .reliable) == .failure(.notInput))
        #expect(gate.accept(Self.data(.inputPointer, Self.pointer, seq: 1, session: "s_someoneelse"), on: .pointer) == .failure(.wrongSession))
        _ = gate.accept(Self.data(.inputPointer, Self.pointer, seq: 5), on: .pointer)
        #expect(gate.accept(Self.data(.inputPointer, Self.pointer, seq: 4), on: .pointer) == .failure(.replayed), "a late pointer move is dropped")
        #expect(gate.accept(Data("{\"version\":1,".utf8), on: .pointer) == .failure(.malformed("malformed_json")))
        let outOfRange: [String: JSONValue] = ["x": .double(1.5), "y": .double(0.25), "displayId": .string("1"), "action": .string("move")]
        #expect(gate.accept(Self.data(.inputPointer, outOfRange, seq: 6), on: .pointer) == .failure(.malformed("invalid_payload")))
    }

    @Test func rateLimitsPerSecond() {
        var gate = DataChannelInputGate(sessionId: Self.session)
        let now = Date()
        var accepted = 0
        for i in 1...300 where (try? gate.accept(Self.data(.inputPointer, Self.pointer, seq: Int64(i)), on: .pointer, now: now).get()) != nil { accepted += 1 }
        #expect(accepted == InputRateLimiter.limits[.inputPointer])
    }
}
