import AppKit
import Foundation
import MyBuddyCore
import MyBuddyHost
import Observation

/// A weak reference that background callbacks can carry; only read on the main actor.
final class WeakOwner<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
}

@MainActor
@Observable
final class FilesStore {
    @ObservationIgnored var app: AppModel!
    let demo: Bool
    private let folders: FolderAccessStore
    private(set) var granted: [GrantedFolder] = []
    var selectedFolderId: String?
    private(set) var browse: LoadState<[[String: JSONValue]]> = .idle
    private(set) var browsePath = ""
    private(set) var transfers: [TransferService.Item] = []
    private(set) var autoSave: Bool
    private(set) var clipboardEvents: [String] = []
    /// Text offered by the phone in "Ask every time" mode, waiting for the user.
    private(set) var pendingIncoming: (text: String, device: String, sessionId: String, revisionId: String)?
    /// Local clipboard change waiting for the user to send it.
    private(set) var pendingOutgoing: String?
    var errorMessage: String?

    @ObservationIgnored private let monitor = PasteboardMonitor()
    @ObservationIgnored private var loopGuard = ClipboardLoopGuard()
    @ObservationIgnored private var offeredByPeer: [String: (hash: String, size: Int)] = [:]
    @ObservationIgnored private var ourOffer: (revisionId: String, text: String)?
    @ObservationIgnored let transferService: TransferService
    @ObservationIgnored private var knownSessions: Set<String> = []
    @ObservationIgnored private var appliedTransfers = 0

    init(demo: Bool, folders: FolderAccessStore, serverRef: ServerRef, autoSave: Bool) {
        self.demo = demo
        self.folders = folders
        self.autoSave = autoSave
        let sequencer = Sequencer(), owner = WeakOwner<FilesStore>()
        transferService = TransferService(
            policy: autoSave ? .saveAutomatically : .ask,
            send: { event, session in serverRef.server?.send(event, toSession: session) },
            onChange: { items in
                let n = sequencer.next()
                Task { @MainActor in owner.value?.applyTransfers(items, sequence: n) }
            },
            record: { event in Task { @MainActor in owner.value?.app.activityLog.record(event) } },
            sessionAllowsTransfer: { session in
                serverRef.server?.activeSessions.first { $0.id == session }?.route.allowsFileTransfer ?? true
            })
        defer { owner.value = self }
        if demo {
            granted = DemoData.folders
            selectedFolderId = granted.first?.id
            browse = .loaded(DemoData.folderEntries)
            transfers = DemoData.transfers
            clipboardEvents = ["Received text from Vivo X300 · 2 min ago", "Sent text to Vivo X300 · 14 min ago"]
        } else {
            granted = folders.all
            selectedFolderId = granted.first?.id
        }
    }

    // MARK: Folders

    func grantFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Share Folder"
        panel.message = "Your phone will only be able to browse inside this folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let folder = try folders.grant(url)
            granted = folders.all
            selectedFolderId = folder.id
            app.activityLog.record(.security, "Shared folder “\(folder.displayName)”", detail: "Phone can browse and open files inside it")
            app.connection.refreshSessions(using: .filesBrowse)
            load(folder.id, path: "")
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// One click + confirmation in the view: the phone can then browse and download anything in the home folder
    /// except hidden items and ~/Library. macOS asks once for each protected folder (Desktop, Documents, Downloads).
    func shareHome() {
        do {
            let folder = try folders.grantHome()
            granted = folders.all
            selectedFolderId = folder.id
            app.activityLog.record(.security, "Shared the Home folder", detail: "Phone can browse it; hidden items and Library stay private")
            app.connection.refreshSessions(using: .filesBrowse)
            load(folder.id, path: "")
        } catch {
            errorMessage = "\(error)"
        }
    }

    var homeShared: Bool { demo ? false : folders.homeShared }

    func revoke(_ folder: GrantedFolder) {
        try? folders.revoke(id: folder.id)
        granted = folders.all
        if selectedFolderId == folder.id { selectedFolderId = granted.first?.id }
        app.activityLog.record(.security, "Stopped sharing “\(folder.displayName)”")
        app.connection.refreshSessions(using: .filesBrowse)
    }

    func load(_ folderId: String, path: String) {
        guard !demo else { return }
        selectedFolderId = folderId
        browsePath = path
        do {
            browse = .loaded(try folders.list(rootId: folderId, path: path))
        } catch {
            browse = .failed("This folder can’t be read. It may have moved or access was removed.")
        }
    }

    // MARK: Transfers

    private func applyTransfers(_ items: [TransferService.Item], sequence: Int) {
        guard sequence > appliedTransfers else { return }
        appliedTransfers = sequence
        transfers = items
    }

    /// Sessions that may exchange files right now.
    var transferSessions: [ActiveSessionInfo] {
        app.connection.sessions.filter { $0.grantedCapabilities.contains(.filesTransfer) }
    }

    func setAutoSave(_ on: Bool) {
        autoSave = on
        transferService.policy = on ? .saveAutomatically : .ask
        app.settings.saveIncomingFilesAutomatically = on
    }

    /// Picks a file and offers it to the connected phone (hashing runs off the main thread).
    func sendFileToPhone() {
        guard let session = transferSessions.first else {
            errorMessage = "Connect a phone that is allowed to “Send & receive files” first."
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Send"
        panel.message = "The file goes straight to \(session.deviceName), encrypted and checksum-verified."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        offer(url, to: session)
    }

    private func offer(_ url: URL, to session: ActiveSessionInfo, requestId: String? = nil) {
        let service = transferService
        Task.detached { [weak self] in
            do {
                try service.offerFile(at: url, toSession: session.id, deviceName: session.deviceName, requestId: requestId)
            } catch {
                await MainActor.run { self?.errorMessage = "Couldn’t send “\(url.lastPathComponent)”: \(error)" }
            }
        }
    }

    /// The phone asks to download a file from a shared folder: resolved inside the granted root
    /// (traversal and symlink escapes refused) and then offered like any other file.
    func handleFileRequest(_ e: Envelope, device: TrustedDevice, granted: Set<Capability>) -> [OutgoingEvent] {
        let fail: (String, String) -> [OutgoingEvent] = { code, message in
            [OutgoingEvent(.error, ["code": .string(code), "message": .string(message), "retryable": .bool(false)], replyTo: e.sequence)]
        }
        guard granted.contains(.filesBrowse) else { return fail("not_permitted", "“Browse shared folders” is not enabled for this device on the Mac.") }
        let rootId = e.payload["rootId"]?.stringValue ?? "", path = e.payload["path"]?.stringValue ?? ""
        guard let url = try? folders.resolve(rootId: rootId, path: path) else { return fail("path_denied", "That path is outside the folders you shared.") }
        guard let session = app.connection.sessions.first(where: { $0.id == e.sessionId }) else { return [] }
        guard session.route.allowsFileTransfer else { return fail("relayed_session", TransferService.relayedMessage) }
        app.activityLog.record(.transfer, "\(device.name) downloaded a shared file", detail: url.lastPathComponent)
        offer(url, to: session, requestId: e.payload["requestId"]?.stringValue)
        return []
    }

    func sessionsChanged(_ sessions: [ActiveSessionInfo]) {
        let now = Set(sessions.map(\.id))
        for ended in knownSessions.subtracting(now) { transferService.sessionEnded(ended) }
        knownSessions = now
    }

    func revealInFinder(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    // MARK: Clipboard

    func startClipboardMonitor() {
        monitor.start { [weak self] change in
            Task { @MainActor in self?.localClipboardChanged(change) }
        }
    }

    private var clipboardSessions: [ActiveSessionInfo] {
        app.connection.sessions.filter { $0.grantedCapabilities.contains(.clipboardSync) }
    }

    private func localClipboardChanged(_ change: PasteboardMonitor.Change) {
        guard !clipboardSessions.isEmpty else { return }
        let policy = ClipboardPolicy(mode: app.settings.clipboardMode, paused: app.settings.clipboardPaused)
        switch policy.evaluate(text: change.text, pasteboardTypes: change.types, loopGuard: loopGuard) {
        case .offerAutomatically: offerToPhone(change.text)
        case .askUser: pendingOutgoing = change.text
        case .skip: break
        }
    }

    func sendPendingOutgoing() {
        if let text = pendingOutgoing { offerToPhone(text) }
        pendingOutgoing = nil
    }

    func dismissPendingOutgoing() { pendingOutgoing = nil }

    private func offerToPhone(_ text: String) {
        guard let identity = app.identity else { return }
        let revision = ClipboardRevision(text: text, originDeviceId: identity.deviceId)
        ourOffer = (revision.revisionId.uuidString.lowercased(), text)
        for s in clipboardSessions {
            app.connection.push(OutgoingEvent(.clipboardOffer, ["revisionId": .string(revision.revisionId.uuidString.lowercased()),
                                                                "originDeviceId": .string(identity.deviceId), "contentHash": .string(revision.contentHash),
                                                                "size": .int(Int64(revision.size)), "mime": .string("text/plain")]), toSession: s.id)
        }
        note("Offered text to phone (\(text.utf8.count) bytes)")
    }

    func handlePeerClipboard(_ e: Envelope, device: TrustedDevice) -> [OutgoingEvent] {
        let revision = e.payload["revisionId"]?.stringValue ?? ""
        switch e.type {
        case .clipboardOffer:
            guard app.settings.clipboardMode != .off, !app.settings.clipboardPaused else {
                return [OutgoingEvent(.clipboardPaused, ["paused": .bool(true)], replyTo: e.sequence)]
            }
            offeredByPeer[revision] = (e.payload["contentHash"]?.stringValue ?? "", Int(e.payload["size"]?.intValue ?? 0))
            return [OutgoingEvent(.clipboardRequest, ["revisionId": .string(revision)], replyTo: e.sequence)]
        case .clipboardContent:
            guard let offer = offeredByPeer.removeValue(forKey: revision), let text = e.payload["text"]?.stringValue,
                  ClipboardPolicy.hash(text) == offer.hash else {
                return [OutgoingEvent(.error, ["code": .string("hash_mismatch"), "message": .string("Clipboard content didn’t match its offer."), "retryable": .bool(false)], replyTo: e.sequence)]
            }
            if app.settings.clipboardMode == .trustedAuto, ClipboardPolicy.looksSensitive(text) == nil {
                applyText(text, origin: device.name)
                return [OutgoingEvent(.clipboardApplied, ["revisionId": .string(revision)], replyTo: e.sequence)]
            }
            pendingIncoming = (text, device.name, e.sessionId, revision)
            return []
        case .clipboardRequest:
            guard let ourOffer, ourOffer.revisionId == revision else { return [] }
            return [OutgoingEvent(.clipboardContent, ["revisionId": .string(revision), "text": .string(ourOffer.text)], replyTo: e.sequence)]
        case .clipboardApplied:
            note("\(device.name) applied the clipboard")
            return []
        default:
            return []
        }
    }

    func acceptIncoming() {
        guard let p = pendingIncoming else { return }
        applyText(p.text, origin: p.device)
        app.connection.push(OutgoingEvent(.clipboardApplied, ["revisionId": .string(p.revisionId)]), toSession: p.sessionId)
        pendingIncoming = nil
    }

    func rejectIncoming() { pendingIncoming = nil }

    /// Writes text to the Mac clipboard without re-offering it back (loop prevention).
    func applyText(_ text: String, origin: String) {
        guard !demo else { return }
        loopGuard.noteApplied(hash: ClipboardPolicy.hash(text))
        monitor.write(text)
        note("Received text from \(origin) (\(text.utf8.count) bytes)")
        app.activityLog.record(.clipboard, "Clipboard updated from \(origin)", detail: "\(text.utf8.count) bytes")
    }

    private func note(_ s: String) {
        clipboardEvents.insert("\(s) · \(Date().formatted(date: .omitted, time: .shortened))", at: 0)
        if clipboardEvents.count > 10 { clipboardEvents.removeLast() }
    }
}
