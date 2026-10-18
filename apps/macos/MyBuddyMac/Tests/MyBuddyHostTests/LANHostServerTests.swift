import Foundation
import Testing
import MyBuddyCore
@testable import MyBuddyHost

/// End-to-end over real loopback sockets: simulated phone ↔ LANHostServer.
@Suite("LAN host server (loopback, end-to-end)", .serialized)
struct LANHostServerTests {
    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ v: T) { value = v }
        var get: T { lock.withLock { value } }
        func set(_ v: T) { lock.withLock { value = v } }
    }

    struct Harness {
        let server: LANHostServer
        let hostIdentity: SoftwareIdentity
        let trust: TrustStore
        let window: PairingWindow
        let approvals: Box<[PairingApprovalRequest]>
        let activity: Box<[ActivityEvent]>
        var host = "127.0.0.1"
        var url: URL { URL(string: "ws://\(host):\(server.boundPort!)")! }
    }

    func makeServer(approve: Bool = true, bindHost: String? = nil) async throws -> Harness {
        let hostIdentity = SoftwareIdentity()
        let trust = TrustStore(storage: InMemoryTrustStorage())
        let window = PairingWindow()
        let approvals = Box<[PairingApprovalRequest]>([])
        let activity = Box<[ActivityEvent]>([])
        var config = LANHostServer.Configuration()
        config.port = 0
        config.advertiseBonjour = false
        config.loopbackOnly = true
        config.bindHost = bindHost
        let handlers = LANHostHandlers(
            approvePairing: { request in
                approvals.set(approvals.get + [request])
                return approve ? PermissionGrant() : nil
            },
            handle: { envelope, _, _ in
                if envelope.type == .healthSnapshotRequest {
                    return [OutgoingEvent(.healthSnapshotResult, ["snapshot": .object(["schemaVersion": .int(1)])], replyTo: envelope.sequence)]
                }
                return []
            },
            record: { e in activity.set(activity.get + [e]) })
        let server = LANHostServer(identity: hostIdentity, hostName: "Test Mac", trust: trust, pairingWindow: window, handlers: handlers, configuration: config)
        try server.start()
        for _ in 0..<100 where server.boundPort == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(server.boundPort != nil)
        var harness = Harness(server: server, hostIdentity: hostIdentity, trust: trust, window: window, approvals: approvals, activity: activity)
        if let bindHost { harness.host = bindHost }
        return harness
    }

    /// Uses this Mac's real Tailscale address when Tailscale is connected (skips otherwise). The listener is
    /// bound to that one address for a few seconds and still requires the MBH1 handshake.
    @Test func tailnetSessionsAreLabelledAndRefusedWhenTailscaleIsTurnedOff() async throws {
        guard let tailnetIP = TailscaleStatus.current().address else {
            print("skipped: Tailscale is not connected on this Mac")
            return
        }
        let h = try await makeServer(bindHost: tailnetIP)
        defer { h.server.stop() }
        let phone = SoftwareIdentity()
        try h.trust.trust(spki: phone.publicKeySPKI, name: "Vivo X300", platform: "android")
        let client = MBH1WebSocketClient(url: h.url, identity: phone)
        try await client.connect(mode: .resume, pinnedFingerprint: h.hostIdentity.fingerprint)
        try await client.send(.sessionRequest, ["requestedCapabilities": .array([.string("health.read")]), "protocolVersions": .array([.int(1)]), "features": .array([])])
        _ = try await client.receive(.sessionApproved)
        #expect(h.server.activeSessions.first?.viaTailnet == true, "a phone arriving on the tailnet address is labelled as Tailscale")

        // Turning Tailscale off ends that session and refuses new tailnet connections before any handshake.
        h.server.setAllowTailnet(false)
        let closed = try await client.receive(.sessionClosed)
        #expect(closed.payload["reason"] == .string("user"))
        let again = MBH1WebSocketClient(url: h.url, identity: phone)
        await #expect(throws: (any Error).self) {
            try await again.connect(mode: .resume, pinnedFingerprint: h.hostIdentity.fingerprint)
        }
        #expect(h.activity.get.contains { $0.title == "Refused a connection over Tailscale" })

        // And on again: accepted.
        h.server.setAllowTailnet(true)
        let third = MBH1WebSocketClient(url: h.url, identity: phone)
        try await third.connect(mode: .resume, pinnedFingerprint: h.hostIdentity.fingerprint)
        third.close()
    }

    @Test func pairApproveSessionAndCapabilityEnforcement() async throws {
        let h = try await makeServer()
        defer { h.server.stop() }
        let invitation = h.window.open(addresses: ["127.0.0.1:\(h.server.boundPort!)"], hostFingerprint: h.hostIdentity.fingerprint, displayName: "Test Mac")
        let phone = SoftwareIdentity()
        let client = MBH1WebSocketClient(url: h.url, identity: phone, clientName: "Vivo X300")
        let sas = try await client.connect(mode: .pair, pinnedFingerprint: invitation.hostFingerprint, pairingSecret: invitation.secret)
        try await client.send(.pairingRequest, ["deviceName": .string("Vivo X300"), "platform": .string("android"), "appVersion": .string("0.1.0")])
        let approved = try await client.receive(.pairingApproved)
        #expect(approved.payload["hostDeviceId"]?.stringValue == h.hostIdentity.deviceId)
        #expect(h.approvals.get.first?.verificationCode == sas, "Mac shows the same 6-digit code as the phone")
        #expect(h.trust.isTrusted(spki: phone.publicKeySPKI))
        #expect(!h.window.isOpen, "the QR secret is single use")

        try await client.send(.sessionRequest, ["requestedCapabilities": .array([.string("health.read"), .string("input.control")]),
                                                "protocolVersions": .array([.int(1)]), "features": .array([])])
        let session = try await client.receive(.sessionApproved)
        #expect(session.payload["grantedCapabilities"] == .array([.string("health.read")]), "input control is off by default")

        try await client.send(.hostHeartbeat, ["probe": .string("p1"), "reply": .bool(false)])
        #expect(try await client.receive(.hostHeartbeat).payload["reply"] == .bool(true))

        let req = try await client.send(.healthSnapshotRequest, [:])
        #expect(try await client.receive(.healthSnapshotResult).replyTo == req)

        try await client.send(.inputText, ["text": .string("hello")])
        let denied = try await client.receive(.error)
        #expect(denied.payload["code"] == .string("not_permitted"))
        #expect(h.server.activeSessions.count == 1)
        client.close()
    }

    @Test func resumeRevokeAndRefuseUnknownDevices() async throws {
        let h = try await makeServer()
        defer { h.server.stop() }
        let phone = SoftwareIdentity()
        try h.trust.trust(spki: phone.publicKeySPKI, name: "Vivo X300", platform: "android")

        let client = MBH1WebSocketClient(url: h.url, identity: phone)
        try await client.connect(mode: .resume, pinnedFingerprint: h.hostIdentity.fingerprint)
        try await client.send(.sessionRequest, ["requestedCapabilities": .array([.string("health.read")]), "protocolVersions": .array([.int(1)]), "features": .array([])])
        _ = try await client.receive(.sessionApproved)

        // Revocation ends the live session immediately with a reason.
        try h.trust.revoke(id: phone.deviceId)
        h.server.disconnect(deviceId: phone.deviceId)
        let closed = try await client.receive(.sessionClosed)
        #expect(closed.payload["reason"] == .string("revoked"))

        // The revoked phone (and any unknown phone) can no longer connect.
        for identity in [phone, SoftwareIdentity()] {
            let again = MBH1WebSocketClient(url: h.url, identity: identity)
            try await again.connect(mode: .resume, pinnedFingerprint: h.hostIdentity.fingerprint)
            await #expect(throws: (any Error).self) {
                try await again.send(.sessionRequest, ["requestedCapabilities": .array([]), "protocolVersions": .array([.int(1)]), "features": .array([])])
                _ = try await again.receive()
            }
        }
        #expect(h.activity.get.contains { $0.title == "Refused unknown or revoked device" })
    }

    @Test func wrongSecretOrWrongHostKeyNeverReachesApproval() async throws {
        let h = try await makeServer()
        defer { h.server.stop() }
        let invitation = h.window.open(addresses: ["127.0.0.1:\(h.server.boundPort!)"], hostFingerprint: h.hostIdentity.fingerprint, displayName: "Test Mac")

        let attacker = MBH1WebSocketClient(url: h.url, identity: SoftwareIdentity())
        try await attacker.connect(mode: .pair, pinnedFingerprint: invitation.hostFingerprint, pairingSecret: Data(repeating: 0, count: 32))
        await #expect(throws: (any Error).self) {
            try await attacker.send(.pairingRequest, ["deviceName": .string("Evil"), "platform": .string("android"), "appVersion": .string("1")])
            _ = try await attacker.receive()
        }
        #expect(h.approvals.get.isEmpty, "a wrong proof never even shows an approval prompt")

        // A phone that pinned a different Mac refuses this host.
        let wrongPin = MBH1WebSocketClient(url: h.url, identity: SoftwareIdentity())
        await #expect(throws: MBH1WebSocketClient.ClientError.handshake(.hostKeyMismatch)) {
            try await wrongPin.connect(mode: .pair, pinnedFingerprint: SoftwareIdentity().fingerprint, pairingSecret: invitation.secret)
        }
    }

    @Test func declinedPairingIsNotTrusted() async throws {
        let h = try await makeServer(approve: false)
        defer { h.server.stop() }
        let invitation = h.window.open(addresses: ["127.0.0.1:\(h.server.boundPort!)"], hostFingerprint: h.hostIdentity.fingerprint, displayName: "Test Mac")
        let phone = SoftwareIdentity()
        let client = MBH1WebSocketClient(url: h.url, identity: phone)
        try await client.connect(mode: .pair, pinnedFingerprint: invitation.hostFingerprint, pairingSecret: invitation.secret)
        try await client.send(.pairingRequest, ["deviceName": .string("Vivo X300"), "platform": .string("android"), "appVersion": .string("0.1.0")])
        let rejected = try await client.receive(.pairingRejected)
        #expect(rejected.payload["reason"] == .string("user_rejected"))
        #expect(!h.trust.isTrusted(spki: phone.publicKeySPKI))
    }

    @Test func emergencyStopClosesEverySession() async throws {
        let h = try await makeServer()
        defer { h.server.stop() }
        let phone = SoftwareIdentity()
        try h.trust.trust(spki: phone.publicKeySPKI, name: "Vivo X300", platform: "android")
        let client = MBH1WebSocketClient(url: h.url, identity: phone)
        try await client.connect(mode: .resume, pinnedFingerprint: h.hostIdentity.fingerprint)
        try await client.send(.sessionRequest, ["requestedCapabilities": .array([]), "protocolVersions": .array([.int(1)]), "features": .array([])])
        _ = try await client.receive(.sessionApproved)
        h.server.closeAll(reason: "emergency_stop")
        #expect(try await client.receive(.sessionClosed).payload["reason"] == .string("emergency_stop"))
    }
}
