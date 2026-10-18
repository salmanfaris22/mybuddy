import Foundation
import MyBuddyCore
import Network

/// A pairing request waiting for the user's decision on the Mac.
public struct PairingApprovalRequest: Sendable, Identifiable, Equatable {
    public let id = UUID()
    public let deviceName: String
    public let platform: String
    public let deviceId: String
    public let appVersion: String
    /// 6-digit code that must match the one shown on the phone.
    public let verificationCode: String
    public let remoteAddress: String

    public init(deviceName: String, platform: String, deviceId: String, appVersion: String, verificationCode: String, remoteAddress: String) {
        self.deviceName = deviceName
        self.platform = platform
        self.deviceId = deviceId
        self.appVersion = appVersion
        self.verificationCode = verificationCode
        self.remoteAddress = remoteAddress
    }
}

public struct ActiveSessionInfo: Sendable, Identifiable, Equatable {
    public let id: String
    public let deviceId: String
    public let deviceName: String
    public let platform: String
    public let startedAt: Date
    public let grantedCapabilities: Set<Capability>
    public let remoteAddress: String
    /// How the phone reached this Mac (Wi-Fi/LAN, Tailscale, or the internet — direct or via TURN).
    public let route: SessionRoute
    /// The phone reached this Mac through Tailscale (its address is in the tailnet ranges).
    public var viaTailnet: Bool { route == .tailscale }

    public init(id: String, deviceId: String, deviceName: String, platform: String, startedAt: Date, grantedCapabilities: Set<Capability>,
                remoteAddress: String, viaTailnet: Bool = false, route: SessionRoute? = nil) {
        self.id = id
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.platform = platform
        self.startedAt = startedAt
        self.grantedCapabilities = grantedCapabilities
        self.remoteAddress = remoteAddress
        self.route = route ?? (viaTailnet ? .tailscale : .localNetwork)
    }

    func with(route: SessionRoute) -> ActiveSessionInfo {
        ActiveSessionInfo(id: id, deviceId: deviceId, deviceName: deviceName, platform: platform, startedAt: startedAt,
                          grantedCapabilities: grantedCapabilities, remoteAddress: remoteAddress, route: route)
    }
}

/// A reliable, ordered, message-preserving channel to one phone that carries MBH1: text messages are the
/// handshake, binary messages are frames. The LAN listener uses WebSockets; internet sessions use a WebRTC
/// data channel (MyBuddyMedia).
public protocol HostTransport: AnyObject, Sendable {
    var remoteDescription: String { get }
    /// How this transport reaches the phone right now.
    var route: SessionRoute { get }
    /// Delivers messages in order on `queue` until the transport closes.
    func start(queue: DispatchQueue, onMessage: @escaping @Sendable (Data, _ isText: Bool) -> Void, onClosed: @escaping @Sendable () -> Void)
    func send(_ data: Data, text: Bool, completion: (@Sendable () -> Void)?)
    func cancel()
    /// Called when the route changes (e.g. ICE moving from a direct path to a TURN relay).
    func onRouteChange(_ handler: @escaping @Sendable (SessionRoute) -> Void)
}

/// The LAN listener's transport: one WebSocket over TCP.
final class WebSocketTransport: HostTransport, @unchecked Sendable {
    private let connection: NWConnection
    let route: SessionRoute
    private let lock = NSLock()
    private var closed = false

    init(_ connection: NWConnection, viaTailnet: Bool) {
        self.connection = connection
        route = viaTailnet ? .tailscale : .localNetwork
    }

    var remoteDescription: String { "\(connection.endpoint)" }

    func start(queue: DispatchQueue, onMessage: @escaping @Sendable (Data, Bool) -> Void, onClosed: @escaping @Sendable () -> Void) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.lock.withLock { self?.closed = true }
                onClosed()
            default: break
            }
        }
        connection.start(queue: queue)
        receive(onMessage: onMessage, onClosed: onClosed)
    }

    private func receive(onMessage: @escaping @Sendable (Data, Bool) -> Void, onClosed: @escaping @Sendable () -> Void) {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }
            if error != nil { return onClosed() }
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if meta?.opcode == .close { return onClosed() }
            if let data = content, !data.isEmpty { onMessage(data, meta?.opcode == .text) }
            if !self.lock.withLock({ self.closed }) { self.receive(onMessage: onMessage, onClosed: onClosed) }
        }
    }

    func send(_ data: Data, text: Bool, completion: (@Sendable () -> Void)?) {
        let meta = NWProtocolWebSocket.Metadata(opcode: text ? .text : .binary)
        let context = NWConnection.ContentContext(identifier: "mb", metadata: [meta])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in completion?() })
    }

    func cancel() {
        lock.withLock { closed = true }
        connection.cancel()
    }

    func onRouteChange(_ handler: @escaping @Sendable (SessionRoute) -> Void) {}
}

public struct OutgoingEvent: Sendable {
    public let type: EventType
    public let payload: [String: JSONValue]
    public let replyTo: Int64?
    public init(_ type: EventType, _ payload: [String: JSONValue], replyTo: Int64? = nil) {
        self.type = type
        self.payload = payload
        self.replyTo = replyTo
    }
}

/// Hooks the app provides. All authorization decisions that need a human go through `approvePairing`.
public struct LANHostHandlers: Sendable {
    public var approvePairing: @Sendable (PairingApprovalRequest) async -> PermissionGrant?
    /// Handles an already-authorized envelope (capability checked by the server) and returns replies.
    public var handle: @Sendable (Envelope, TrustedDevice, Set<Capability>) async -> [OutgoingEvent]
    public var sessionsChanged: @Sendable ([ActiveSessionInfo]) -> Void
    public var record: @Sendable (ActivityEvent) -> Void
    /// Extra `session.approved` fields for a device (e.g. `sharedFolders` when `files.browse` is granted).
    public var sessionExtras: @Sendable (TrustedDevice, Set<Capability>) -> [String: JSONValue]

    public init(approvePairing: @escaping @Sendable (PairingApprovalRequest) async -> PermissionGrant?,
                handle: @escaping @Sendable (Envelope, TrustedDevice, Set<Capability>) async -> [OutgoingEvent],
                sessionsChanged: @escaping @Sendable ([ActiveSessionInfo]) -> Void = { _ in },
                record: @escaping @Sendable (ActivityEvent) -> Void = { _ in },
                sessionExtras: @escaping @Sendable (TrustedDevice, Set<Capability>) -> [String: JSONValue] = { _, _ in [:] }) {
        self.approvePairing = approvePairing
        self.handle = handle
        self.sessionsChanged = sessionsChanged
        self.record = record
        self.sessionExtras = sessionExtras
    }
}

/// MyBuddy's local-network host: WebSocket over TCP + MBH1. Every message after the handshake is
/// encrypted and authenticated; every privileged event is checked against the device's grants.
public final class LANHostServer: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var port: UInt16 = 47811
        public var advertiseBonjour = true
        /// Bind 127.0.0.1 only (tests and the interop host). The app listens on the LAN.
        public var loopbackOnly = false
        /// Bind one specific local address (e.g. this Mac's Tailscale IP for tests); overrides `loopbackOnly`.
        public var bindHost: String?
        public var maxConcurrentHandshakes = 4
        public var handshakeTimeout: TimeInterval = 10
        public var approvalTimeout: TimeInterval = 120
        public var heartbeatIntervalMs = 5000
        /// Optional event groups this host implements, advertised in `session.approved.features`
        /// (e.g. `screen` once the streaming engine is linked) so the phone only offers what works.
        public var features: [String] = []
        /// Accept phones arriving over Tailscale (tailnet addresses). Changeable at runtime with `setAllowTailnet`.
        public var allowTailnet = true
        public init() {}
    }

    public enum State: Sendable, Equatable {
        case stopped
        case listening(port: UInt16)
        case failed(String)
    }

    public static let bonjourType = "_mybuddy._tcp"

    let identity: any DeviceIdentity
    let hostName: String
    let trust: TrustStore
    let pairingWindow: PairingWindow
    let handlers: LANHostHandlers
    let config: Configuration
    private let queue = DispatchQueue(label: "app.mybuddy.lan-host")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [UUID: HostConnection] = [:]
    private var handshaking = 0
    private var stateValue: State = .stopped
    private var allowTailnetValue: Bool
    private var allowInternetValue = false
    public var onStateChange: (@Sendable (State) -> Void)?

    public init(identity: any DeviceIdentity, hostName: String, trust: TrustStore, pairingWindow: PairingWindow,
                handlers: LANHostHandlers, configuration: Configuration = Configuration()) {
        self.identity = identity
        self.hostName = String(hostName.prefix(64))
        self.trust = trust
        self.pairingWindow = pairingWindow
        self.handlers = handlers
        config = configuration
        allowTailnetValue = configuration.allowTailnet
    }

    /// Turning Tailscale off takes effect immediately: sessions that came in over the tailnet end.
    public func setAllowTailnet(_ allow: Bool) {
        lock.withLock { allowTailnetValue = allow }
        guard !allow else { return }
        let viaTailnet = lock.withLock { connections.values.filter { $0.arrivedViaTailnet } }
        for c in viaTailnet { c.close(reason: "user") }
    }

    /// Internet sessions (MyBuddy Connect) are accepted only while this is on; turning it off ends them.
    public func setAllowInternet(_ allow: Bool) {
        lock.withLock { allowInternetValue = allow }
        guard !allow else { return }
        let internet = lock.withLock { connections.values.filter { $0.isInternet } }
        for c in internet { c.close(reason: "user") }
    }

    public var allowsInternet: Bool { lock.withLock { allowInternetValue } }

    /// Runs an MBH1 session over a transport established elsewhere (a WebRTC data channel opened through
    /// MyBuddy Connect). Same handshake limits and rules as the LAN — resume only: pairing needs the QR on
    /// the local network. Returns false (and closes the transport) when refused.
    @discardableResult
    public func adopt(_ transport: any HostTransport) -> Bool {
        guard lock.withLock({ allowInternetValue }) else {
            transport.cancel()
            return false
        }
        let allowed: Bool = lock.withLock {
            guard handshaking < config.maxConcurrentHandshakes else { return false }
            handshaking += 1
            return true
        }
        guard allowed else {
            transport.cancel()
            return false
        }
        let hc = HostConnection(server: self, transport: transport, allowsPairing: false)
        lock.withLock { connections[hc.id] = hc }
        hc.start(queue: queue)
        return true
    }

    /// The remote host of a connection, without the port (and without an IPv6 scope).
    static func remoteHost(_ endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let a): return "\(a)"
        case .ipv6(let a): return "\(a)".split(separator: "%").first.map(String.init)
        case .name(let n, _): return n
        @unknown default: return nil
        }
    }

    public var state: State { lock.withLock { stateValue } }

    private func setState(_ s: State) {
        lock.withLock { stateValue = s }
        onStateChange?(s)
    }

    public func start() throws {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = MBH1.maxFrameBytes
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.includePeerToPeer = false
        let port = config.port == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: config.port)!
        let l: NWListener
        if let bind = config.bindHost {
            params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bind), port: port)
            l = try NWListener(using: params)
        } else if config.loopbackOnly {
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
            l = try NWListener(using: params)
        } else {
            l = try NWListener(using: params, on: port)
        }
        if config.advertiseBonjour {
            let txt = NWTXTRecord(["v": "1", "fp": String(identity.fingerprint.prefix(8))])
            l.service = NWListener.Service(name: hostName, type: Self.bonjourType, txtRecord: txt)
        }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self else { return }
            switch state {
            case .ready: self.setState(.listening(port: l?.port?.rawValue ?? 0))
            case .failed(let e): self.setState(.failed("\(e)"))
            case .cancelled: self.setState(.stopped)
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        lock.withLock { listener = l }
        l.start(queue: queue)
    }

    public func stop() {
        closeAll(reason: "app_quit")
        let l = lock.withLock { () -> NWListener? in defer { listener = nil }; return listener }
        l?.cancel()
        setState(.stopped)
    }

    /// The port actually bound (useful when configured with port 0).
    public var boundPort: UInt16? {
        if case .listening(let p) = state { return p }
        return nil
    }

    private func accept(_ c: NWConnection) {
        let viaTailnet = Self.remoteHost(c.endpoint).map(Tailnet.isTailnetAddress) ?? false
        if viaTailnet, !lock.withLock({ allowTailnetValue }) {
            c.cancel()
            handlers.record(ActivityEvent(kind: .security, title: "Refused a connection over Tailscale", detail: "Tailscale is turned off in Settings → Connections"))
            return
        }
        let allowed: Bool = lock.withLock {
            guard handshaking < config.maxConcurrentHandshakes else { return false }
            handshaking += 1
            return true
        }
        guard allowed else {
            c.cancel()
            return
        }
        let hc = HostConnection(server: self, transport: WebSocketTransport(c, viaTailnet: viaTailnet), allowsPairing: true)
        lock.withLock { connections[hc.id] = hc }
        hc.start(queue: queue)
    }

    func handshakeFinished() { lock.withLock { handshaking = max(0, handshaking - 1) } }

    func remove(_ hc: HostConnection) {
        lock.withLock { _ = connections.removeValue(forKey: hc.id) }
        publishSessions()
    }

    func publishSessions() { handlers.sessionsChanged(activeSessions) }

    public var activeSessions: [ActiveSessionInfo] {
        lock.withLock { connections.values.compactMap(\.sessionInfo) }.sorted { $0.startedAt < $1.startedAt }
    }

    /// Emergency stop / quit: closes every session immediately.
    public func closeAll(reason: String) {
        let all = lock.withLock { Array(connections.values) }
        for c in all { c.close(reason: reason) }
    }

    /// Called after revoking a device: its sessions end immediately.
    public func disconnect(deviceId: String, reason: String = "revoked") {
        let matching = lock.withLock { connections.values.filter { $0.sessionInfo?.deviceId == deviceId } }
        for c in matching { c.close(reason: reason) }
    }

    /// The Mac's own round-trip measurement to a session's phone (heartbeat probes every interval), in ms.
    public func roundTripMs(session sessionId: String) -> Int? {
        lock.withLock { connections.values.first { $0.sessionInfo?.id == sessionId } }?.roundTripMs
    }

    /// Pushes an event to one session (e.g. streamed AI deltas for the phone that asked).
    public func send(_ event: OutgoingEvent, toSession sessionId: String) {
        let target = lock.withLock { connections.values.first { $0.sessionInfo?.id == sessionId } }
        target?.push(event)
    }

    /// Pushes an event to every active session that holds the needed capability.
    public func broadcast(_ event: OutgoingEvent) {
        let all = lock.withLock { Array(connections.values) }
        for c in all { c.push(event) }
    }
}

/// One phone connection (any transport): handshake → (pairing approval) → session request → active session.
final class HostConnection: @unchecked Sendable {
    let id = UUID()
    private weak var server: LANHostServer?
    private let transport: any HostTransport
    /// Pair-mode handshakes are accepted only on the local network (the QR's secret travels there).
    private let allowsPairing: Bool
    private let lock = NSLock()
    private var handshake: MBH1Host
    private var phase: Phase = .awaitingHello
    private var session: SecureSession?
    private var device: TrustedDevice?
    private var granted: Set<Capability> = []
    private var info: ActiveSessionInfo?
    private var limiter = InputRateLimiter()
    private var closed = false
    private var handshakeAccounted = false
    private var lastFrameAt = Date()
    private var handshakeResult: MBH1Host.Result?
    private var idleTimer: (any DispatchSourceTimer)?
    private var probeCount = 0
    private var probesInFlight: [String: Date] = [:]
    private var rttValue: Int?
    var roundTripMs: Int? { lock.withLock { rttValue } }
    private let jobs = SerialAsyncQueue()
    private var queue: DispatchQueue?
    var arrivedViaTailnet: Bool { transport.route == .tailscale }
    var isInternet: Bool { transport.route == .internetDirect || transport.route == .internetRelayed }

    enum Phase { case awaitingHello, awaitingClient, awaitingPairingRequest, awaitingApproval, awaitingSessionRequest, active }

    init(server: LANHostServer, transport: any HostTransport, allowsPairing: Bool) {
        self.server = server
        self.transport = transport
        self.allowsPairing = allowsPairing
        handshake = MBH1Host(identity: server.identity)
    }

    var sessionInfo: ActiveSessionInfo? { lock.withLock { info } }
    var remote: String { transport.remoteDescription }

    func start(queue: DispatchQueue) {
        self.queue = queue
        transport.onRouteChange { [weak self] route in self?.routeChanged(route) }
        transport.start(queue: queue, onMessage: { [weak self] data, isText in
            guard let self else { return }
            // Enqueued synchronously in receive order; processed strictly one at a time.
            self.jobs.enqueue { await self.process(data, isText: isText) }
        }, onClosed: { [weak self] in self?.close(reason: nil) })
        let timeout = server?.config.handshakeTimeout ?? 10
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            let stuck = self.lock.withLock { self.phase == .awaitingHello || self.phase == .awaitingClient }
            if stuck { self.close(reason: nil) }
        }
    }

    /// Releases this connection's slot in the concurrent-handshake limit exactly once.
    private func finishHandshakeAccounting() {
        let first = lock.withLock { () -> Bool in
            defer { handshakeAccounted = true }
            return !handshakeAccounted
        }
        if first { server?.handshakeFinished() }
    }

    private func routeChanged(_ route: SessionRoute) {
        let changed = lock.withLock { () -> Bool in
            guard let current = info, current.route != route else { return false }
            info = current.with(route: route)
            return true
        }
        if changed { server?.publishSessions() }
    }

    private func process(_ data: Data, isText: Bool) async {
        guard let server, !lock.withLock({ closed }) else { return }
        let phase = lock.withLock { self.phase }
        switch phase {
        case .awaitingHello:
            guard isText else { return close(reason: nil) }
            switch runHello(data) {
            case .success(let reply): sendRaw(reply, text: true)
            case .failure:
                server.handlers.record(ActivityEvent(kind: .security, title: "Rejected connection: invalid handshake", detail: remote))
                close(reason: nil)
            }
        case .awaitingClient:
            guard isText else { return close(reason: nil) }
            let verifier = MBH1Host.Verifier(
                checkPairingProof: { [window = server.pairingWindow] proof, th2 in window.checkProof(proof, th2: th2) },
                isTrusted: { [trust = server.trust] spki in trust.isTrusted(spki: spki) })
            let result = runClient(data, verifier: verifier)
            finishHandshakeAccounting()
            if case .success(let r) = result, r.mode == .pair, !allowsPairing {
                server.handlers.record(ActivityEvent(kind: .security, title: "Refused pairing over the internet", detail: "Pair on the same Wi-Fi with the QR code"))
                return close(reason: nil)
            }
            if case .failure(let error) = result {
                let title: String = switch error {
                case .notTrusted: "Refused unknown or revoked device"
                case .pairingProofInvalid: "Refused pairing attempt with a wrong or expired code"
                default: "Rejected connection: handshake failed"
                }
                server.handlers.record(ActivityEvent(kind: .security, title: title, detail: remote))
                close(reason: nil)
            }
        default:
            guard !isText else { return close(reason: nil) }
            await processFrame(data, server: server)
        }
    }

    private func processFrame(_ data: Data, server: LANHostServer) async {
        let (opened, phase) = openFrame(data)
        guard let opened else { return close(reason: nil) }
        let envelope: Envelope
        switch opened {
        case .success(let e): envelope = e
        case .failure(.protocolViolation(let p)) where p != .replayedSequence:
            send(OutgoingEvent(.error, ["code": .string(p.code), "message": .string("Message rejected"), "retryable": .bool(false)]))
            return
        case .failure:
            return close(reason: "error")
        }
        switch phase {
        case .awaitingPairingRequest:
            guard envelope.type == .pairingRequest else { return close(reason: "error") }
            await handlePairingRequest(envelope, server: server)
        case .awaitingSessionRequest:
            guard envelope.type == .sessionRequest else { return close(reason: "error") }
            handleSessionRequest(envelope, server: server)
        case .active:
            await handleActive(envelope, server: server)
        default:
            close(reason: "error")
        }
    }

    // MARK: synchronous critical sections (NSLock is not usable across suspension points)

    private func runHello(_ data: Data) -> Result<Data, HandshakeError> {
        lock.withLock {
            let r = Result { () throws(HandshakeError) -> Data in try handshake.handleHello(data) }
            if case .success = r { phase = .awaitingClient }
            return r
        }
    }

    private func runClient(_ data: Data, verifier: MBH1Host.Verifier) -> Result<MBH1Host.Result, HandshakeError> {
        lock.withLock {
            let r = Result { () throws(HandshakeError) -> MBH1Host.Result in try handshake.handleClient(data, verifier: verifier) }
            if case .success(let result) = r {
                handshakeResult = result
                session = SecureSession(role: .mac, keys: result.keys)
                phase = result.mode == .pair ? .awaitingPairingRequest : .awaitingSessionRequest
                lastFrameAt = Date()
            }
            return r
        }
    }

    private func openFrame(_ data: Data) -> (Result<Envelope, SessionError>?, Phase) {
        lock.withLock {
            guard session != nil else { return (nil, phase) }
            lastFrameAt = Date()
            return (Result { () throws(SessionError) -> Envelope in try session!.open(data) }, phase)
        }
    }

    private func handlePairingRequest(_ e: Envelope, server: LANHostServer) async {
        guard let result = lock.withLock({ handshakeResult }) else { return close(reason: "error") }
        lock.withLock { phase = .awaitingApproval }
        let request = PairingApprovalRequest(deviceName: e.payload["deviceName"]?.stringValue ?? result.clientName,
                                             platform: result.platform, deviceId: result.clientDeviceId,
                                             appVersion: e.payload["appVersion"]?.stringValue ?? "?",
                                             verificationCode: result.keys.sas, remoteAddress: remote)
        let decision = await withTimeout(server.config.approvalTimeout) { await server.handlers.approvePairing(request) }
        guard let grant = decision ?? nil else {
            server.handlers.record(ActivityEvent(kind: .pairing, title: "Pairing declined", detail: request.deviceName))
            return close(reason: nil, final: OutgoingEvent(.pairingRejected, ["reason": .string(decision == nil ? "expired" : "user_rejected")], replyTo: e.sequence))
        }
        do {
            let device = try server.trust.trust(spki: result.clientIdentityKey, name: request.deviceName, platform: result.platform, grant: grant)
            lock.withLock {
                self.device = device
                phase = .awaitingSessionRequest
            }
            send(OutgoingEvent(.pairingApproved, ["hostDeviceId": .string(server.identity.deviceId), "hostName": .string(server.hostName),
                                                  "grantedCapabilities": .array(grant.capabilities.map(\.rawValue).sorted().map(JSONValue.string))],
                               replyTo: e.sequence))
            server.handlers.record(ActivityEvent(kind: .pairing, title: "Paired with \(request.deviceName)", detail: "Verification code confirmed on the Mac"))
        } catch {
            close(reason: nil, final: OutgoingEvent(.pairingRejected, ["reason": .string("user_rejected")], replyTo: e.sequence))
        }
    }

    private func handleSessionRequest(_ e: Envelope, server: LANHostServer) {
        guard let result = lock.withLock({ handshakeResult }),
              let device = server.trust.device(id: result.clientDeviceId), device.isActive, device.publicKeySPKI == result.clientIdentityKey
        else {
            return close(reason: nil, final: OutgoingEvent(.sessionRejected, ["reason": .string("not_trusted")], replyTo: e.sequence))
        }
        let requested = (e.payload["requestedCapabilities"]?.arrayValue ?? []).compactMap { $0.stringValue.flatMap(Capability.init(rawValue:)) }
        let granted = device.grant.intersect(requested: requested)
        let info = ActiveSessionInfo(id: result.keys.sessionId, deviceId: device.id, deviceName: device.name, platform: device.platform,
                                     startedAt: Date(), grantedCapabilities: granted, remoteAddress: remote, route: transport.route)
        lock.withLock {
            self.device = device
            self.granted = granted
            self.info = info
            phase = .active
        }
        try? server.trust.touch(id: device.id)
        var approved: [String: JSONValue] = ["grantedCapabilities": .array(granted.map(\.rawValue).sorted().map(JSONValue.string)),
                                             "protocolVersion": .int(1), "features": .array(server.config.features.prefix(64).map(JSONValue.string)),
                                             "heartbeatIntervalMs": .int(Int64(server.config.heartbeatIntervalMs))]
        approved.merge(server.handlers.sessionExtras(device, granted)) { current, _ in current }
        send(OutgoingEvent(.sessionApproved, approved, replyTo: e.sequence))
        server.handlers.record(ActivityEvent(kind: .session, title: "Session started with \(device.name)",
                                             detail: granted.map(\.title).sorted().joined(separator: ", ")))
        startIdleTimer(intervalMs: server.config.heartbeatIntervalMs)
        server.publishSessions()
    }

    /// Ends the session if the phone goes silent for 3 heartbeat intervals.
    private func startIdleTimer(intervalMs: Int) {
        guard let queue else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = Double(intervalMs) / 1000
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let silent = self.lock.withLock { Date().timeIntervalSince(self.lastFrameAt) }
            if silent > 3 * interval { return self.close(reason: "timeout") }
            // Measure the round trip from this side too (the phone answers `reply: false` probes).
            let probe = self.lock.withLock { () -> String in
                self.probeCount += 1
                let p = "m\(self.probeCount)"
                self.probesInFlight = self.probesInFlight.filter { Date().timeIntervalSince($0.value) < 30 }
                self.probesInFlight[p] = Date()
                return p
            }
            self.send(OutgoingEvent(.hostHeartbeat, ["probe": .string(probe), "reply": .bool(false)]))
        }
        lock.withLock { idleTimer = timer }
        timer.resume()
    }

    private func handleActive(_ e: Envelope, server: LANHostServer) async {
        let (device, granted, allowedRate) = lock.withLock { (self.device, self.granted, limiter.allow(e.type)) }
        guard let device else { return close(reason: "error") }
        // Revocation is checked on every message, not only at session start.
        guard server.trust.device(id: device.id)?.isActive == true else { return close(reason: "revoked") }
        switch e.type {
        case .hostHeartbeat:
            if e.payload["reply"]?.boolValue == false {
                send(OutgoingEvent(.hostHeartbeat, ["probe": e.payload["probe"] ?? .string("p"), "reply": .bool(true)], replyTo: e.sequence))
            } else if let probe = e.payload["probe"]?.stringValue {
                lock.withLock {
                    if let sent = probesInFlight.removeValue(forKey: probe) { rttValue = Int((Date().timeIntervalSince(sent) * 1000).rounded()) }
                }
            }
            return
        case .sessionClosed:
            return close(reason: nil)
        default:
            break
        }
        if let needed = e.type.requiredCapability, !granted.contains(needed) {
            send(OutgoingEvent(.error, ["code": .string("not_permitted"), "message": .string("“\(needed.title)” is not enabled for this device on the Mac."),
                                        "retryable": .bool(false)], replyTo: e.sequence))
            return
        }
        guard allowedRate else { return }  // excess input is dropped
        for reply in await server.handlers.handle(e, device, granted) { send(reply) }
    }

    func push(_ event: OutgoingEvent) {
        let ok = lock.withLock { phase == .active && !closed && (event.type.requiredCapability.map(granted.contains) ?? true) }
        if ok { send(event) }
    }

    /// Seals and enqueues under one lock so frames reach the wire in sequence order even when several
    /// threads send at once (e.g. libwebrtc's ICE callbacks and the connection queue); the phone rejects
    /// a frame whose sequence is not increasing. `NWConnection.send` only enqueues, so holding the lock is cheap.
    func send(_ event: OutgoingEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, session != nil, let frame = try? session!.seal(event.type, payload: event.payload, replyTo: event.replyTo).frame else { return }
        sendRaw(frame, text: false)
    }

    private func sendRaw(_ data: Data, text: Bool, then: (@Sendable () -> Void)? = nil) {
        transport.send(data, text: text, completion: then)
    }

    /// Closes the connection. A final event (e.g. `pairing.rejected`) or, for active sessions,
    /// `session.closed` is flushed before the socket is cancelled so the peer learns why.
    func close(reason: String?, final finalEvent: OutgoingEvent? = nil) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        var goodbye: Data?
        if session != nil {
            if let finalEvent {
                goodbye = try? session!.seal(finalEvent.type, payload: finalEvent.payload, replyTo: finalEvent.replyTo).frame
            } else if phase == .active, let reason {
                goodbye = try? session!.seal(.sessionClosed, payload: ["reason": .string(reason)]).frame
            }
        }
        closed = true
        let info = self.info
        idleTimer?.cancel()
        idleTimer = nil
        lock.unlock()

        finishHandshakeAccounting()
        if let goodbye {
            sendRaw(goodbye, text: false) { [transport] in transport.cancel() }
            queue?.asyncAfter(deadline: .now() + 1) { [transport] in transport.cancel() }
        } else {
            transport.cancel()
        }
        if let server {
            server.remove(self)
            if let info {
                server.handlers.record(ActivityEvent(kind: .session, title: "Session ended with \(info.deviceName)", detail: reason))
            }
        }
    }
}

/// Runs async jobs strictly one after another, in enqueue order.
final class SerialAsyncQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func enqueue(_ job: @escaping @Sendable () async -> Void) {
        lock.withLock {
            let previous = tail
            tail = Task {
                await previous?.value
                await job()
            }
        }
    }
}

/// Runs `body` with a deadline; returns nil when the deadline passes first.
func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await body() }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
