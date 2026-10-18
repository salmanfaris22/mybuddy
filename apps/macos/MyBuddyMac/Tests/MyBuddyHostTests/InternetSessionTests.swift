import Foundation
import Testing
import MyBuddyCore
@testable import MyBuddyHost

/// Internet sessions: MBH1 over an adopted transport (in production a WebRTC data channel opened through
/// MyBuddy Connect). Same handshake and rules as the LAN — resume only, internet access must be on.
@Suite("Internet sessions over adopted transports")
struct InternetSessionTests {
    /// An in-memory transport: what the Mac sends is readable in order, test input is delivered on its queue.
    final class MemoryTransport: HostTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var routeValue: SessionRoute
        private var handler: (@Sendable (SessionRoute) -> Void)?
        private var deliver: (@Sendable (Data, Bool) -> Void)?
        private var queue: DispatchQueue?
        private(set) var cancelled = false
        let output: AsyncStream<(Data, Bool)>
        private let continuation: AsyncStream<(Data, Bool)>.Continuation

        init(route: SessionRoute = .internetDirect) {
            routeValue = route
            (output, continuation) = AsyncStream.makeStream()
        }

        var remoteDescription: String { "memory" }
        var route: SessionRoute { lock.withLock { routeValue } }

        func start(queue: DispatchQueue, onMessage: @escaping @Sendable (Data, Bool) -> Void, onClosed: @escaping @Sendable () -> Void) {
            lock.withLock {
                self.queue = queue
                deliver = onMessage
            }
        }

        func send(_ data: Data, text: Bool, completion: (@Sendable () -> Void)?) {
            continuation.yield((data, text))
            completion?()
        }

        func cancel() {
            lock.withLock { cancelled = true }
            continuation.finish()
        }

        func onRouteChange(_ handler: @escaping @Sendable (SessionRoute) -> Void) { lock.withLock { self.handler = handler } }

        func input(_ data: Data, text: Bool) {
            let (q, d) = lock.withLock { (queue, deliver) }
            q?.async { d?(data, text) }
        }

        func changeRoute(_ route: SessionRoute) {
            let h = lock.withLock { () -> (@Sendable (SessionRoute) -> Void)? in
                routeValue = route
                return handler
            }
            h?(route)
        }
    }

    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ActivityEvent] = []
        func add(_ e: ActivityEvent) { lock.withLock { items.append(e) } }
        var titles: [String] { lock.withLock { items.map(\.title) } }
    }

    private let window = PairingWindow()

    private func makeServer(log: Log) -> (LANHostServer, SoftwareIdentity, TrustStore) {
        let host = SoftwareIdentity()
        let trust = TrustStore(storage: InMemoryTrustStorage())
        let handlers = LANHostHandlers(approvePairing: { _ in PermissionGrant() }, handle: { _, _, _ in [] }, record: { log.add($0) })
        // The listener isn't needed: adopted transports bypass it.
        return (LANHostServer(identity: host, hostName: "Test Mac", trust: trust, pairingWindow: window, handlers: handlers), host, trust)
    }

    /// Runs the phone side of MBH1 over `t`; returns the session.
    private func handshake(_ t: MemoryTransport, phone: SoftwareIdentity, host: SoftwareIdentity, mode: MBH1.Mode = .resume,
                           secret: Data? = nil) async throws -> SecureSession? {
        var iterator = t.output.makeAsyncIterator()
        var client = MBH1Client(mode: mode, identity: phone, clientName: "Vivo X300", platform: "android",
                                pinnedHostFingerprint: host.fingerprint, pairingSecret: secret)
        t.input(client.makeHello(), text: true)
        guard let (hostHello, isText) = await iterator.next(), isText else { return nil }
        let (reply, result) = try client.handleHost(hostHello)
        t.input(reply, text: true)
        var session = SecureSession(role: .phone, keys: result.keys)
        let request = try session.seal(.sessionRequest, payload: ["requestedCapabilities": .array([.string("health.read")]),
                                                                  "protocolVersions": .array([.int(1)]), "features": .array([])])
        t.input(request.frame, text: false)
        guard let (frame, text) = await iterator.next(), !text else { return nil }
        let approved = try session.open(frame)
        #expect(approved.type == .sessionApproved)
        return session
    }

    @Test func adoptedSessionsCarryTheirRouteAndFollowTheInternetSwitch() async throws {
        let log = Log()
        let (server, host, trust) = makeServer(log: log)
        let phone = SoftwareIdentity()
        try trust.trust(spki: phone.publicKeySPKI, name: "Vivo X300", platform: "android")

        // Off by default: refused before any handshake.
        let refused = MemoryTransport()
        #expect(server.adopt(refused) == false)
        #expect(refused.cancelled)

        server.setAllowInternet(true)
        let t = MemoryTransport()
        #expect(server.adopt(t))
        _ = try await handshake(t, phone: phone, host: host)
        #expect(server.activeSessions.first?.route == .internetDirect)
        #expect(server.activeSessions.first?.route.allowsFileTransfer == true)

        // ICE moving to a TURN relay is reflected in the session (file transfer then stays off).
        t.changeRoute(.internetRelayed)
        #expect(server.activeSessions.first?.route == .internetRelayed)
        #expect(server.activeSessions.first?.route.allowsFileTransfer == false)

        // Turning internet access off ends internet sessions at once.
        server.setAllowInternet(false)
        for _ in 0..<50 where !server.activeSessions.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(server.activeSessions.isEmpty)
        #expect(t.cancelled)
    }

    @Test func pairingAndUnknownPhonesAreRefusedOverTheInternet() async throws {
        let log = Log()
        let (server, host, _) = makeServer(log: log)
        server.setAllowInternet(true)

        // Pair mode needs the QR on the local network: refused over the internet even with the right code.
        let invitation = window.open(addresses: ["192.168.1.20:47811"], hostFingerprint: host.fingerprint, displayName: "Test Mac")
        let pairing = MemoryTransport()
        #expect(server.adopt(pairing))
        _ = try? await handshake(pairing, phone: SoftwareIdentity(), host: host, mode: .pair, secret: invitation.secret)
        for _ in 0..<50 where !pairing.cancelled { try await Task.sleep(for: .milliseconds(20)) }
        #expect(pairing.cancelled)
        #expect(log.titles.contains("Refused pairing over the internet"))

        // An untrusted phone in resume mode is refused like on the LAN.
        let stranger = MemoryTransport()
        #expect(server.adopt(stranger))
        _ = try? await handshake(stranger, phone: SoftwareIdentity(), host: host)
        for _ in 0..<50 where !stranger.cancelled { try await Task.sleep(for: .milliseconds(20)) }
        #expect(stranger.cancelled)
        #expect(server.activeSessions.isEmpty)
        #expect(log.titles.contains("Refused unknown or revoked device"))
    }
}
