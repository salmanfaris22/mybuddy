import Foundation
import Testing
@testable import MyBuddyCore

/// MyBuddy Connect statements and the signed WebRTC rendezvous, pinned by the shared vectors (the Go server
/// verifies the same bytes).
@Suite("MyBuddy Connect")
struct ConnectTests {
    let v: Vectors
    init() throws { v = try Vectors.load() }

    private func connect(_ key: String) -> String { v.connect[key] as! String }
    private var clientSPKI: Data { v.b64("clientIdentityKeySpkiB64u") }
    private var hostSPKI: Data { v.b64("hostIdentityKeySpkiB64u") }
    private var clientId: String { v.expect("clientDeviceId") }
    private var hostId: String { v.expect("hostDeviceId") }

    @Test func statementsMatchTheServerBytes() {
        #expect(Hex.encode(ConnectStatements.register(spki: clientSPKI, platform: "android")) == connect("registerMessageHex"))
        let nonce = Base64URL.decode(connect("challengeNonceB64u"))!
        #expect(Hex.encode(ConnectStatements.auth(challengeId: connect("challengeId"), nonce: nonce, deviceId: clientId)) == connect("authMessageHex"))
        #expect(Hex.encode(ConnectStatements.pairing(hostDeviceId: hostId, clientDeviceId: clientId, createdAt: connect("pairingCreatedAt")))
                == connect("pairingMessageHex"))
        #expect(Hex.encode(ConnectStatements.rtc(kind: connect("rtcKind"), rid: connect("rtcId"), from: clientId, to: hostId,
                                                 at: connect("rtcAt"), sdp: connect("rtcSdp"))) == connect("rtcMessageHex"))
    }

    @Test func vectorSignaturesVerify() {
        let pairing = Hex.decode(connect("pairingMessageHex"))!
        #expect(IdentityMath.verify(spki: hostSPKI, message: pairing, derSignature: Base64URL.decode(connect("pairingHostSignatureDerB64u"))!))
        #expect(IdentityMath.verify(spki: clientSPKI, message: pairing, derSignature: Base64URL.decode(connect("pairingClientSignatureDerB64u"))!))
    }

    @Test func rendezvousOfferFromTheVectorsDecodesAndVerifies() throws {
        let m = try RendezvousMessage.decode(Data(connect("rtcEnvelopeJson").utf8))
        #expect(m.kind == .offer && m.from == clientId && m.to == hostId)
        let at = ConnectTime.parse(connect("rtcAt"))!
        #expect(m.verify(signerSPKI: clientSPKI, expectedTo: hostId, now: at.addingTimeInterval(30)))
        // Stale, wrong recipient, wrong signer, tampered SDP: all refused.
        #expect(!m.verify(signerSPKI: clientSPKI, expectedTo: hostId, now: at.addingTimeInterval(121)))
        #expect(!m.verify(signerSPKI: clientSPKI, expectedTo: clientId, now: at))
        #expect(!m.verify(signerSPKI: hostSPKI, expectedTo: hostId, now: at))
        var tampered = m
        tampered.sdp = m.sdp!.replacingOccurrences(of: "1F:2E", with: "AA:BB")
        #expect(!tampered.verify(signerSPKI: clientSPKI, expectedTo: hostId, now: at))
    }

    @Test func signedAnswersRoundTrip() throws {
        let mac = SoftwareIdentity(), phone = SoftwareIdentity()
        let rid = ConnectIDs.newRendezvousId()
        #expect(ConnectIDs.isRendezvousId(rid))
        let answer = try RendezvousMessage.signed(.answer, rid: rid, identity: mac, to: phone.deviceId, sdp: "v=0\r\n")
        let decoded = try RendezvousMessage.decode(try answer.encoded())
        #expect(decoded == answer)
        #expect(decoded.verify(signerSPKI: mac.publicKeySPKI, expectedTo: phone.deviceId))
        #expect(!decoded.verify(signerSPKI: phone.publicKeySPKI, expectedTo: phone.deviceId), "only the Mac's key verifies")
    }

    @Test func malformedRendezvousIsRejected() {
        func bad(_ json: String) -> Bool { (try? RendezvousMessage.decode(Data(json.utf8))) == nil }
        let ids = #""from":"da96726356de5002c857434beefe468d","to":"e514356e6546b0b22ebcdd982ec66090""#
        #expect(bad(#"{"v":1,"kind":"offer","rid":"r_abcdefgh12",\#(ids)}"#), "an offer needs sdp, time and signature")
        #expect(bad(#"{"v":2,"kind":"bye","rid":"r_abcdefgh12",\#(ids)}"#), "unknown version")
        #expect(bad(#"{"v":1,"kind":"bye","rid":"x",\#(ids)}"#), "bad rendezvous id")
        #expect(bad(#"{"v":1,"kind":"bye","rid":"r_abcdefgh12","from":"ABC","to":"e514356e6546b0b22ebcdd982ec66090"}"#), "bad device id")
        #expect(bad(#"{"v":1,"kind":"shell","rid":"r_abcdefgh12",\#(ids)}"#), "unknown kind")
        #expect(!bad(#"{"v":1,"kind":"ice","rid":"r_abcdefgh12",\#(ids),"candidate":"candidate:1 1 udp 1 10.0.0.2 5000 typ host","sdpMid":"0","sdpMLineIndex":0}"#))
    }

    @Test func replayGuardAcceptsEachRendezvousOnce() {
        let guardian = RendezvousReplayGuard(window: 60)
        let now = Date()
        #expect(guardian.firstUse(from: "a", rid: "r_1", kind: .offer, now: now))
        #expect(!guardian.firstUse(from: "a", rid: "r_1", kind: .offer, now: now.addingTimeInterval(5)))
        #expect(guardian.firstUse(from: "b", rid: "r_1", kind: .offer, now: now), "ids are per sender")
        #expect(guardian.firstUse(from: "a", rid: "r_1", kind: .offer, now: now.addingTimeInterval(61)), "forgotten after the window")
    }

    @Test func serverAddressRules() {
        #expect(ConnectServerURL.normalize("https://connect.example.com")?.absoluteString == "https://connect.example.com")
        #expect(ConnectServerURL.normalize(" https://Connect.Example.com:8443/ ")?.absoluteString == "https://connect.example.com:8443")
        #expect(ConnectServerURL.normalize("http://127.0.0.1:8787")?.absoluteString == "http://127.0.0.1:8787", "plain http only on loopback")
        #expect(ConnectServerURL.normalize("http://connect.example.com") == nil)
        #expect(ConnectServerURL.normalize("https://user:pw@connect.example.com") == nil)
        #expect(ConnectServerURL.normalize("https://connect.example.com/v1?x=1") == nil)
        #expect(ConnectServerURL.normalize("ftp://connect.example.com") == nil)
        #expect(ConnectServerURL.signalURL(URL(string: "https://c.example.com:8443")!)?.absoluteString == "wss://c.example.com:8443/v1/signal")
        #expect(ConnectServerURL.signalURL(URL(string: "http://127.0.0.1:8787")!)?.absoluteString == "ws://127.0.0.1:8787/v1/signal")
    }

    @Test func iceRouteReadsTheSelectedPair() {
        func entry(_ id: String, _ type: String, _ values: [String: RTCStatsEntry.Value]) -> RTCStatsEntry {
            RTCStatsEntry(id: id, type: type, timestampUs: 0, values: values)
        }
        let direct = [entry("T", "transport", ["selectedCandidatePairId": .string("P")]),
                      entry("P", "candidate-pair", ["localCandidateId": .string("L"), "remoteCandidateId": .string("R")]),
                      entry("L", "local-candidate", ["candidateType": .string("srflx")]), entry("R", "remote-candidate", ["candidateType": .string("host")])]
        #expect(ICERoute.isRelayed(direct) == false)
        var relayed = direct
        relayed[3] = entry("R", "remote-candidate", ["candidateType": .string("relay")])
        #expect(ICERoute.isRelayed(relayed) == true)
        #expect(ICERoute.isRelayed([entry("T", "transport", [:])]) == nil, "nothing selected yet")
        #expect(!SessionRoute.internetRelayed.allowsFileTransfer && SessionRoute.internetDirect.allowsFileTransfer)
    }
}
