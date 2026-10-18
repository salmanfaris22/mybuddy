import AppKit
import Foundation
import MyBuddyCore
import MyBuddyHost
import Observation

@MainActor
@Observable
final class ConnectionStore {
    @ObservationIgnored var app: AppModel!
    let demo: Bool

    private(set) var serverState: LANHostServer.State = .stopped
    private(set) var sessions: [ActiveSessionInfo] = []
    private(set) var trustedDevices: [TrustedDevice] = []
    private(set) var invitation: PairingInvitation?
    private(set) var tailscale = TailscaleStatus(state: .notInstalled, appURL: nil)
    var pendingApproval: PairingApprovalRequest?
    var showPairingSheet = false
    private var approvalContinuation: CheckedContinuation<PermissionGrant?, Never>?
    private var server: LANHostServer?
    private var lastInputWarning = Date.distantPast
    /// The Mac's own ping to each connected phone (session id → ms), refreshed while sessions exist.
    private(set) var roundTrips: [String: Int] = [:]
    @ObservationIgnored private var pingTask: Task<Void, Never>?
    private var cachedApps: [InstalledApp] = []

    init(demo: Bool) { self.demo = demo }

    var hasTrustedDevice: Bool { trustedDevices.contains(where: \.isActive) }
    var primaryDevice: TrustedDevice? { trustedDevices.first(where: \.isActive) }
    var activeSession: ActiveSessionInfo? { sessions.first }
    /// This Mac's measured round trip to the connected phone, once the phone has answered a probe.
    var activeRoundTripMs: Int? { activeSession.flatMap { roundTrips[$0.id] } }

    /// "Connected · Wi-Fi" / "· Tailscale" / "· Internet" while a phone is connected, else the connection state.
    var statusTitle: String {
        guard let s = activeSession else { return connectionState.title }
        let route = switch s.route {
        case .localNetwork: "Connected · Wi-Fi"
        case .tailscale: "Connected · Tailscale"
        case .internetDirect: "Connected · Internet"
        case .internetRelayed: "Connected · Internet (relayed)"
        }
        return activeRoundTripMs.map { "\(route) · \($0) ms" } ?? route
    }

    /// Polls the host's per-session round-trip measurements (probes go out every heartbeat interval).
    private func updatePingPolling() {
        guard !sessions.isEmpty else {
            pingTask?.cancel()
            pingTask = nil
            roundTrips = [:]
            return
        }
        guard pingTask == nil else { return }
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, let server = self.server else { continue }
                var next: [String: Int] = [:]
                for s in self.sessions { next[s.id] = server.roundTripMs(session: s.id) }
                if next != self.roundTrips { self.roundTrips = next }
            }
        }
    }

    func refreshTailscale() {
        tailscale = demo ? TailscaleStatus(state: .connected(Tailnet.Interface(name: "utun4", ipv4: "100.101.102.103", ipv6: "fd7a:115c:a1e0::4f2b")), appURL: nil)
            : TailscaleStatus.current()
    }

    func setAllowTailscale(_ allow: Bool) {
        app.settings.allowTailscale = allow
        server?.setAllowTailnet(allow)
        app.activityLog.record(.security, allow ? "Allowed connections over Tailscale" : "Turned off connections over Tailscale",
                               detail: allow ? "Paired phones can reach this Mac through your tailnet" : "Tailnet sessions were ended")
    }

    var connectionState: ConnectionState {
        if demo { return sessions.isEmpty ? .disconnected : .directConnected }
        if pendingApproval != nil { return .awaitingApproval(code: pendingApproval!.verificationCode) }
        if invitation != nil { return .pairing }
        if !sessions.isEmpty { return .directConnected }
        switch serverState {
        case .listening: return hasTrustedDevice ? .disconnected : .offline
        case .failed(let why): return .failed(reason: why)
        case .stopped: return .offline
        }
    }

    func reloadDevices() {
        trustedDevices = app.trust.all
        if demo { sessions = DemoData.sessions(for: trustedDevices) }
    }

    // MARK: Server lifecycle

    func startIfNeeded() {
        reloadDevices()
        guard !demo, server == nil, app.settings.acceptConnections, hasTrustedDevice || invitation != nil, let identity = app.identity else { return }
        start(identity: identity, port: 47811)
    }

    private func start(identity: any DeviceIdentity, port: UInt16) {
        var config = LANHostServer.Configuration()
        config.port = port
        config.features = ["screen"]
        config.allowTailnet = app.settings.allowTailscale
        let s = LANHostServer(identity: identity, hostName: app.hostName, trust: app.trust, pairingWindow: app.pairingWindow,
                              handlers: makeHandlers(), configuration: config)
        s.onStateChange = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.serverState = state
                // If the preferred port is taken, fall back to any free port.
                if case .failed = state, port != 0 {
                    self.server?.stop()
                    self.server = nil
                    self.start(identity: identity, port: 0)
                }
            }
        }
        do {
            try s.start()
            server = s
            app.serverRef.server = s
            s.setAllowInternet(app.internet.isOn)
        } catch {
            serverState = .failed("\(error)")
        }
    }

    func stopServer() {
        server?.stop()
        server = nil
        app.serverRef.server = nil
        serverState = .stopped
    }

    // MARK: Pairing

    func openPairing() {
        guard !demo else {
            invitation = DemoData.invitation
            showPairingSheet = true
            return
        }
        guard let identity = app.identity else { return }
        if server == nil { start(identity: identity, port: 47811) }
        showPairingSheet = true
        Task {
            for _ in 0..<50 {
                if case .listening = serverState { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            let port = server?.boundPort ?? 47811
            var addresses = SystemHealthCollector.lanIPv4Addresses().prefix(3).map { "\($0):\(port)" }
            // With Tailscale on, the code also carries this Mac's tailnet address so the phone can connect from anywhere.
            refreshTailscale()
            if app.settings.allowTailscale, let tailnet = tailscale.address { addresses.append("\(tailnet):\(port)") }
            invitation = app.pairingWindow.open(addresses: addresses.isEmpty ? ["127.0.0.1:\(port)"] : Array(addresses),
                                                hostFingerprint: identity.fingerprint, displayName: app.hostName)
            app.activityLog.record(.pairing, "Pairing window opened", detail: "Single-use code, expires in 2 minutes")
        }
    }

    func closePairing() {
        app.pairingWindow.close()
        invitation = nil
        showPairingSheet = false
        if pendingApproval != nil { decline() }
    }

    /// Called by the server; suspends until the user decides (or the server's timeout cancels it).
    nonisolated func requestApproval(_ request: PairingApprovalRequest) async -> PermissionGrant? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<PermissionGrant?, Never>) in
                Task { @MainActor in
                    self.approvalContinuation?.resume(returning: nil)
                    self.approvalContinuation = c
                    self.pendingApproval = request
                    self.showPairingSheet = true
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        } onCancel: {
            Task { @MainActor in self.resolveApproval(nil) }
        }
    }

    func approve(grant: PermissionGrant = PermissionGrant()) {
        resolveApproval(grant)
        app.pairingWindow.close()
        invitation = nil
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            reloadDevices()
        }
    }

    func decline() { resolveApproval(nil) }

    private func resolveApproval(_ grant: PermissionGrant?) {
        approvalContinuation?.resume(returning: grant)
        approvalContinuation = nil
        pendingApproval = nil
        if grant != nil { showPairingSheet = false }
    }

    // MARK: Devices & permissions

    func revoke(_ device: TrustedDevice) {
        try? app.trust.revoke(id: device.id)
        app.internet.removeAccess(for: device.id)
        server?.disconnect(deviceId: device.id, reason: "revoked")
        app.activityLog.record(.security, "Revoked \(device.name)", detail: "The phone can no longer connect")
        reloadDevices()
    }

    func forget(_ device: TrustedDevice) {
        try? app.trust.remove(id: device.id)
        app.internet.removeAccess(for: device.id)
        reloadDevices()
    }

    func setCapability(_ capability: Capability, enabled: Bool, for device: TrustedDevice) {
        try? app.trust.setCapability(capability, enabled: enabled, for: device.id)
        // A change takes effect immediately: the phone reconnects on its own and gets the new grant (a newly allowed
        // feature such as Shared notes or Coding agents works without restarting anything on the phone).
        server?.disconnect(deviceId: device.id, reason: "user")
        app.activityLog.record(.security, "\(enabled ? "Allowed" : "Removed") “\(capability.title)” for \(device.name)")
        reloadDevices()
    }

    /// Phones learn shared folders and agent folders when a session starts: reconnect the ones that use them so a
    /// change shows up on the phone right away (they reconnect on their own).
    func refreshSessions(using capability: Capability) {
        for s in sessions where s.grantedCapabilities.contains(capability) { server?.disconnect(deviceId: s.deviceId, reason: "user") }
    }

    func emergencyStop() {
        server?.closeAll(reason: "emergency_stop")
        app.pairingWindow.close()
        invitation = nil
        if demo { sessions = [] }
    }

    func push(_ event: OutgoingEvent, toSession id: String) { server?.send(event, toSession: id) }

    // MARK: Request routing (already authorized by capability in the server)

    private func makeHandlers() -> LANHostHandlers {
        let folders: FolderAccessStore = app.folders
        let transfers: TransferService = app.files.transferService
        let agents: PhoneAgentDirectory = app.ai.phoneAgents
        return LANHostHandlers(
            approvePairing: { [weak self] request in await self?.requestApproval(request) ?? nil },
            handle: { [weak self] envelope, device, granted in
                // File chunks are handled right here on the connection's queue (thread-safe service), so big
                // transfers never run disk IO on the main thread.
                switch envelope.type {
                case .fileOffer, .fileStart, .fileChunk, .fileAck, .filePause, .fileResume, .fileCancel, .fileComplete, .fileError:
                    return transfers.handle(envelope, deviceName: device.name)
                default:
                    return await self?.route(envelope, device: device, granted: granted) ?? []
                }
            },
            sessionsChanged: { [weak self] sessions in
                Task { @MainActor in
                    guard let self else { return }
                    self.sessions = sessions
                    self.updatePingPolling()
                    self.app.updateStayAwake()
                    self.app.screenShare.sessionsChanged(sessions)
                    self.app.files.sessionsChanged(sessions)
                    self.app.internet.sessionsChanged(sessions)
                    self.app.notes.sessionsChanged(sessions)
                    self.app.injector.setEnabled(sessions.contains { $0.grantedCapabilities.contains(.inputControl) })
                    self.reloadDevices()
                }
            },
            record: { [weak self] event in Task { @MainActor in self?.app.activityLog.record(event) } },
            sessionExtras: { _, granted in
                var extras: [String: JSONValue] = [:]
                if granted.contains(.filesBrowse) {
                    extras["sharedFolders"] = .array(folders.all.prefix(32).map {
                        .object(["rootId": .string($0.id), "name": .string(String($0.displayName.prefix(255)))])
                    })
                }
                if granted.contains(.aiAgent) { extras.merge(agents.sessionExtras) { a, _ in a } }
                return extras
            })
    }

    private func error(_ code: String, _ message: String, _ e: Envelope) -> [OutgoingEvent] {
        [OutgoingEvent(.error, ["code": .string(code), "message": .string(message), "retryable": .bool(false)], replyTo: e.sequence)]
    }

    func route(_ e: Envelope, device: TrustedDevice, granted: Set<Capability>) async -> [OutgoingEvent] {
        switch e.type {
        case .healthSnapshotRequest:
            guard let snapshot = await app.health.snapshotForPeer() else { return error("unavailable", "Health data is not available right now.", e) }
            let redacted = HealthReport.redacted(snapshot, options: app.settings.redaction)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(redacted), let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                return error("internal", "Could not encode health data.", e)
            }
            return [OutgoingEvent(.healthSnapshotResult, ["snapshot": value], replyTo: e.sequence)]

        case .hostAppList:
            if cachedApps.isEmpty { cachedApps = WorkspaceAppCatalog.installedApps() }
            let limit = Int(e.payload["limit"]?.intValue ?? 50)
            let apps = WorkspaceAppCatalog.search(e.payload["query"]?.stringValue ?? "", in: cachedApps, limit: min(limit, 200))
            return [OutgoingEvent(.hostAppList, ["apps": .array(apps.map { .object(["bundleId": .string($0.bundleId), "name": .string(String($0.name.prefix(255))),
                                                                                  "isRunning": .bool(WorkspaceAppCatalog.isRunning($0.bundleId))]) })], replyTo: e.sequence)]

        case .hostAppOpen:
            let bundleId = e.payload["bundleId"]?.stringValue ?? ""
            let status = await WorkspaceAppCatalog.open(bundleId: bundleId)
            app.activityLog.record(.session, "\(device.name) opened an app", detail: "\(bundleId): \(status)")
            return [OutgoingEvent(.hostAppOpen, ["bundleId": .string(bundleId), "status": .string(status)], replyTo: e.sequence)]

        case .hostFileList:
            let rootId = e.payload["rootId"]?.stringValue ?? "", path = e.payload["path"]?.stringValue ?? ""
            do {
                let entries = try app.folders.list(rootId: rootId, path: path)
                return [OutgoingEvent(.hostFileList, ["rootId": .string(rootId), "path": .string(path), "entries": .array(entries.map(JSONValue.object))], replyTo: e.sequence)]
            } catch {
                return self.error("path_denied", "That path is outside the folders you shared.", e)
            }

        case .hostFileOpen:
            let rootId = e.payload["rootId"]?.stringValue ?? "", path = e.payload["path"]?.stringValue ?? ""
            let status = app.folders.open(rootId: rootId, path: path)
            app.activityLog.record(.session, "\(device.name) opened a shared file", detail: status)
            return [OutgoingEvent(.hostFileOpen, ["rootId": .string(rootId), "path": .string(path), "status": .string(status)], replyTo: e.sequence)]

        case .fileRequest:
            return app.files.handleFileRequest(e, device: device, granted: granted)

        case .connectEnroll:
            return await app.internet.handleEnroll(e, device: device)

        case .notificationPosted, .notificationRemoved:
            app.notifications.handle(e, device: device)
            return []

        case .clipboardOffer, .clipboardContent, .clipboardRequest, .clipboardApplied, .clipboardPaused:
            return app.files.handlePeerClipboard(e, device: device)

        case .notesIndex, .notesPut:
            return app.notes.handle(e)

        case .aiRequest:
            return await app.ai.handlePeerRequest(e, device: device, granted: granted)

        case .aiCancel:
            app.ai.cancelPeer(requestId: e.payload["requestId"]?.stringValue)
            return []

        case .voiceTranscript, .voiceIntentApproved, .voiceStarted, .voiceCancelled:
            return await app.voice.handlePeer(e, device: device, granted: granted)

        case .inputPointer, .inputButton, .inputScroll, .inputKey, .inputText:
            return handleInput(e)

        case .screenStart, .screenUpdate, .screenStop, .webrtcAnswer, .webrtcIce:
            return await app.screenShare.handle(e, device: device)

        default:
            return error("unsupported", "This Mac doesn’t handle \(e.type.rawValue) yet.", e)
        }
    }

    private func handleInput(_ e: Envelope) -> [OutgoingEvent] {
        guard SystemPermissions.accessibility == .granted, app.injector.isEnabled else {
            // One warning per second at most.
            guard Date().timeIntervalSince(lastInputWarning) > 1 else { return [] }
            lastInputWarning = Date()
            return error("accessibility_required", "Allow MyBuddy in System Settings → Privacy & Security → Accessibility on the Mac.", e)
        }
        // While this phone views the screen, its input lands on the display being streamed to it.
        let target = app.screenShare.controller.inputTarget(for: e.sessionId)
        guard let display = RemoteInput.targetDisplay(streamedDisplayId: target?.displayId, source: target?.source) else {
            return error("window_share_no_input", "Remote control works when a whole display is shared, not a single window.", e)
        }
        RemoteInput.apply(e, injector: app.injector, display: display)
        return []
    }
}
