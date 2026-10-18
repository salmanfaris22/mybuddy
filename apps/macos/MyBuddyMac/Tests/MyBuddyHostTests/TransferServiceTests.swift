import CryptoKit
import Foundation
import MyBuddyCore
@testable import MyBuddyHost
import Testing

@Suite("Send window")
struct SendWindowTests {
    @Test func keepsAtMostEightChunksInFlight() {
        var w = SendWindow(chunkCount: 20)
        let first = w.takeSendable()
        #expect(first == Array(0..<8))
        let none = w.takeSendable()
        #expect(none.isEmpty, "window full until acks arrive")
        let acked = w.ack(2)
        #expect(acked)
        let more = w.takeSendable()
        #expect(more == [8, 9, 10])
        let bogus = w.ack(15)
        #expect(!bogus, "acks for unsent chunks are protocol violations")
        for i in 3...10 { w.ack(i) }
        let next = w.takeSendable()
        #expect(next == Array(11..<19))
    }

    @Test func resumesFromAChunkAndFinishes() {
        var w = SendWindow(chunkCount: 5, from: 3)
        let rest = w.takeSendable()
        #expect(rest == [3, 4])
        w.ack(4)
        #expect(w.allAcked && w.ackedBytesFraction == 1)
    }
}

/// Two real TransferService instances talking to each other through an asynchronous pump (like the network),
/// one acting as the Mac and one as the phone.
@Suite("Transfer service (end-to-end, in process)", .serialized)
struct TransferServiceTests {
    final class Link: @unchecked Sendable {
        let queue = DispatchQueue(label: "test.transfer.link")
        private let lock = NSLock()
        private var sequence: Int64 = 0
        var mac: TransferService!
        var phone: TransferService!
        /// Lets a test corrupt or drop messages in transit.
        var tamper: (@Sendable (OutgoingEvent) -> OutgoingEvent?)?

        func deliver(_ event: OutgoingEvent, to target: @escaping @Sendable () -> TransferService, replyTarget: @escaping @Sendable () -> TransferService) {
            queue.async { [self] in
                guard let event = tamper?(event) ?? (tamper == nil ? event : nil) else { return }
                let seq = lock.withLock { sequence += 1; return sequence }
                let envelope = Envelope(type: event.type, sessionId: "s_transfertest", sequence: seq, sentAt: Date(), replyTo: event.replyTo, payload: event.payload)
                for reply in target().handle(envelope, deviceName: "peer") { deliver(reply, to: replyTarget, replyTarget: target) }
            }
        }
    }

    static func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mybuddy-transfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func randomFile(in dir: URL, size: Int, name: String = "report.bin") throws -> URL {
        var bytes = [UInt8](repeating: 0, count: size)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        let url = dir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    /// Mac (sender side of this test) and phone services with the given phone policy.
    static func pair(phonePolicy: TransferService.IncomingPolicy, destination: URL) -> Link {
        let link = Link()
        link.mac = TransferService(policy: .ask, destination: destination, send: { [link] e, _ in
            link.deliver(e, to: { link.phone }, replyTarget: { link.mac })
        })
        link.phone = TransferService(policy: phonePolicy, destination: destination, send: { [link] e, _ in
            link.deliver(e, to: { link.mac }, replyTarget: { link.phone })
        })
        return link
    }

    static func waitFor(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw TimedOutWaiting(what: what) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    struct TimedOutWaiting: Error { let what: String }

    func state(_ s: TransferService, _ id: UUID) -> TransferState? { s.items.first { $0.id == id }?.state }

    @Test func sendsAFileEndToEndVerifiedAndQuarantined() async throws {
        let source = try Self.temporaryDirectory(), dest = try Self.temporaryDirectory()
        let file = try Self.randomFile(in: source, size: 300_000)  // 5 chunks, the last one short
        let link = Self.pair(phonePolicy: .saveAutomatically, destination: dest)
        let id = try link.mac.offerFile(at: file, toSession: "s_transfertest", deviceName: "phone")
        try await Self.waitFor("both sides done") {
            if case .completed = state(link.mac, id), case .completed = state(link.phone, id) { return true }
            return false
        }
        guard case .completed(let received) = state(link.phone, id) else { return }
        #expect(try Data(contentsOf: received) == Data(contentsOf: file))
        #expect(received.deletingLastPathComponent().standardizedFileURL == dest.standardizedFileURL)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dest.path).filter { $0.hasSuffix(".part") }
        #expect(leftovers.isEmpty, "no temporary file left behind")
        let quarantine = try received.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(quarantine?[kLSQuarantineAgentNameKey as String] as? String == "MyBuddy")
    }

    @Test func askModeWaitsForTheUserAndDeclineTellsTheSender() async throws {
        let source = try Self.temporaryDirectory(), dest = try Self.temporaryDirectory()
        let link = Self.pair(phonePolicy: .ask, destination: dest)
        let accepted = try link.mac.offerFile(at: try Self.randomFile(in: source, size: 70_000), toSession: "s_transfertest", deviceName: "phone")
        try await Self.waitFor("offer shown") { state(link.phone, accepted) == .awaitingAcceptance }
        try await Task.sleep(for: .milliseconds(200))
        #expect(state(link.phone, accepted) == .awaitingAcceptance, "nothing is written before the user accepts")
        link.phone.accept(accepted)
        try await Self.waitFor("accepted transfer completes") {
            if case .completed = state(link.mac, accepted) { return true }
            return false
        }

        let declined = try link.mac.offerFile(at: try Self.randomFile(in: source, size: 20_000, name: "b.bin"), toSession: "s_transfertest", deviceName: "phone")
        try await Self.waitFor("second offer shown") { state(link.phone, declined) == .awaitingAcceptance }
        link.phone.decline(declined)
        try await Self.waitFor("sender learns it was declined") { state(link.mac, declined) == .failed(.declined) }
    }

    @Test func corruptedChunkFailsTheChecksumAndLeavesNoFile() async throws {
        let source = try Self.temporaryDirectory(), dest = try Self.temporaryDirectory()
        let link = Self.pair(phonePolicy: .saveAutomatically, destination: dest)
        link.tamper = { event in
            guard event.type == .fileChunk, event.payload["index"]?.intValue == 1, let s = event.payload["data"]?.stringValue,
                  var data = Base64URL.decode(s) else { return event }
            data[0] ^= 0xFF  // flip bits in transit
            var p = event.payload
            p["data"] = .string(Base64URL.encode(data))
            return OutgoingEvent(event.type, p, replyTo: event.replyTo)
        }
        let id = try link.mac.offerFile(at: try Self.randomFile(in: source, size: 200_000), toSession: "s_transfertest", deviceName: "phone")
        try await Self.waitFor("both sides report the failure") {
            if case .failed(.checksumMismatch) = state(link.phone, id), case .failed = state(link.mac, id) { return true }
            return false
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path).isEmpty, "neither the bad file nor its temp file remains")
    }

    @Test func cancelPauseResumeAndLimits() async throws {
        let source = try Self.temporaryDirectory(), dest = try Self.temporaryDirectory()
        let link = Self.pair(phonePolicy: .ask, destination: dest)
        let big = try Self.randomFile(in: source, size: 2_000_000, name: "big.bin")
        let id = try link.mac.offerFile(at: big, toSession: "s_transfertest", deviceName: "phone")
        try await Self.waitFor("offer shown") { state(link.phone, id) == .awaitingAcceptance }
        link.mac.pause(id)  // paused before the receiver even starts
        link.phone.accept(id)
        try await Task.sleep(for: .milliseconds(300))
        if case .inProgress(let r, _) = state(link.phone, id) { #expect(r == 0, "a paused sender sends nothing") }
        link.mac.resume(id)
        try await Self.waitFor("progress after resume") {
            if case .inProgress(let r, _) = state(link.phone, id) { return r > 0 }
            if case .completed = state(link.phone, id) { return true }
            return false
        }

        // At most two active transfers per session.
        let second = try link.mac.offerFile(at: try Self.randomFile(in: source, size: 50_000, name: "two.bin"), toSession: "s_transfertest", deviceName: "phone")
        #expect(throws: TransferError.self) {
            try link.mac.offerFile(at: try Self.randomFile(in: source, size: 50_000, name: "three.bin"), toSession: "s_transfertest", deviceName: "phone")
        }
        link.mac.cancel(second)
        try await Self.waitFor("receiver drops the cancelled offer") { state(link.phone, second) == .cancelled }

        // Session end stops everything and deletes partial files.
        link.phone.sessionEnded("s_transfertest")
        link.mac.sessionEnded("s_transfertest")
        try await Task.sleep(for: .milliseconds(200))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path).filter { $0.hasSuffix(".part") }.isEmpty)
    }

    @Test func refusesUnsafeOffers() {
        let dest = FileManager.default.temporaryDirectory
        let service = TransferService(policy: .saveAutomatically, destination: dest, send: { _, _ in })
        func offer(name: String, size: Int64) -> Envelope {
            let o = FileOffer(name: "placeholder", size: 1, sha256: String(repeating: "a", count: 64))
            var p = o.payload
            p["name"] = .string(name)
            p["size"] = .int(size)
            return Envelope(type: .fileOffer, sessionId: "s_transfertest", sequence: 1, sentAt: Date(), payload: p)
        }
        #expect(service.handle(offer(name: "../evil.sh", size: 10), deviceName: "phone").first?.payload["code"]?.stringValue == "denied")
        #expect(service.handle(offer(name: "huge.iso", size: FileOffer.maxSize + 1), deviceName: "phone").first?.payload["code"]?.stringValue == "too_large")
    }
}
