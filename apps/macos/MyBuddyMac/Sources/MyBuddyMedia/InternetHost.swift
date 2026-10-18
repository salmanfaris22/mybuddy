import Foundation
@preconcurrency import LiveKitWebRTC
import MyBuddyCore
import MyBuddyHost

/// Accepts internet sessions through MyBuddy Connect (CONNECTIVITY §3). Stays online on `/v1/signal` while
/// internet access is on; for each signed offer from a phone this Mac trusts it answers (signed), gathers ICE
/// with the server's STUN/TURN, and hands the `mb-session` data channel to the LAN host, where the usual
/// MBH1 resume handshake runs. The server only ever relays the signed introduction.
public final class InternetHost: @unchecked Sendable {
    public enum Status: Sendable, Equatable {
        case off
        case signingIn
        case online
        case offline(String)
    }

    private let adoptTransport: @Sendable (any HostTransport) -> Bool
    private let allowed: @Sendable () -> Bool
    private let identity: any DeviceIdentity
    private let trust: TrustStore
    public let client: ConnectClient
    private let loopbackAlias: String?
    private let onStatus: @Sendable (Status) -> Void
    private let onPairingRevoked: @Sendable (_ peerDeviceId: String) -> Void
    private let log: @Sendable (String) -> Void
    private let replay = RendezvousReplayGuard()
    private let lock = NSLock()
    private var signal: ConnectSignal?
    private var rendezvous: [String: Answerer] = [:]  // rid → negotiation in progress or live
    private var presenceValue: [String: Bool] = [:]
    private var turn: (servers: [ICEServerConfig], expires: Date)?

    /// `adopt` hands an opened session channel to the LAN host (`LANHostServer.adopt`); `allowed` says whether
    /// internet access is on right now (`LANHostServer.allowsInternet`).
    public init(identity: any DeviceIdentity, trust: TrustStore, client: ConnectClient, loopbackAlias: String? = nil,
                adopt: @escaping @Sendable (any HostTransport) -> Bool, allowed: @escaping @Sendable () -> Bool,
                onStatus: @escaping @Sendable (Status) -> Void = { _ in },
                onPairingRevoked: @escaping @Sendable (String) -> Void = { _ in },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        adoptTransport = adopt
        self.allowed = allowed
        self.identity = identity
        self.trust = trust
        self.client = client
        self.loopbackAlias = loopbackAlias
        self.onStatus = onStatus
        self.onPairingRevoked = onPairingRevoked
        self.log = log
        if loopbackAlias != nil { WebRTCEngine.configure(allowLoopback: true) }
    }

    /// Which paired phones are online on the server right now.
    public var presence: [String: Bool] { lock.withLock { presenceValue } }

    public func start() {
        let s = lock.withLock { () -> ConnectSignal? in
            guard signal == nil else { return nil }
            let s = ConnectSignal(client: client) { [weak self] event in self?.handle(event) }
            signal = s
            return s
        }
        guard let s else { return }
        onStatus(.signingIn)
        s.start()
    }

    public func stop() {
        let (s, all) = lock.withLock { () -> (ConnectSignal?, [Answerer]) in
            defer { signal = nil; rendezvous = [:]; presenceValue = [:] }
            return (signal, Array(rendezvous.values))
        }
        s?.stop()
        all.forEach { $0.close() }
        onStatus(.off)
    }

    /// STUN/TURN servers for internet sessions (also used for screen video), cached until 80 % of their TTL.
    public func iceServers() async -> [ICEServerConfig] {
        if let t = lock.withLock({ turn }), t.expires > Date() { return t.servers }
        guard let creds = try? await client.turnCredentials() else { return [] }
        let servers = [ICEServerConfig(urls: creds.urls, username: creds.username, credential: creds.credential)]
        lock.withLock { turn = (servers, Date().addingTimeInterval(Double(creds.ttlSeconds) * 0.8)) }
        return servers
    }

    // MARK: signaling

    private func handle(_ event: ConnectSignal.Event) {
        switch event {
        case .connected:
            onStatus(.online)
            log("CONNECT online on the signaling server")
        case .disconnected(let why):
            onStatus(.offline(why))
        case .presence(let peers):
            lock.withLock { presenceValue.merge(peers) { _, new in new } }
        case .pairingRevoked(_, let peer):
            log("CONNECT pairing with \(peer.prefix(8))… was removed on the server")
            onPairingRevoked(peer)
        case .serverError(let code, _, _):
            if code != "peer_offline" { log("CONNECT server error \(code)") }
        case .relay(let from, _, let data):
            guard let message = try? RendezvousMessage.decode(data), message.from == from, message.to == identity.deviceId else { return }
            Task { await self.receive(message) }
        }
    }

    private func receive(_ m: RendezvousMessage) async {
        switch m.kind {
        case .offer:
            await accept(m)
        case .ice:
            lock.withLock { rendezvous[m.rid] }?.addRemote(m)
        case .bye:
            lock.withLock { rendezvous.removeValue(forKey: m.rid) }?.close()
        case .answer:
            break  // the Mac never offers
        }
    }

    private func accept(_ offer: RendezvousMessage) async {
        guard allowed() else { return }
        // Only phones this Mac trusts (and hasn't revoked), with a valid fresh signature, once per rendezvous.
        guard let device = trust.device(id: offer.from), device.isActive,
              offer.verify(signerSPKI: device.publicKeySPKI, expectedTo: identity.deviceId),
              replay.firstUse(from: offer.from, rid: offer.rid, kind: .offer)
        else {
            log("CONNECT refused an offer that isn’t from a trusted phone (or is stale)")
            return
        }
        if let existing = lock.withLock({ rendezvous[offer.rid] }) { existing.close() }
        let servers = await iceServers()
        let answerer = Answerer(rid: offer.rid, selfId: identity.deviceId, peer: offer.from, deviceName: device.name, servers: servers, loopbackAlias: loopbackAlias,
                                relay: { [weak self] message in self?.send(message) },
                                adopt: { [weak self] transport in self?.adoptTransport(transport) ?? false },
                                finished: { [weak self] rid in _ = self?.lock.withLock { self?.rendezvous.removeValue(forKey: rid) } },
                                log: log)
        lock.withLock { rendezvous[offer.rid] = answerer }
        do {
            let sdp = try await answerer.answer(offerSDP: offer.sdp ?? "")
            send(try RendezvousMessage.signed(.answer, rid: offer.rid, identity: identity, to: offer.from, sdp: sdp))
            log("CONNECT answered \(device.name) (rendezvous \(offer.rid.prefix(8))…, \(servers.isEmpty ? "no TURN" : "with TURN"))")
        } catch {
            log("CONNECT couldn’t answer: \(error)")
            lock.withLock { rendezvous.removeValue(forKey: offer.rid) }?.close()
        }
    }

    private func send(_ message: RendezvousMessage) {
        guard let data = try? message.encoded() else { return }
        lock.withLock { signal }?.relay(to: message.to, data: data)
    }
}

/// One answered rendezvous: its peer connection, the `mb-session` channel and the route watcher.
final class Answerer: NSObject, @unchecked Sendable, LKRTCPeerConnectionDelegate {
    let rid: String
    private let selfId: String
    private let peer: String
    private let deviceName: String
    private let relay: @Sendable (RendezvousMessage) -> Void
    private let adopt: @Sendable (any HostTransport) -> Bool
    private let finished: @Sendable (String) -> Void
    private let log: @Sendable (String) -> Void
    private let loopbackAlias: String?
    private let lock = NSLock()
    private var pc: LKRTCPeerConnection?
    private var transport: DataChannelTransport?
    private var pendingRemote: [RendezvousMessage] = []
    private var remoteSet = false
    private var closed = false

    init(rid: String, selfId: String, peer: String, deviceName: String, servers: [ICEServerConfig], loopbackAlias: String?,
         relay: @escaping @Sendable (RendezvousMessage) -> Void, adopt: @escaping @Sendable (any HostTransport) -> Bool,
         finished: @escaping @Sendable (String) -> Void, log: @escaping @Sendable (String) -> Void) {
        self.rid = rid
        self.selfId = selfId
        self.peer = peer
        self.deviceName = deviceName
        self.relay = relay
        self.adopt = adopt
        self.finished = finished
        self.log = log
        self.loopbackAlias = loopbackAlias
        super.init()
        let config = LKRTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherContinually
        config.keyType = .ECDSA
        config.iceServers = servers.map { LKRTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        pc = WebRTCEngine.shared.factory.peerConnection(with: config, constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
                                                        delegate: self)
        // Nothing opens without a channel within 30 s.
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.lock.withLock({ self.transport == nil && !self.closed }) else { return }
            self.log("CONNECT rendezvous \(rid.prefix(8))… timed out before the channel opened")
            self.close()
        }
    }

    func answer(offerSDP: String) async throws -> String {
        guard let pc = lock.withLock({ pc }) else { throw MediaError.negotiation("closed") }
        try await pc.applyRemote(type: .offer, sdp: offerSDP)
        let queued = lock.withLock { () -> [RendezvousMessage] in
            remoteSet = true
            defer { pendingRemote = [] }
            return pendingRemote
        }
        let sdp = try await pc.makeAnswer()
        try await pc.applyLocal(type: .answer, sdp: sdp)
        for m in queued { addRemote(m) }
        return sdp
    }

    func addRemote(_ m: RendezvousMessage) {
        let ready = lock.withLock { () -> Bool in
            if !remoteSet {
                if pendingRemote.count < 64 { pendingRemote.append(m) }
                return false
            }
            return true
        }
        guard ready, let pc = lock.withLock({ pc }), let sdp = m.candidate, !sdp.isEmpty else { return }
        Task { try? await pc.addCandidate(sdp: sdp, mLineIndex: Int32(m.sdpMLineIndex ?? 0), mid: m.sdpMid) }
    }

    func close() {
        let (pc, transport) = lock.withLock { () -> (LKRTCPeerConnection?, DataChannelTransport?) in
            guard !closed else { return (nil, nil) }
            closed = true
            defer { self.pc = nil }
            return (self.pc, self.transport)
        }
        transport?.cancel()
        pc?.close()
        finished(rid)
    }

    // MARK: LKRTCPeerConnectionDelegate

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        var sdp = candidate.sdp
        if let alias = loopbackAlias { sdp = sdp.replacingOccurrences(of: " 127.0.0.1 ", with: " \(alias) ") }  // test-only (emulator)
        relay(RendezvousMessage(kind: .ice, rid: rid, from: selfId, to: peer, candidate: sdp, sdpMid: candidate.sdpMid,
                                sdpMLineIndex: Int(candidate.sdpMLineIndex)))
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {
        // The phone opens exactly one channel; anything else is refused.
        guard dataChannel.label == DataChannelTransport.label, lock.withLock({ transport == nil && !closed }) else {
            dataChannel.close()
            return
        }
        let t = DataChannelTransport(channel: dataChannel, pc: peerConnection, deviceName: deviceName) { [weak self] in self?.close() }
        lock.withLock { transport = t }
        t.whenOpen { [weak self] in
            guard let self else { return }
            if self.adopt(t) {
                self.log("CONNECT session channel open with \(self.deviceName)")
                t.watchRoute()
            } else {
                self.log("CONNECT refused the session channel (internet access off or too many handshakes)")
                self.close()
            }
        }
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) {
        if newState == .failed || newState == .closed { close() }
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
}

/// MBH1 over the `mb-session` WebRTC data channel (reliable, ordered; text = handshake, binary = frames).
final class DataChannelTransport: NSObject, HostTransport, @unchecked Sendable, LKRTCDataChannelDelegate {
    static let label = "mb-session"

    private let channel: LKRTCDataChannel
    private let pc: LKRTCPeerConnection
    private let deviceName: String
    private let onDead: @Sendable () -> Void
    private let lock = NSLock()
    private var routeValue: SessionRoute = .internetDirect
    private var routeHandler: (@Sendable (SessionRoute) -> Void)?
    private var onMessage: (@Sendable (Data, Bool) -> Void)?
    private var onClosed: (@Sendable () -> Void)?
    private var queue: DispatchQueue?
    private var early: [(Data, Bool)] = []
    private var openWaiters: [@Sendable () -> Void] = []
    private var closed = false
    private var watcher: Task<Void, Never>?

    init(channel: LKRTCDataChannel, pc: LKRTCPeerConnection, deviceName: String, onDead: @escaping @Sendable () -> Void) {
        self.channel = channel
        self.pc = pc
        self.deviceName = deviceName
        self.onDead = onDead
        super.init()
        channel.delegate = self
    }

    var remoteDescription: String { "internet (WebRTC) · \(deviceName)" }
    var route: SessionRoute { lock.withLock { routeValue } }

    func whenOpen(_ action: @escaping @Sendable () -> Void) {
        let now = lock.withLock { () -> Bool in
            if channel.readyState == .open { return true }
            openWaiters.append(action)
            return false
        }
        if now { action() }
    }

    func start(queue: DispatchQueue, onMessage: @escaping @Sendable (Data, Bool) -> Void, onClosed: @escaping @Sendable () -> Void) {
        let backlog = lock.withLock { () -> [(Data, Bool)] in
            self.queue = queue
            self.onMessage = onMessage
            self.onClosed = onClosed
            defer { early = [] }
            return early
        }
        queue.async { for (data, text) in backlog { onMessage(data, text) } }
    }

    func send(_ data: Data, text: Bool, completion: (@Sendable () -> Void)?) {
        if !lock.withLock({ closed }) { channel.sendData(LKRTCDataBuffer(data: data, isBinary: !text)) }
        completion?()
    }

    func cancel() {
        let first = lock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            watcher?.cancel()
            return true
        }
        guard first else { return }
        channel.close()
        pc.close()
        onDead()
    }

    func onRouteChange(_ handler: @escaping @Sendable (SessionRoute) -> Void) { lock.withLock { routeHandler = handler } }

    /// Reads the selected candidate pair every few seconds: a `relay` candidate on either end means TURN.
    func watchRoute() {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let entries = await self.pc.statsEntries()
                if let relayed = ICERoute.isRelayed(entries) {
                    let (changed, handler) = self.lock.withLock { () -> (Bool, (@Sendable (SessionRoute) -> Void)?) in
                        let next: SessionRoute = relayed ? .internetRelayed : .internetDirect
                        guard next != routeValue else { return (false, nil) }
                        routeValue = next
                        return (true, routeHandler)
                    }
                    if changed { handler?(relayed ? .internetRelayed : .internetDirect) }
                }
                try? await Task.sleep(for: .seconds(4))
            }
        }
        lock.withLock { watcher = task }
    }

    // MARK: LKRTCDataChannelDelegate

    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        switch dataChannel.readyState {
        case .open:
            let waiters = lock.withLock { () -> [@Sendable () -> Void] in defer { openWaiters = [] }; return openWaiters }
            waiters.forEach { $0() }
        case .closed, .closing:
            let handler = lock.withLock { () -> (@Sendable () -> Void)? in
                guard !closed else { return nil }
                return onClosed
            }
            handler?()
            cancel()
        default:
            break
        }
    }

    func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        let data = buffer.data, text = !buffer.isBinary
        let target = lock.withLock { () -> (DispatchQueue, @Sendable (Data, Bool) -> Void)? in
            guard let queue, let onMessage else {
                if early.count < 16 { early.append((data, text)) }
                return nil
            }
            return (queue, onMessage)
        }
        if let (queue, deliver) = target { queue.async { deliver(data, text) } }
    }
}
