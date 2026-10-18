import Foundation
import Testing
@testable import MyBuddyCore

@Suite("Protocol envelope v1")
struct ProtocolTests {
    struct FixtureCase: CustomTestStringConvertible, Sendable {
        let file: String
        let receiver: ProtocolRole
        let expected: String  // event type for valid, error code for invalid
        var testDescription: String { file }
    }

    static func manifest(_ section: String) -> [FixtureCase] {
        guard let m = try? Repo.json("protocol/fixtures/manifest.json"), let items = m[section] as? [[String: String]] else {
            return []
        }
        return items.map { item in
            FixtureCase(file: item["file"]!, receiver: ProtocolRole(rawValue: item["receiver"]!)!,
                        expected: item[section == "valid" ? "type" : "error"]!)
        }
    }

    @Test("embedded catalog is byte-identical to protocol/schema/events.v1.json")
    func catalogDoesNotDrift() throws {
        let onDisk = try String(contentsOf: Repo.root.appendingPathComponent("protocol/schema/events.v1.json"), encoding: .utf8)
        #expect(EventCatalog.embeddedJSON + "\n" == onDisk, "run scripts/embed-catalog.sh")
    }

    @Test("EventType and Capability enums match the catalog exactly")
    func enumsMatchCatalog() {
        let catalog = EventCatalog.shared
        #expect(Set(EventType.allCases.map(\.rawValue)) == Set(catalog.events.keys))
        #expect(Set(Capability.allCases.map(\.rawValue)) == Set(catalog.capabilities))
        #expect(catalog.events.count == 66)
    }

    @Test("fixture manifest is present", arguments: ["valid", "invalid"])
    func manifestLoaded(section: String) {
        #expect(Self.manifest(section).count > 20)
    }

    @Test("valid fixtures decode", arguments: ProtocolTests.manifest("valid"))
    func validFixture(_ c: FixtureCase) throws {
        let data = try Repo.data("protocol/fixtures/" + c.file)
        let envelope = try EnvelopeCodec.decode(data, receiver: c.receiver)
        #expect(envelope.type.rawValue == c.expected)
    }

    @Test("invalid fixtures are rejected with the expected code", arguments: ProtocolTests.manifest("invalid"))
    func invalidFixture(_ c: FixtureCase) throws {
        let data = try Repo.data("protocol/fixtures/" + c.file)
        do {
            let envelope = try EnvelopeCodec.decode(data, receiver: c.receiver)
            Issue.record("accepted invalid fixture as \(envelope.type)")
        } catch {
            #expect(error.code == c.expected, "\(error)")
        }
    }

    @Test func encodeRoundTripAndSelfValidation() throws {
        let env = Envelope(type: .inputPointer, sessionId: "s_test00001", sequence: 7, sentAt: Date(timeIntervalSince1970: 1_792_131_000.123),
                           payload: ["x": .double(0.25), "y": .double(0.75), "displayId": .string("1"), "action": .string("move")])
        let data = try EnvelopeCodec.encode(env, receiver: .mac)
        let back = try EnvelopeCodec.decode(data, receiver: .mac)
        #expect(back.type == .inputPointer && back.sequence == 7 && back.payload["x"] == .double(0.25))

        // We refuse to send what the peer would reject.
        let bad = Envelope(type: .inputPointer, sessionId: "s_test00001", sequence: 8, sentAt: Date(),
                           payload: ["x": .double(2), "y": .double(0.5), "displayId": .string("1"), "action": .string("move")])
        #expect(throws: ProtocolError.self) { try EnvelopeCodec.encode(bad, receiver: .mac) }
        // A Mac→phone type cannot be encoded for the Mac.
        let wrongWay = Envelope(type: .webrtcOffer, sessionId: "s_test00001", sequence: 9, sentAt: Date(), payload: ["sdp": .string("v=0")])
        #expect(throws: ProtocolError.wrongDirection) { try EnvelopeCodec.encode(wrongWay, receiver: .mac) }
    }

    @Test func sequenceGuardRejectsReplays() throws {
        var guardState = SequenceGuard()
        func env(_ seq: Int64) -> Envelope {
            Envelope(type: .hostHeartbeat, sessionId: "s_test00001", sequence: seq, sentAt: Date(), payload: [:])
        }
        try guardState.accept(env(1))
        try guardState.accept(env(5))
        #expect(throws: ProtocolError.replayedSequence) { try guardState.accept(env(5)) }
        #expect(throws: ProtocolError.replayedSequence) { try guardState.accept(env(3)) }
    }

    @Test func typedPayloadDecoding() throws {
        struct Pointer: Decodable { let x: Double; let y: Double; let displayId: String }
        let data = try Repo.data("protocol/fixtures/valid/input.pointer.json")
        let p = try EnvelopeCodec.decode(data, receiver: .mac).decodePayload(Pointer.self)
        #expect(p.x == 0.52 && p.y == 0.38 && p.displayId == "1")
    }

    @Test func base64URLStrictness() {
        #expect(Base64URL.decode("SGVsbG8") == Data("Hello".utf8))
        #expect(Base64URL.decode("SGVsbG8=") == nil, "padding is not allowed")
        #expect(Base64URL.decode("SGV+bG8") == nil, "standard alphabet is not allowed")
        #expect(Base64URL.encode(Data([0xfb, 0xff])) == "-_8")
    }

    @Test func fileNameRules() {
        for ok in ["report.pdf", "Photo 2026.HEIC", "résumé.txt", ".hidden"] { #expect(FileNameRules.isSafe(ok), "\(ok)") }
        for bad in ["", ".", "..", "a/b", "a\\b", "a:b", "x\u{7}", " lead", "trail ", "dot."] { #expect(!FileNameRules.isSafe(bad), "\(bad)") }
    }
}
