import CoreServices
import Foundation
import MyBuddyCore

/// File transfers with paired phones, both directions (PROTOCOL §5.5). Files travel inside the end-to-end
/// encrypted MBH1 session over a direct path — never through a server. Incoming files are written to a temporary file in the destination,
/// verified with SHA-256, renamed into place atomically (never overwriting) and tagged as downloaded
/// (quarantine) so Gatekeeper treats them like any other download.
public final class TransferService: @unchecked Sendable {
    public enum Direction: String, Sendable { case toMac, toPhone }

    /// What happens when a phone offers a file.
    public enum IncomingPolicy: Sendable, Equatable {
        case ask
        case saveAutomatically
    }

    public struct Item: Sendable, Identifiable, Equatable {
        public let id: UUID
        public let name: String
        public let size: Int64
        public let direction: Direction
        public let sessionId: String
        public let deviceName: String
        public var state: TransferState
        public var updatedAt: Date

        public init(id: UUID, name: String, size: Int64, direction: Direction, sessionId: String, deviceName: String, state: TransferState, updatedAt: Date) {
            self.id = id
            self.name = name
            self.size = size
            self.direction = direction
            self.sessionId = sessionId
            self.deviceName = deviceName
            self.state = state
            self.updatedAt = updatedAt
        }
    }

    public static let maxConcurrentPerSession = 2
    public static let stallTimeout: TimeInterval = 60
    public static let acceptanceTimeout: TimeInterval = 300

    private final class Incoming {
        var item: Item
        let offer: FileOffer
        var receiver: FileReceiver?
        var lastActivity = Date()
        init(item: Item, offer: FileOffer) {
            self.item = item
            self.offer = offer
        }
    }

    private final class Outgoing {
        var item: Item
        let offer: FileOffer
        let handle: FileHandle
        let url: URL
        var window: SendWindow?
        var paused = false
        var lastActivity = Date()
        init(item: Item, offer: FileOffer, handle: FileHandle, url: URL) {
            self.item = item
            self.offer = offer
            self.handle = handle
            self.url = url
        }
    }

    private let lock = NSLock()
    private var incoming: [UUID: Incoming] = [:]
    private var outgoing: [UUID: Outgoing] = [:]
    private var finished: [Item] = []
    private var policyValue: IncomingPolicy
    private var destinationValue: URL
    private let send: @Sendable (OutgoingEvent, String) -> Void
    private let onChange: @Sendable ([Item]) -> Void
    private let record: @Sendable (ActivityEvent) -> Void
    /// False for sessions whose bytes would pass through a server (TURN-relayed internet sessions).
    private let sessionAllowsTransfer: @Sendable (String) -> Bool
    private var watchdog: (any DispatchSourceTimer)?

    public init(policy: IncomingPolicy = .ask, destination: URL = TransferService.defaultDestination,
                send: @escaping @Sendable (OutgoingEvent, String) -> Void,
                onChange: @escaping @Sendable ([Item]) -> Void = { _ in },
                record: @escaping @Sendable (ActivityEvent) -> Void = { _ in },
                sessionAllowsTransfer: @escaping @Sendable (String) -> Bool = { _ in true }) {
        policyValue = policy
        destinationValue = destination
        self.send = send
        self.onChange = onChange
        self.record = record
        self.sessionAllowsTransfer = sessionAllowsTransfer
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "app.mybuddy.transfers.watchdog"))
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.expireStalled() }
        timer.resume()
        watchdog = timer
    }

    deinit { watchdog?.cancel() }

    public static var defaultDestination: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
    }

    public var policy: IncomingPolicy {
        get { lock.withLock { policyValue } }
        set { lock.withLock { policyValue = newValue } }
    }

    public var destination: URL {
        get { lock.withLock { destinationValue } }
        set { lock.withLock { destinationValue = newValue } }
    }

    /// Active transfers first, then the most recent finished ones.
    public var items: [Item] {
        lock.withLock { currentItems() }
    }

    private func currentItems() -> [Item] {
        let active = (incoming.values.map(\.item) + outgoing.values.map(\.item)).sorted { $0.updatedAt > $1.updatedAt }
        return active + finished
    }

    private func publish() { onChange(items) }

    // MARK: Events from the phone (already authorized for `files.transfer` by the host)

    public func handle(_ e: Envelope, deviceName: String) -> [OutgoingEvent] {
        guard let id = e.payload["transferId"]?.stringValue.flatMap(UUID.init(uuidString:)) else { return [] }
        let replies: [OutgoingEvent]
        switch e.type {
        case .fileOffer: replies = receiveOffer(e, id: id, deviceName: deviceName)
        case .fileChunk: replies = receiveChunk(e, id: id)
        case .fileStart: replies = startSending(e, id: id)
        case .fileAck: replies = ackReceived(e, id: id)
        case .fileComplete: replies = completeReceived(e, id: id)
        case .filePause, .fileResume: replies = pauseChanged(id: id, sessionId: e.sessionId, paused: e.type == .filePause)
        case .fileCancel: replies = cancelled(id: id, sessionId: e.sessionId, code: nil)
        case .fileError: replies = cancelled(id: id, sessionId: e.sessionId, code: e.payload["code"]?.stringValue)
        default: replies = []
        }
        publish()
        return replies
    }

    private func error(_ id: UUID, _ code: TransferErrorCode, replyTo: Int64? = nil) -> OutgoingEvent {
        OutgoingEvent(.fileError, ["transferId": .string(id.uuidString.lowercased()), "code": .string(code.rawValue)], replyTo: replyTo)
    }

    private func activeCount(_ sessionId: String) -> Int {
        incoming.values.filter { $0.item.sessionId == sessionId }.count + outgoing.values.filter { $0.item.sessionId == sessionId }.count
    }

    /// Why transfers are off in relayed internet sessions (shown on both devices).
    public static let relayedMessage = "File transfer needs a direct connection — this session goes through a relay server."

    private func receiveOffer(_ e: Envelope, id: UUID, deviceName: String) -> [OutgoingEvent] {
        guard let offer = FileOffer(payload: e.payload) else { return [error(id, .denied, replyTo: e.sequence)] }
        guard sessionAllowsTransfer(e.sessionId) else {
            return [error(id, .denied, replyTo: e.sequence),
                    OutgoingEvent(.error, ["code": .string("relayed_session"), "message": .string(Self.relayedMessage), "retryable": .bool(false)], replyTo: e.sequence)]
        }
        return lock.withLock { () -> [OutgoingEvent] in
            guard incoming[id] == nil, outgoing[id] == nil else { return [] }
            guard activeCount(e.sessionId) < Self.maxConcurrentPerSession else { return [error(id, .denied, replyTo: e.sequence)] }
            guard offer.size <= FileOffer.maxSize else { return [error(id, .tooLarge, replyTo: e.sequence)] }
            guard FileNameRules.isSafe(offer.name) else { return [error(id, .denied, replyTo: e.sequence)] }
            let item = Item(id: id, name: offer.name, size: offer.size, direction: .toMac, sessionId: e.sessionId, deviceName: deviceName,
                            state: .awaitingAcceptance, updatedAt: Date())
            let transfer = Incoming(item: item, offer: offer)
            incoming[id] = transfer
            guard policyValue == .saveAutomatically else { return [] }
            return beginReceiving(transfer, replyTo: e.sequence)
        }
    }

    /// Must be called with the lock held.
    private func beginReceiving(_ t: Incoming, replyTo: Int64?) -> [OutgoingEvent] {
        do throws(TransferError) {
            t.receiver = try FileReceiver(offer: t.offer, destinationDirectory: destinationValue)
        } catch let failure {
            incoming[t.item.id] = nil
            finish(t.item, state: .failed(failure))
            let code: TransferErrorCode = failure == .tooLarge ? .tooLarge : .denied
            return [error(t.item.id, code, replyTo: replyTo)]
        }
        t.item.state = .inProgress(received: 0, total: t.offer.size)
        t.item.updatedAt = Date()
        t.lastActivity = Date()
        return [OutgoingEvent(.fileStart, ["transferId": .string(t.item.id.uuidString.lowercased()), "fromChunk": .int(0)], replyTo: replyTo)]
    }

    private func receiveChunk(_ e: Envelope, id: UUID) -> [OutgoingEvent] {
        lock.withLock { () -> [OutgoingEvent] in
            guard let t = incoming[id], t.item.sessionId == e.sessionId, let receiver = t.receiver,
                  let index = e.payload["index"]?.intValue, let data = e.payload["data"]?.stringValue.flatMap(Base64URL.decode)
            else { return [] }
            do throws(TransferError) {
                let received = try receiver.write(index: Int(index), data: data)
                t.lastActivity = Date()
                t.item.state = .inProgress(received: received, total: t.offer.size)
                t.item.updatedAt = Date()
                var replies = [OutgoingEvent(.fileAck, ["transferId": .string(id.uuidString.lowercased()), "index": .int(Int64(receiver.nextExpectedIndex - 1))])]
                if receiver.nextExpectedIndex == t.offer.chunkCount {
                    t.item.state = .verifying
                    do throws(TransferError) {
                        let url = try receiver.finish()
                        Self.markDownloaded(url)
                        incoming[id] = nil
                        finish(t.item, state: .completed(url))
                        record(ActivityEvent(kind: .transfer, title: "Received \(t.offer.name) from \(t.item.deviceName)",
                                             detail: "\(ByteCountFormatter.string(fromByteCount: t.offer.size, countStyle: .file)) · SHA-256 verified"))
                        replies.append(OutgoingEvent(.fileComplete, ["transferId": .string(id.uuidString.lowercased()), "sha256": .string(t.offer.sha256)]))
                    } catch let failure {
                        incoming[id] = nil
                        finish(t.item, state: .failed(failure))
                        replies.append(error(id, failure == .checksumMismatch ? .checksumMismatch : .diskFull))
                    }
                }
                return replies
            } catch let failure {
                receiver.cancel()
                incoming[id] = nil
                finish(t.item, state: .failed(failure))
                return [error(id, .invalidChunk)]
            }
        }
    }

    private func startSending(_ e: Envelope, id: UUID) -> [OutgoingEvent] {
        lock.withLock {
            guard let t = outgoing[id], t.item.sessionId == e.sessionId, t.window == nil else { return }
            let from = Int(e.payload["fromChunk"]?.intValue ?? 0)
            t.window = SendWindow(chunkCount: t.offer.chunkCount, from: from)
            let sent = Int64(from) * Int64(t.offer.chunkSize)
            t.item.state = t.paused ? .paused(received: sent, total: t.offer.size) : .inProgress(received: sent, total: t.offer.size)
            t.item.updatedAt = Date()
            t.lastActivity = Date()
            pump(t)
        }
        return []
    }

    private func ackReceived(_ e: Envelope, id: UUID) -> [OutgoingEvent] {
        lock.withLock { () -> [OutgoingEvent] in
            guard let t = outgoing[id], t.item.sessionId == e.sessionId, var window = t.window, let index = e.payload["index"]?.intValue else { return [] }
            guard window.ack(Int(index)) else {
                outgoing[id] = nil
                try? t.handle.close()
                finish(t.item, state: .failed(.invalidChunk("ack for an unsent chunk")))
                return [error(id, .invalidChunk)]
            }
            t.window = window
            t.lastActivity = Date()
            let sent = min(t.offer.size, Int64(window.highestAcked + 1) * Int64(t.offer.chunkSize))
            t.item.state = window.allAcked ? .verifying : (t.paused ? .paused(received: sent, total: t.offer.size) : .inProgress(received: sent, total: t.offer.size))
            t.item.updatedAt = Date()
            pump(t)
            return []
        }
    }

    /// Sends every chunk the window allows (lock held).
    private func pump(_ t: Outgoing) {
        guard !t.paused, var window = t.window else { return }
        let indices = window.takeSendable()
        t.window = window
        for index in indices {
            do {
                try t.handle.seek(toOffset: UInt64(index) * UInt64(t.offer.chunkSize))
                let data = try t.handle.read(upToCount: t.offer.chunkSize) ?? Data()
                guard data.count == t.offer.expectedLength(ofChunk: index) else { throw TransferError.io("file changed while sending") }
                send(OutgoingEvent(.fileChunk, ["transferId": .string(t.item.id.uuidString.lowercased()), "index": .int(Int64(index)),
                                                "data": .string(Base64URL.encode(data))]), t.item.sessionId)
            } catch {
                outgoing[t.item.id] = nil
                try? t.handle.close()
                finish(t.item, state: .failed(.io("couldn’t read the file")))
                send(self.error(t.item.id, .cancelled), t.item.sessionId)
                return
            }
        }
    }

    private func completeReceived(_ e: Envelope, id: UUID) -> [OutgoingEvent] {
        lock.withLock {
            guard let t = outgoing.removeValue(forKey: id), t.item.sessionId == e.sessionId else { return }
            try? t.handle.close()
            if e.payload["sha256"]?.stringValue == t.offer.sha256, t.window?.allAcked == true {
                finish(t.item, state: .completed(t.url))
                record(ActivityEvent(kind: .transfer, title: "Sent \(t.offer.name) to \(t.item.deviceName)",
                                     detail: "\(ByteCountFormatter.string(fromByteCount: t.offer.size, countStyle: .file)) · SHA-256 verified by the phone"))
            } else {
                finish(t.item, state: .failed(.checksumMismatch))
            }
        }
        return []
    }

    private func pauseChanged(id: UUID, sessionId: String, paused: Bool) -> [OutgoingEvent] {
        lock.withLock {
            if let t = outgoing[id], t.item.sessionId == sessionId {
                t.paused = paused
                t.lastActivity = Date()
                switch t.item.state {
                case .inProgress(let r, let total) where paused: t.item.state = .paused(received: r, total: total)
                case .paused(let r, let total) where !paused: t.item.state = .inProgress(received: r, total: total)
                default: break
                }
                // Resuming always refills the window (it may have started while paused).
                if !paused { pump(t) }
                t.item.updatedAt = Date()
            } else if let t = incoming[id], t.item.sessionId == sessionId {
                t.lastActivity = Date()
                if case .inProgress(let r, let total) = t.item.state, paused { t.item.state = .paused(received: r, total: total) }
                if case .paused(let r, let total) = t.item.state, !paused { t.item.state = .inProgress(received: r, total: total) }
                t.item.updatedAt = Date()
            }
        }
        return []
    }

    private func cancelled(id: UUID, sessionId: String, code: String?) -> [OutgoingEvent] {
        lock.withLock {
            let failure: TransferState = code.map { $0 == TransferErrorCode.checksumMismatch.rawValue ? .failed(.checksumMismatch) : .failed(.io($0)) } ?? .cancelled
            if let t = incoming[id], t.item.sessionId == sessionId {
                t.receiver?.cancel()
                incoming[id] = nil
                finish(t.item, state: failure)
            } else if let t = outgoing[id], t.item.sessionId == sessionId {
                try? t.handle.close()
                outgoing[id] = nil
                let declined = code == TransferErrorCode.denied.rawValue && t.item.state == .awaitingAcceptance
                finish(t.item, state: declined ? .failed(.declined) : failure)
            }
        }
        return []
    }

    // MARK: Actions on the Mac

    /// Accepts a pending incoming file (Ask mode).
    public func accept(_ id: UUID) {
        let replies: [OutgoingEvent] = lock.withLock {
            guard let t = incoming[id], t.receiver == nil, t.item.state == .awaitingAcceptance else { return [] }
            return beginReceiving(t, replyTo: nil)
        }
        if let session = lock.withLock({ incoming[id]?.item.sessionId ?? finished.first { $0.id == id }?.sessionId }) {
            replies.forEach { send($0, session) }
        }
        publish()
    }

    public func decline(_ id: UUID) {
        let session: String? = lock.withLock {
            guard let t = incoming.removeValue(forKey: id) else { return nil }
            finish(t.item, state: .cancelled)
            return t.item.sessionId
        }
        if let session { send(error(id, .denied), session) }
        publish()
    }

    /// Offers a Mac file to a phone. Reads it once to compute the SHA-256 (call off the main thread for big files).
    @discardableResult
    public func offerFile(at url: URL, toSession sessionId: String, deviceName: String, requestId: String? = nil) throws -> UUID {
        guard sessionAllowsTransfer(sessionId) else { throw TransferError.invalidOffer(Self.relayedMessage) }
        guard lock.withLock({ activeCount(sessionId) }) < Self.maxConcurrentPerSession else { throw TransferError.invalidOffer("too many transfers") }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw TransferError.invalidOffer("not a regular file") }
        guard Int64(values.fileSize ?? 0) <= FileOffer.maxSize else { throw TransferError.tooLarge }
        guard Int64(values.fileSize ?? 0) > 0 else { throw TransferError.invalidOffer("empty file") }
        let name = FileNameRules.isSafe(url.lastPathComponent) ? url.lastPathComponent : "file"
        let offer = try FileChunker(url: url).makeOffer(name: name, mimeType: nil)
        let handle = try FileHandle(forReadingFrom: url)
        let item = Item(id: offer.transferId, name: offer.name, size: offer.size, direction: .toPhone, sessionId: sessionId, deviceName: deviceName,
                        state: .awaitingAcceptance, updatedAt: Date())
        lock.withLock { outgoing[offer.transferId] = Outgoing(item: item, offer: offer, handle: handle, url: url) }
        var payload = offer.payload
        // Echoed so the phone can tell the file it asked for (accepted automatically) from an unsolicited offer.
        if let requestId, UUID(uuidString: requestId) != nil { payload["requestId"] = .string(requestId.lowercased()) }
        send(OutgoingEvent(.fileOffer, payload), sessionId)
        publish()
        return offer.transferId
    }

    public func pause(_ id: UUID) { userPause(id, paused: true) }
    public func resume(_ id: UUID) { userPause(id, paused: false) }

    private func userPause(_ id: UUID, paused: Bool) {
        let session: String? = lock.withLock { outgoing[id]?.item.sessionId ?? incoming[id]?.item.sessionId }
        guard let session else { return }
        _ = pauseChanged(id: id, sessionId: session, paused: paused)
        send(OutgoingEvent(paused ? .filePause : .fileResume, ["transferId": .string(id.uuidString.lowercased())]), session)
        publish()
    }

    public func cancel(_ id: UUID) {
        let session: String? = lock.withLock { outgoing[id]?.item.sessionId ?? incoming[id]?.item.sessionId }
        guard let session else { return }
        _ = cancelled(id: id, sessionId: session, code: nil)
        send(OutgoingEvent(.fileCancel, ["transferId": .string(id.uuidString.lowercased()), "reason": .string("Cancelled on the Mac")]), session)
        publish()
    }

    /// The session ended: every transfer of it stops and partial files are deleted.
    public func sessionEnded(_ sessionId: String) {
        lock.withLock {
            for (id, t) in incoming where t.item.sessionId == sessionId {
                t.receiver?.cancel()
                incoming[id] = nil
                finish(t.item, state: .failed(.cancelled))
            }
            for (id, t) in outgoing where t.item.sessionId == sessionId {
                try? t.handle.close()
                outgoing[id] = nil
                finish(t.item, state: .failed(.cancelled))
            }
        }
        publish()
    }

    public func clearFinished() {
        lock.withLock { finished.removeAll() }
        publish()
    }

    // MARK: Internals

    /// Lock held.
    private func finish(_ item: Item, state: TransferState) {
        var done = item
        done.state = state
        done.updatedAt = Date()
        finished.insert(done, at: 0)
        if finished.count > 50 { finished.removeLast() }
    }

    private func expireStalled() {
        let now = Date()
        var timedOut: [(UUID, String)] = []
        lock.withLock {
            for (id, t) in incoming {
                let limit = t.receiver == nil ? Self.acceptanceTimeout : Self.stallTimeout
                if now.timeIntervalSince(t.lastActivity) > limit, !isPaused(t.item.state) {
                    t.receiver?.cancel()
                    incoming[id] = nil
                    finish(t.item, state: .failed(.io("timeout")))
                    timedOut.append((id, t.item.sessionId))
                }
            }
            for (id, t) in outgoing {
                let limit = t.window == nil ? Self.acceptanceTimeout : Self.stallTimeout
                if now.timeIntervalSince(t.lastActivity) > limit, !t.paused {
                    try? t.handle.close()
                    outgoing[id] = nil
                    finish(t.item, state: .failed(.io("timeout")))
                    timedOut.append((id, t.item.sessionId))
                }
            }
        }
        guard !timedOut.isEmpty else { return }
        for (id, session) in timedOut { send(error(id, .timeout), session) }
        publish()
    }

    private func isPaused(_ s: TransferState) -> Bool {
        if case .paused = s { return true }
        return false
    }

    /// Tags a received file like a browser download (Gatekeeper checks it before first launch).
    static func markDownloaded(_ url: URL) {
        var values = URLResourceValues()
        values.quarantineProperties = [kLSQuarantineAgentNameKey as String: "MyBuddy",
                                       kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String]
        var target = url
        try? target.setResourceValues(values)
    }
}
