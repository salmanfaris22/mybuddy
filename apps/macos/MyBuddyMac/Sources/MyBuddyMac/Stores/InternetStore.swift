import Foundation
import MyBuddyCore
import MyBuddyHost
import MyBuddyMedia
import Observation

/// Internet access through the user's own MyBuddy Connect server (docs/CONNECTIVITY.md §3): signs this Mac in,
/// stays reachable on the signaling socket while turned on, offers internet access to phones connected over
/// Wi-Fi/Tailscale and registers the pairing once the phone agrees.
@MainActor
@Observable
final class InternetStore {
    @ObservationIgnored var app: AppModel!
    let demo: Bool

    enum Status: Equatable {
        case off
        case signingIn
        case online
        case offline(String)
        case failed(String)

        var title: String {
            switch self {
            case .off: "Off"
            case .signingIn: "Signing in…"
            case .online: "Online"
            case .offline: "Reconnecting to the server"
            case .failed: "Error"
            }
        }
    }

    private(set) var status: Status = .off
    var serverInput = ""
    /// Phones that were offered internet access in their current session (device id → statement time).
    private(set) var offered: [String: String] = [:]
    private(set) var lastMessage: String?
    @ObservationIgnored private var host: InternetHost?
    @ObservationIgnored let hostRef = InternetHostRef()

    init(demo: Bool) {
        self.demo = demo
        if demo {
            // Preview data (DemoData.settings): a configured server with the demo phone enrolled.
            status = .online
            serverInput = "https://connect.example.com"
        }
    }

    var isOn: Bool { status != .off }
    var serverLabel: String { ConnectServerURL.normalize(app.settings.connectServer)?.host ?? "not set" }
    func isEnrolled(_ deviceId: String) -> Bool { app.settings.connectEnrollments[deviceId] != nil }

    func startIfNeeded() {
        serverInput = app.settings.connectServer
        if demo {
            status = app.settings.allowInternet ? .online : .off
            return
        }
        if app.settings.allowInternet { Task { await turnOn() } }
    }

    /// Validates the address, signs in and goes online. The setting stays on across launches.
    func turnOn() async {
        guard !demo else { status = .online; return }
        guard let url = ConnectServerURL.normalize(serverInput.isEmpty ? app.settings.connectServer : serverInput) else {
            status = .failed("Enter your server’s https:// address (no path).")
            return
        }
        guard let identity = app.identity else {
            status = .failed("This Mac’s identity isn’t available.")
            return
        }
        app.settings.connectServer = url.absoluteString
        serverInput = url.absoluteString
        status = .signingIn
        let client = ConnectClient(server: url, identity: identity)
        do {
            _ = try await client.token()  // registers on first use, then answers a signed challenge
        } catch {
            status = .failed(Self.describe(error))
            app.activityLog.record(.security, "Couldn’t sign in to MyBuddy Connect", detail: Self.describe(error))
            return
        }
        host?.stop()
        let serverRef = app.serverRef
        let internet = InternetHost(identity: identity, trust: app.trust, client: client,
                                    adopt: { transport in serverRef.server?.adopt(transport) ?? false },
                                    allowed: { serverRef.server?.allowsInternet ?? false },
                                    onStatus: { [weak self] s in Task { @MainActor in self?.hostStatus(s) } },
                                    onPairingRevoked: { [weak self] peer in Task { @MainActor in self?.pairingRevoked(peer) } },
                                    log: { line in NSLog("%@", line) })
        host = internet
        hostRef.host = internet
        app.settings.allowInternet = true
        app.connection.startIfNeeded()
        serverRef.server?.setAllowInternet(true)
        internet.start()
        app.activityLog.record(.security, "Turned on internet access", detail: "Through \(url.host ?? url.absoluteString)")
        offerToConnectedPhones()
    }

    func turnOff() {
        app.settings.allowInternet = false
        app.serverRef.server?.setAllowInternet(false)
        host?.stop()
        host = nil
        hostRef.host = nil
        offered = [:]
        status = .off
        app.activityLog.record(.security, "Turned off internet access", detail: "Internet sessions were ended; Wi-Fi and Tailscale still work")
    }

    private func hostStatus(_ s: InternetHost.Status) {
        guard app.settings.allowInternet else { return }
        switch s {
        case .off: status = .off
        case .signingIn: status = .signingIn
        case .online:
            status = .online
            offerToConnectedPhones()  // phones that connected while the server was unreachable
        case .offline(let why): status = .offline(why)
        }
    }

    /// The phone (or this Mac elsewhere) removed the pairing on the server: forget the enrolment here too.
    private func pairingRevoked(_ peer: String) {
        guard app.settings.connectEnrollments.removeValue(forKey: peer) != nil else { return }
        let name = app.trust.device(id: peer)?.name ?? "A phone"
        app.activityLog.record(.security, "Internet access removed for \(name)", detail: "The pairing was revoked on the server")
    }

    // MARK: enrolment

    func sessionsChanged(_ sessions: [ActiveSessionInfo]) {
        let live = Set(sessions.map(\.deviceId))
        offered = offered.filter { live.contains($0.key) }
        if app.settings.allowInternet { offerToConnectedPhones() }
    }

    /// Offers internet access to phones connected over Wi-Fi/Tailscale that aren't enrolled yet (once per session).
    private func offerToConnectedPhones() {
        // Only while this Mac is actually online on the server: an offer the phone can't complete helps nobody.
        guard app.settings.allowInternet, status == .online, let url = ConnectServerURL.normalize(app.settings.connectServer),
              let identity = app.identity else { return }
        for s in app.connection.sessions where s.route == .localNetwork || s.route == .tailscale {
            guard !isEnrolled(s.deviceId), offered[s.deviceId] == nil else { continue }
            let createdAt = ConnectTime.format(Date())
            offered[s.deviceId] = createdAt
            app.connection.push(OutgoingEvent(.connectOffer, ["serverUrl": .string(url.absoluteString), "hostDeviceId": .string(identity.deviceId),
                                                              "createdAt": .string(createdAt)]), toSession: s.id)
        }
    }

    /// `connect.enroll`: the phone agreed and signed. Check its signature, co-sign and register the pairing.
    func handleEnroll(_ e: Envelope, device: TrustedDevice) async -> [OutgoingEvent] {
        func refuse(_ code: String, _ message: String) -> [OutgoingEvent] {
            [OutgoingEvent(.error, ["code": .string(code), "message": .string(message), "retryable": .bool(false)], replyTo: e.sequence)]
        }
        guard let createdAt = e.payload["createdAt"]?.stringValue, offered[device.id] == createdAt,
              e.payload["clientDeviceId"]?.stringValue == device.id,
              let signature = e.payload["clientSignature"]?.stringValue.flatMap(Base64URL.decode),
              let identity = app.identity, let url = ConnectServerURL.normalize(app.settings.connectServer),
              let client = host?.client
        else { return refuse("connect_not_offered", "This Mac didn’t offer internet access in this session.") }
        let statement = ConnectStatements.pairing(hostDeviceId: identity.deviceId, clientDeviceId: device.id, createdAt: createdAt)
        guard IdentityMath.verify(spki: device.publicKeySPKI, message: statement, derSignature: signature) else {
            return refuse("bad_signature", "The phone’s signature didn’t verify.")
        }
        do {
            let pairingId = try await client.registerPairing(clientDeviceId: device.id, createdAt: createdAt, clientSignature: signature)
            app.settings.connectEnrollments[device.id] = pairingId
            offered[device.id] = nil
            app.activityLog.record(.pairing, "Internet access enabled for \(device.name)", detail: "Through \(url.host ?? url.absoluteString)")
            return [OutgoingEvent(.connectEnrolled, ["pairingId": .string(pairingId), "serverUrl": .string(url.absoluteString)], replyTo: e.sequence)]
        } catch {
            lastMessage = Self.describe(error)
            return refuse("connect_failed", "Couldn’t register with the server: \(Self.describe(error))")
        }
    }

    /// Removes a phone's internet access on the server (it keeps working on Wi-Fi and Tailscale).
    func removeAccess(for deviceId: String) {
        guard let pairingId = app.settings.connectEnrollments[deviceId] else { return }
        app.settings.connectEnrollments[deviceId] = nil
        let client = host?.client
        Task {
            try? await client?.revokePairing(id: pairingId)
        }
        app.activityLog.record(.security, "Removed internet access for a phone", detail: "Pairing \(pairingId.prefix(10))… revoked on the server")
    }

    /// STUN/TURN servers for a session's screen video (only internet sessions use them).
    nonisolated static func iceProvider(hostRef: InternetHostRef, serverRef: ServerRef) -> @Sendable (String) async -> [ICEServerConfig] {
        { sessionId in
            let route = serverRef.server?.activeSessions.first { $0.id == sessionId }?.route
            guard route == .internetDirect || route == .internetRelayed, let host = hostRef.host else { return [] }
            return await host.iceServers()
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case ConnectError.server(_, let message, _): message
        case ConnectError.transport(let why): why
        case ConnectError.invalid(let why): why
        case ConnectError.notConfigured: "Not set up"
        default: "\(error)"
        }
    }
}

/// Thread-safe handle to the running internet host (read from WebRTC threads).
final class InternetHostRef: @unchecked Sendable {
    private let lock = NSLock()
    private var value: InternetHost?
    var host: InternetHost? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
