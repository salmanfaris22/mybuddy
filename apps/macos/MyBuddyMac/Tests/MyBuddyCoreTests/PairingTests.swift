import Foundation
import Testing
@testable import MyBuddyCore

@Suite("Pairing, trust and permissions")
struct PairingTests {
    @Test func invitationURLRoundTripAndVectorURL() throws {
        let inv = PairingInvitation(addresses: ["192.168.1.20:47811", "[fe80::1%en0]:47811"], hostFingerprint: String(repeating: "A", count: 43),
                                    secret: Data(repeating: 3, count: 32), expiresAt: Date(timeIntervalSince1970: 2_000_000_000), displayName: "Salman’s MacBook Air")
        let parsed = try PairingInvitation.parse(inv.url.absoluteString, now: Date(timeIntervalSince1970: 1_900_000_000))
        #expect(parsed == inv)

        let v = try Vectors.load()
        let fromVector = try PairingInvitation.parse(v.expect("qrUrl"), now: Date(timeIntervalSince1970: 1_792_130_000))
        #expect(fromVector.hostFingerprint == v.expect("hostFingerprint"))
        #expect(fromVector.secret == v.b64("pairingSecretB64u"))
        #expect(fromVector.displayName == "Salman’s MacBook Air")
    }

    @Test func invitationRejectsBadInput() {
        let now = Date(timeIntervalSince1970: 1_792_130_000)
        let good = "mybuddy://pair?v=1&h=10.0.0.2:47811&fp=\(String(repeating: "A", count: 43))&s=\(Base64URL.encode(Data(repeating: 1, count: 32)))&x=1792131000&n=Mac"
        #expect((try? PairingInvitation.parse(good, now: now)) != nil)
        #expect(throws: PairingError.expired) { try PairingInvitation.parse(good, now: Date(timeIntervalSince1970: 1_792_131_001)) }
        for bad in [
            good.replacingOccurrences(of: "mybuddy://", with: "https://"),
            good.replacingOccurrences(of: "v=1", with: "v=2"),
            good.replacingOccurrences(of: "10.0.0.2:47811", with: "10.0.0.2"),
            good.replacingOccurrences(of: "10.0.0.2:47811", with: "evil.example/x:80"),
            good.replacingOccurrences(of: "&n=Mac", with: "&n=Mac&n=Other"),
            good.replacingOccurrences(of: Base64URL.encode(Data(repeating: 1, count: 32)), with: "short"),
        ] {
            #expect(throws: PairingError.self, "\(bad)") { try PairingInvitation.parse(bad, now: now) }
        }
    }

    @Test func invitationAddressesMustStayOnTheLocalNetwork() {
        for ok in ["10.0.0.2:47811", "192.168.1.20:47811", "172.16.0.9:47811", "100.100.1.2:47811", "127.0.0.1:47811",
                   "mac.local:47811", "[fe80::1%en0]:47811", "[fd12::1]:47811"] {
            #expect(PairingInvitation.isValidHostPort(ok), "\(ok)")
        }
        for bad in ["8.8.8.8:47811", "172.32.0.1:47811", "evil.example:47811", "[2001:db8::1]:47811", "100.128.0.1:47811", "1.2.3:47811"] {
            #expect(!PairingInvitation.isValidHostPort(bad), "\(bad)")
        }
    }

    @Test func pairingWindowIsSingleUseAndExpires() {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000) }
        let clock = Clock()
        let window = PairingWindow(lifetime: 120, maxFailedAttempts: 3, now: { clock.now })
        let inv = window.open(addresses: ["10.0.0.2:47811"], hostFingerprint: "fp", displayName: "Mac")
        let th2 = Data(repeating: 5, count: 32)
        let goodProof = MBH1.pairingProof(secret: inv.secret, th2: th2)
        #expect(!window.checkProof(Data(repeating: 0, count: 32), th2: th2))
        #expect(window.isOpen, "one failed attempt keeps the window open")
        #expect(window.checkProof(goodProof, th2: th2))
        #expect(!window.isOpen, "a successful proof consumes the secret")
        #expect(!window.checkProof(goodProof, th2: th2), "single use")

        let inv2 = window.open(addresses: ["10.0.0.2:47811"], hostFingerprint: "fp", displayName: "Mac")
        clock.now = clock.now.addingTimeInterval(121)
        #expect(!window.checkProof(MBH1.pairingProof(secret: inv2.secret, th2: th2), th2: th2), "expired")

        _ = window.open(addresses: ["10.0.0.2:47811"], hostFingerprint: "fp", displayName: "Mac")
        for _ in 0..<3 { _ = window.checkProof(Data(count: 32), th2: th2) }
        #expect(!window.isOpen, "too many failures close the window")
    }

    @Test func trustStoreLifecycle() throws {
        let storage = InMemoryTrustStorage()
        let store = TrustStore(storage: storage)
        let phone = SoftwareIdentity()
        #expect(!store.isTrusted(spki: phone.publicKeySPKI))
        let device = try store.trust(spki: phone.publicKeySPKI, name: "Vivo X300", platform: "android")
        #expect(store.isTrusted(spki: phone.publicKeySPKI))
        #expect(device.grant.allows(.screenView) && !device.grant.allows(.inputControl), "input is off by default")

        try store.setCapability(.inputControl, enabled: true, for: device.id)
        try store.setCapability(.unattended, enabled: true, for: device.id)
        #expect(store.device(id: device.id)!.grant.allows(.inputControl))
        #expect(!store.device(id: device.id)!.grant.allows(.unattended), "unattended can never be granted")

        // Persisted and reloaded.
        let reloaded = TrustStore(storage: storage)
        #expect(reloaded.isTrusted(spki: phone.publicKeySPKI))

        try store.revoke(id: device.id)
        #expect(!store.isTrusted(spki: phone.publicKeySPKI))
        #expect(store.active.isEmpty && store.all.count == 1)

        // A different key claiming the same device id is never trusted.
        #expect(!store.isTrusted(spki: SoftwareIdentity().publicKeySPKI))
    }

    @Test func backoffIsBoundedWithJitter() {
        var b = Backoff(base: 0.5, cap: 30, maxAttempts: 8)
        var delays: [TimeInterval] = []
        while let d = b.nextDelay(random: { $0.upperBound }) { delays.append(d) }
        #expect(delays == [0.5, 1, 2, 4, 8, 16, 30, 30])
        #expect(b.nextDelay() == nil, "never retries forever")
        b.reset()
        let jittered = b.nextDelay()!
        #expect(jittered >= 0 && jittered <= 0.5)
    }

    @Test func connectionStateTones() {
        #expect(ConnectionState.directConnected.isConnected && ConnectionState.relayedConnected.isConnected)
        #expect(!ConnectionState.awaitingApproval(code: "123456").isConnected)
        #expect(ConnectionState.failed(reason: "x").tone == .danger)
    }
}
