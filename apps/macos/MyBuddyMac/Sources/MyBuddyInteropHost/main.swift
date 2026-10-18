import Foundation
import MyBuddyCore
import MyBuddyHost
import MyBuddyMedia
import MyBuddyTestSupport

// Test-only interop host: lets the Android app (emulator or a phone on USB reverse) pair with the real
// Swift host stack without the GUI. Loopback only, throw-away identity and trust, and approval is typed
// on stdin after comparing the 6-digit code — nothing is auto-approved. Never bundled into MyBuddy.app.
//
//   swift run MyBuddyInteropHost --advertise 10.0.2.2                         health.read only
//   swift run MyBuddyInteropHost --advertise 10.0.2.2 --screen test-pattern   + screen.view, streaming a
//       clearly labelled synthetic test pattern through the real WebRTC pipeline (no screen capture).
//   … --input log   also grants input.control; received input is printed, NEVER injected (no CGEvents).
//   … --files <dir>   also grants files.browse, files.transfer and clipboard.sync: <dir> is shared, uploads land in
//       <dir>/incoming (saved automatically — test host only), and a FAKE clipboard logs what arrives (the real
//       Mac clipboard is never read or written). After pairing, type `send <path>` to offer a file to the phone
//       or `clip <text>` to offer clipboard text.
//   swift run MyBuddyInteropHost --tailnet [--screen test-pattern]   listen on this Mac's Tailscale address
//       instead of loopback (needs Tailscale running; reachable from your tailnet, pairing still needs approval).
//   … --notifications   also grants notifications.mirror: notifications the phone mirrors are printed (app, preview
//       level, title/text lengths); type `alert <text>` to send a MyBuddy alert to the phone.
//   … --connect http://127.0.0.1:8787 [--connect-advertise http://10.0.2.2:8787]   internet mode through a (local)
//       MyBuddy Connect server: signs in, goes online on /v1/signal, offers internet access to the paired phone (the
//       phone must agree) and accepts internet sessions. `--connect-advertise` is the address sent to the phone (the
//       emulator reaches this Mac's loopback as 10.0.2.2). Type `lan off` to close the local listener so the phone
//       has to come back over the internet.
//
// `--advertise` is the address under which the client reaches this host's loopback (the Android
// emulator sees the host's 127.0.0.1 as 10.0.2.2); WebRTC loopback candidates are advertised under it.

setvbuf(stdout, nil, _IOLBF, 0)

var advertise = "127.0.0.1"
var port: UInt16 = 0
var testPattern = false
var tailnet = false
var logInput = false
var filesDir: URL?
var connectURL: URL?
var connectAdvertise: URL?
var mirrorNotifications = false
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let a = arguments.next() {
    switch a {
    case "--advertise": advertise = arguments.next() ?? advertise
    case "--port": port = UInt16(arguments.next() ?? "") ?? 0
    case "--screen":
        guard arguments.next() == "test-pattern" else {
            FileHandle.standardError.write(Data("only `--screen test-pattern` is supported (no screen capture in the test host)\n".utf8))
            exit(2)
        }
        testPattern = true
    case "--tailnet": tailnet = true
    case "--input":
        guard arguments.next() == "log" else {
            FileHandle.standardError.write(Data("only `--input log` is supported (the test host never injects input)\n".utf8))
            exit(2)
        }
        logInput = true
    case "--files":
        guard let path = arguments.next() else { exit(2) }
        filesDir = URL(fileURLWithPath: path).standardizedFileURL
    case "--connect":
        guard let url = arguments.next().flatMap(ConnectServerURL.normalize) else {
            FileHandle.standardError.write(Data("--connect needs https://host[:port] (or http:// on loopback)\n".utf8))
            exit(2)
        }
        connectURL = url
    case "--notifications": mirrorNotifications = true
    case "--connect-advertise":
        guard let url = arguments.next().flatMap(URL.init(string:)) else { exit(2) }
        connectAdvertise = url
    default:
        FileHandle.standardError.write(Data("usage: MyBuddyInteropHost [--advertise <ip>] [--port <n>] [--screen test-pattern] [--input log] [--files <dir>] [--tailnet] [--connect <url> [--connect-advertise <url>]]\n".utf8))
        exit(2)
    }
}

/// One stdin reader for everything: a line answers a pending pairing approval if there is one, otherwise it
/// is a command (`send <path>`, `clip <text>`).
final class Console: @unchecked Sendable {
    private let lock = NSLock()
    private var approval: CheckedContinuation<String?, Never>?
    var onCommand: (@Sendable (String) -> Void)?

    init() {
        Thread.detachNewThread { [self] in
            while let line = readLine() {
                let waiter: CheckedContinuation<String?, Never>? = lock.withLock {
                    defer { approval = nil }
                    return approval
                }
                if let waiter { waiter.resume(returning: line) } else { onCommand?(line) }
            }
        }
    }

    func nextApproval() async -> String? {
        await withCheckedContinuation { c in lock.withLock { approval = c } }
    }
}
let console = Console()

func snapshotJSON() async -> JSONValue? {
    let diagnostics = HostDiagnostics(appVersion: "interop", lanListener: .reported("Loopback interop host", source: "NWListener", at: Date()),
                                      trustedDevices: 1, activeSessions: 1)
    let snapshot = HealthReport.redacted(await SystemHealthCollector().collect(host: diagnostics), options: RedactionOptions())
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(snapshot) else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: data)
}

/// Lets handlers created before the server reach it.
final class ServerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: LANHostServer?
    private var sessions: Set<String> = []
    var server: LANHostServer? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    /// Returns the sessions that ended since the last call.
    func update(_ active: [ActiveSessionInfo]) -> Set<String> {
        lock.withLock {
            let now = Set(active.map(\.id))
            defer { sessions = now }
            return sessions.subtracting(now)
        }
    }
}

let box = ServerBox()

/// Prints the sender's measured stats every 5 s (fps, bitrate, why the encoder holds back).
final class StatsLog: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    func maybePrint(_ s: StreamStatsSample?) {
        guard let s, lock.withLock({ () -> Bool in
            guard Date().timeIntervalSince(last) >= 5 else { return false }
            last = Date()
            return true
        }) else { return }
        print("STATS sent \(s.dimensions?.description ?? "?") fps=\(s.framesPerSecond.map { String(format: "%.0f", $0) } ?? "?") " +
              "kbps=\(s.bitrateKbps.map { String(format: "%.0f", $0) } ?? "?") codec=\(s.codec ?? "?") encoder=\(s.implementation ?? "?") " +
              "limitation=\(s.qualityLimitation?.rawValue ?? "?") path=\(s.path.rawValue) rtt=\(s.roundTripMs.map { String(format: "%.0f", $0) } ?? "?")ms")
    }
}
let statsLog = StatsLog()
let unsupportedMessage = "The interop host serves health\(testPattern ? " and a test pattern" : "") only."
let grant: Set<Capability> = Set([Capability.healthRead] + (testPattern ? [.screenView] : []) + (logInput ? [.inputControl] : [])
                                 + (filesDir != nil ? [.filesBrowse, .filesTransfer, .clipboardSync] : [])
                                 + (mirrorNotifications ? [.notificationsMirror] : []))

let filesEnabled = filesDir != nil
/// The server address sent to the phone in `connect.offer` (fixed after argument parsing).
let offeredConnectURL: URL? = connectAdvertise ?? connectURL

// Files mode: a shared folder, automatic saving into <dir>/incoming, and transfer-state logging.
let folders = FolderAccessStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("mybuddy-interop-folders-\(UUID().uuidString).json"))
if let filesDir {
    let incomingDir = filesDir.appendingPathComponent("incoming")
    try? FileManager.default.createDirectory(at: incomingDir, withIntermediateDirectories: true)
    do { try folders.grant(filesDir) } catch { print("FAILED to share \(filesDir.path): \(error)"); exit(1) }
}

/// Prints each transfer state change once.
final class TransferLog: @unchecked Sendable {
    private let lock = NSLock()
    private var printed: [UUID: String] = [:]
    func show(_ items: [TransferService.Item]) {
        for item in items {
            let state: String = switch item.state {
            case .awaitingAcceptance: "offered"
            case .inProgress: "in progress"
            case .paused: "paused"
            case .verifying: "verifying"
            case .completed(let url): "completed → \(url.lastPathComponent)"
            case .failed(let why): "failed (\(why))"
            case .cancelled: "cancelled"
            }
            let changed = lock.withLock { () -> Bool in
                guard printed[item.id] != state else { return false }
                printed[item.id] = state
                return true
            }
            if changed { print("TRANSFER \(item.name) \(item.direction == .toMac ? "phone→Mac" : "Mac→phone") \(state)") }
        }
    }
}
let transferLog = TransferLog()
let transfers = TransferService(policy: .saveAutomatically, destination: (filesDir ?? FileManager.default.temporaryDirectory).appendingPathComponent("incoming"),
                                send: { event, session in box.server?.send(event, toSession: session) },
                                onChange: { transferLog.show($0) },
                                record: { print("ACTIVITY \($0.title)") },
                                sessionAllowsTransfer: { session in
                                    box.server?.activeSessions.first { $0.id == session }?.route.allowsFileTransfer ?? true
                                })

/// A fake clipboard: logs what the phone sends (length + hash prefix only) and offers typed test text.
final class FakeClipboard: @unchecked Sendable {
    private let lock = NSLock()
    private var peerOffers: [String: String] = [:]
    private var ours: (revision: String, text: String)?

    func handle(_ e: Envelope) -> [OutgoingEvent] {
        let revision = e.payload["revisionId"]?.stringValue ?? ""
        switch e.type {
        case .clipboardOffer:
            lock.withLock { peerOffers[revision] = e.payload["contentHash"]?.stringValue ?? "" }
            return [OutgoingEvent(.clipboardRequest, ["revisionId": .string(revision)], replyTo: e.sequence)]
        case .clipboardContent:
            let expected = lock.withLock { peerOffers.removeValue(forKey: revision) }
            let text = e.payload["text"]?.stringValue ?? ""
            let hash = ClipboardPolicy.hash(text)
            guard expected == hash else { print("CLIPBOARD content rejected: hash mismatch"); return [] }
            print("CLIPBOARD received \(text.count) characters (sha256 \(hash.prefix(12))…) — logged only, the Mac clipboard is untouched")
            return [OutgoingEvent(.clipboardApplied, ["revisionId": .string(revision)], replyTo: e.sequence)]
        case .clipboardRequest:
            guard let ours = lock.withLock({ ours }), ours.revision == revision else { return [] }
            return [OutgoingEvent(.clipboardContent, ["revisionId": .string(revision), "text": .string(ours.text)], replyTo: e.sequence)]
        case .clipboardApplied:
            print("CLIPBOARD the phone applied our text")
            return []
        case .clipboardPaused:
            print("CLIPBOARD the phone has clipboard sync off")
            return []
        default:
            return []
        }
    }

    func offer(_ text: String, deviceId: String) -> OutgoingEvent {
        let revision = UUID().uuidString.lowercased()
        lock.withLock { ours = (revision, text) }
        return OutgoingEvent(.clipboardOffer, ["revisionId": .string(revision), "originDeviceId": .string(deviceId),
                                               "contentHash": .string(ClipboardPolicy.hash(text)), "size": .int(Int64(text.utf8.count)), "mime": .string("text/plain")])
    }
}
let fakeClipboard = FakeClipboard()

/// Files-mode events (transfers, shared-file downloads, fake clipboard); nil for anything else.
@Sendable func filesReply(_ envelope: Envelope, deviceName: String) -> [OutgoingEvent]? {
    guard filesEnabled else { return nil }
    switch envelope.type {
    case .fileOffer, .fileStart, .fileChunk, .fileAck, .filePause, .fileResume, .fileCancel, .fileComplete, .fileError:
        return transfers.handle(envelope, deviceName: deviceName)
    case .hostFileList:
        let rootId = envelope.payload["rootId"]?.stringValue ?? "", path = envelope.payload["path"]?.stringValue ?? ""
        guard let entries = try? folders.list(rootId: rootId, path: path) else {
            print("REQUEST host.file.list \(path) → refused (outside the shared folder)")
            return [OutgoingEvent(.error, ["code": .string("path_denied"), "message": .string("That path is outside the folders you shared."),
                                           "retryable": .bool(false)], replyTo: envelope.sequence)]
        }
        print("REQUEST host.file.list \(path.isEmpty ? "/" : path) → \(entries.count) entries")
        return [OutgoingEvent(.hostFileList, ["rootId": .string(rootId), "path": .string(path), "entries": .array(entries.map(JSONValue.object))],
                              replyTo: envelope.sequence)]
    case .fileRequest:
        if box.server?.activeSessions.first(where: { $0.id == envelope.sessionId })?.route.allowsFileTransfer == false {
            print("REQUEST file.request → refused (relayed session)")
            return [OutgoingEvent(.error, ["code": .string("relayed_session"), "message": .string(TransferService.relayedMessage),
                                           "retryable": .bool(false)], replyTo: envelope.sequence)]
        }
        let rootId = envelope.payload["rootId"]?.stringValue ?? "", path = envelope.payload["path"]?.stringValue ?? ""
        guard let url = try? folders.resolve(rootId: rootId, path: path) else {
            print("REQUEST file.request \(path) → refused (outside the shared folder)")
            return [OutgoingEvent(.error, ["code": .string("path_denied"), "message": .string("That path is outside the folders you shared."),
                                           "retryable": .bool(false)], replyTo: envelope.sequence)]
        }
        print("REQUEST file.request \(path) → offering")
        let session = envelope.sessionId, requestId = envelope.payload["requestId"]?.stringValue
        Task.detached { _ = try? transfers.offerFile(at: url, toSession: session, deviceName: deviceName, requestId: requestId) }
        return []
    case .clipboardOffer, .clipboardRequest, .clipboardContent, .clipboardApplied, .clipboardPaused:
        return fakeClipboard.handle(envelope)
    default:
        return nil
    }
}

/// One line per input event; never injected.
@Sendable func describeInput(_ e: Envelope, via: String) -> String {
    let p = e.payload
    let detail: String = switch e.type {
    case .inputPointer: String(format: "x=%.3f y=%.3f", p["x"]?.numberValue ?? -1, p["y"]?.numberValue ?? -1)
    case .inputButton: "\(p["button"]?.stringValue ?? "?") \(p["action"]?.stringValue ?? "?") " + String(format: "x=%.3f y=%.3f", p["x"]?.numberValue ?? -1, p["y"]?.numberValue ?? -1)
    case .inputScroll: String(format: "dx=%.1f dy=%.1f", p["dx"]?.numberValue ?? 0, p["dy"]?.numberValue ?? 0)
    case .inputKey: "\(p["code"]?.stringValue ?? "?") \(p["modifiers"]?.arrayValue?.compactMap(\.stringValue).joined(separator: "+") ?? "")"
    case .inputText: "\(p["text"]?.stringValue?.count ?? 0) characters"
    default: ""
    }
    return "INPUT \(e.type.rawValue) \(detail) via \(via) (logged only, not injected)"
}
/// Internet mode (MyBuddy Connect): the running host, offers sent per device, enrolments made.
final class InternetState: @unchecked Sendable {
    private let lock = NSLock()
    private var hostValue: InternetHost?
    private var offers: [String: String] = [:]
    private var enrolled: [String: String] = [:]
    var host: InternetHost? {
        get { lock.withLock { hostValue } }
        set { lock.withLock { hostValue = newValue } }
    }
    func offer(_ device: String) -> String? {
        lock.withLock {
            guard offers[device] == nil, enrolled[device] == nil else { return nil }
            let at = ConnectTime.format(Date())
            offers[device] = at
            return at
        }
    }
    func takeOffer(_ device: String, createdAt: String) -> Bool { lock.withLock { offers[device] == createdAt ? (offers.removeValue(forKey: device) != nil) : false } }
    /** An offer lasts for one session (as in the Mac app): phones no longer connected are offered again next time. */
    func keepOffers(for live: Set<String>) { lock.withLock { offers = offers.filter { live.contains($0.key) } } }
    func enroll(_ device: String, pairing: String) { lock.withLock { enrolled[device] = pairing } }
}
let internetState = InternetState()

var mediaOptions = ScreenShareOptions()
mediaOptions.loopbackAlias = advertise == "127.0.0.1" ? nil : advertise
mediaOptions.autoStartTier = { session in
    box.server?.activeSessions.first { $0.id == session }?.route == .internetRelayed ? .balanced : .high
}
mediaOptions.iceProvider = { session in
    let route = box.server?.activeSessions.first { $0.id == session }?.route
    guard route == .internetDirect || route == .internetRelayed, let host = internetState.host else { return [] }
    return await host.iceServers()
}
let screen: ScreenShareController? = testPattern
    ? ScreenShareController(options: mediaOptions, permission: { true }, makeSource: { TestPatternSource() },
                            send: { event, session in
                                if event.type == .screenState { print("SCREEN state=\(event.payload["state"]?.stringValue ?? "?") \(event.payload["reason"]?.stringValue ?? "")") }
                                box.server?.send(event, toSession: session)
                            },
                            onSnapshot: { snapshot in statsLog.maybePrint(snapshot?.stats) },
                            log: { print("SCREEN \($0)") },
                            authorizeInput: { session in
                                box.server?.activeSessions.first { $0.id == session }?.grantedCapabilities.contains(.inputControl) == true
                            },
                            onInput: { envelope, _ in print(describeInput(envelope, via: "data channel")) })
    : nil

let identity = SoftwareIdentity()

/// `connect.enroll`: the phone agreed to internet access and signed; verify, co-sign, register.
@Sendable func handleEnroll(_ e: Envelope, device: TrustedDevice) async -> [OutgoingEvent] {
    func refuse(_ code: String, _ message: String) -> [OutgoingEvent] {
        print("CONNECT enrolment refused: \(code)")
        return [OutgoingEvent(.error, ["code": .string(code), "message": .string(message), "retryable": .bool(false)], replyTo: e.sequence)]
    }
    guard let host = internetState.host, let createdAt = e.payload["createdAt"]?.stringValue, e.payload["clientDeviceId"]?.stringValue == device.id,
          let signature = e.payload["clientSignature"]?.stringValue.flatMap(Base64URL.decode), internetState.takeOffer(device.id, createdAt: createdAt)
    else { return refuse("connect_not_offered", "This Mac didn’t offer internet access in this session.") }
    let statement = ConnectStatements.pairing(hostDeviceId: identity.deviceId, clientDeviceId: device.id, createdAt: createdAt)
    guard IdentityMath.verify(spki: device.publicKeySPKI, message: statement, derSignature: signature) else { return refuse("bad_signature", "Signature didn’t verify.") }
    do {
        let pairing = try await host.client.registerPairing(clientDeviceId: device.id, createdAt: createdAt, clientSignature: signature)
        internetState.enroll(device.id, pairing: pairing)
        print("CONNECT enrolled \(device.name) (pairing \(pairing.prefix(10))…)")
        return [OutgoingEvent(.connectEnrolled, ["pairingId": .string(pairing), "serverUrl": .string((offeredConnectURL ?? host.client.server).absoluteString)], replyTo: e.sequence)]
    } catch {
        return refuse("connect_failed", "Couldn’t register with the server: \(error)")
    }
}
let trust = TrustStore(storage: InMemoryTrustStorage())
let window = PairingWindow()
let handlers = LANHostHandlers(
    approvePairing: { request in
        print("APPROVAL device=\"\(request.deviceName)\" platform=\(request.platform) code=\(request.verificationCode)")
        print("Type y and Enter only if the phone shows the same code.")
        guard await console.nextApproval()?.trimmingCharacters(in: .whitespaces).lowercased() == "y" else {
            print("DECLINED")
            return nil
        }
        print("APPROVED (\(grant.map(\.rawValue).sorted().joined(separator: ", ")))")
        return PermissionGrant(grant)
    },
    handle: { envelope, device, _ in
        if envelope.type == .connectEnroll { return await handleEnroll(envelope, device: device) }
        if envelope.type == .notificationPosted {
            let p = envelope.payload
            print("NOTIFICATION from \(p["appLabel"]?.stringValue ?? "?") redaction=\(p["redaction"]?.stringValue ?? "?") " +
                  "title=\(p["title"]?.stringValue.map { "\"\($0)\"" } ?? "—") text=\(p["text"]?.stringValue.map { "\"\($0)\"" } ?? "—")")
            return []
        }
        if envelope.type == .notificationRemoved {
            print("NOTIFICATION removed \(envelope.payload["notificationId"]?.stringValue?.prefix(8) ?? "?")…")
            return []
        }
        if let replies = filesReply(envelope, deviceName: device.name) { return replies }
        switch envelope.type {
        case .healthSnapshotRequest:
            guard let value = await snapshotJSON() else {
                return [OutgoingEvent(.error, ["code": .string("internal"), "message": .string("Could not encode health data."),
                                               "retryable": .bool(false)], replyTo: envelope.sequence)]
            }
            print("REQUEST health.snapshot.request → live snapshot")
            return [OutgoingEvent(.healthSnapshotResult, ["snapshot": value], replyTo: envelope.sequence)]
        case .inputPointer, .inputButton, .inputScroll, .inputKey, .inputText:
            print(describeInput(envelope, via: "control channel"))
            return []
        case .screenStart, .screenUpdate, .screenStop, .webrtcAnswer, .webrtcIce:
            guard let screen else { fallthrough }
            if envelope.type != .webrtcIce { print("REQUEST \(envelope.type.rawValue)") }
            return await screen.handle(envelope, deviceName: device.name)
        default:
            print("REQUEST \(envelope.type.rawValue) → unsupported")
            return [OutgoingEvent(.error, ["code": .string("unsupported"), "message": .string(unsupportedMessage),
                                           "retryable": .bool(false)], replyTo: envelope.sequence)]
        }
    },
    sessionsChanged: { sessions in
        for ended in box.update(sessions) {
            Task { await screen?.sessionEnded(ended) }
            transfers.sessionEnded(ended)
        }
        internetState.keepOffers(for: Set(sessions.map(\.deviceId)))
        for s in sessions {
            print("SESSION \(s.deviceName) route=\(s.route.rawValue)")
            // Phones connected locally are offered internet access once (they must agree on the phone).
            guard let url = offeredConnectURL, internetState.host != nil, s.route == .localNetwork || s.route == .tailscale,
                  let createdAt = internetState.offer(s.deviceId) else { continue }
            box.server?.send(OutgoingEvent(.connectOffer, ["serverUrl": .string(url.absoluteString), "hostDeviceId": .string(identity.deviceId),
                                                           "createdAt": .string(createdAt)]), toSession: s.id)
            print("CONNECT offered internet access to \(s.deviceName) via \(url.absoluteString)")
        }
    },
    record: { event in print("ACTIVITY \(event.title)") },
    sessionExtras: { _, granted in
        guard granted.contains(.filesBrowse) else { return [:] }
        return ["sharedFolders": .array(folders.all.map { .object(["rootId": .string($0.id), "name": .string($0.displayName)]) })]
    })

console.onCommand = { line in
    if line.trimmingCharacters(in: .whitespaces) == "lan off" {
        box.server?.stop()
        return print("COMMAND local listener closed — the phone can only come back over the internet")
    }
    guard let session = box.server?.activeSessions.first else { return print("COMMAND ignored: no phone connected") }
    if line.hasPrefix("send ") {
        let url = URL(fileURLWithPath: String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        do { try transfers.offerFile(at: url, toSession: session.id, deviceName: session.deviceName) } catch { print("COMMAND send failed: \(error)") }
    } else if line.trimmingCharacters(in: .whitespaces) == "lan off" {
        box.server?.stop()
        print("COMMAND local listener closed — the phone can only come back over the internet")
    } else if line.hasPrefix("alert ") {
        box.server?.send(OutgoingEvent(.notificationPosted, ["notificationId": .string("mac_\(UUID().uuidString.prefix(8).lowercased())"),
                                                             "appPackage": .string("app.mybuddy.mac"), "appLabel": .string("MyBuddy"),
                                                             "title": .string(String(line.dropFirst(6))), "postedAt": .string(ConnectTime.format(Date())),
                                                             "redaction": .string("none")]), toSession: session.id)
        print("COMMAND sent an alert to the phone")
    } else if line.hasPrefix("clip ") {
        box.server?.send(fakeClipboard.offer(String(line.dropFirst(5)), deviceId: identity.deviceId), toSession: session.id)
        print("COMMAND offered clipboard text to the phone")
    } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
        print("COMMAND unknown (use `send <path>` or `clip <text>`)")
    }
}

var config = LANHostServer.Configuration()
config.port = port
config.advertiseBonjour = false
config.loopbackOnly = true
if tailnet {
    guard let ip = TailscaleStatus.current().address else {
        print("FAILED: Tailscale is not connected on this Mac (start it and sign in, then retry)")
        exit(1)
    }
    config.bindHost = ip
    advertise = ip
    print("NOTE listening on this Mac's Tailscale address \(ip): devices in your tailnet can reach it; pairing still needs approval here")
}
config.features = testPattern ? ["screen"] : []
let server = LANHostServer(identity: identity, hostName: "Interop Mac", trust: trust, pairingWindow: window, handlers: handlers, configuration: config)
box.server = server
do {
    try server.start()
} catch {
    print("FAILED to start: \(error)")
    exit(1)
}
for _ in 0..<250 where server.boundPort == nil { Thread.sleep(forTimeInterval: 0.02) }
guard let bound = server.boundPort else {
    print("FAILED: listener did not become ready (\(server.state))")
    exit(1)
}
if let connectURL {
    let client = ConnectClient(server: connectURL, identity: identity)
    let host = InternetHost(identity: identity, trust: trust, client: client, loopbackAlias: advertise == "127.0.0.1" ? nil : advertise,
                            adopt: { transport in box.server?.adopt(transport) ?? false },
                            allowed: { box.server?.allowsInternet ?? false },
                            onStatus: { status in print("CONNECT status \(status)") },
                            log: { print($0) })
    internetState.host = host
    server.setAllowInternet(true)
    host.start()
}
let invitation = window.open(addresses: ["\(advertise):\(bound)"], hostFingerprint: identity.fingerprint, displayName: "InteropMac")
print("LISTENING \(config.bindHost ?? "127.0.0.1"):\(bound)\(testPattern ? " (screen: labelled test pattern, not a screen capture)" : "")")
print("INVITATION \(invitation.url.absoluteString)")
dispatchMain()
