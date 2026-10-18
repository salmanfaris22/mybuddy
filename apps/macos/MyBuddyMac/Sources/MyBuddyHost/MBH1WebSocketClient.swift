import Foundation
import MyBuddyCore

/// The phone side of MBH1 over WebSocket. The Android app has its own Kotlin implementation;
/// this one powers the end-to-end tests and the developer "simulated phone".
public final class MBH1WebSocketClient: @unchecked Sendable {
    public enum ClientError: Error, Equatable {
        case handshake(HandshakeError)
        case unexpectedMessage(String)
        case session(SessionError)
        case closed
    }

    private let url: URL
    private let identity: any DeviceIdentity
    private let clientName: String
    private let platform: String
    private let urlSession = URLSession(configuration: .ephemeral)
    private var task: URLSessionWebSocketTask?
    private var session: SecureSession?
    private let lock = NSLock()

    public init(url: URL, identity: any DeviceIdentity, clientName: String = "Simulated phone", platform: String = "android") {
        self.url = url
        self.identity = identity
        self.clientName = clientName
        self.platform = platform
    }

    /// Runs the MBH1 handshake. Returns the 6-digit verification code for this session.
    @discardableResult
    public func connect(mode: MBH1.Mode, pinnedFingerprint: String, pairingSecret: Data? = nil) async throws -> String {
        let t = urlSession.webSocketTask(with: url)
        task = t
        t.resume()
        var client = MBH1Client(mode: mode, identity: identity, clientName: clientName, platform: platform,
                                pinnedHostFingerprint: pinnedFingerprint, pairingSecret: pairingSecret)
        try await t.send(.string(String(decoding: client.makeHello(), as: UTF8.self)))
        guard case .string(let hostText) = try await t.receive() else { throw ClientError.unexpectedMessage("expected hs.host") }
        let reply: Data
        let result: MBH1Client.Result
        do {
            (reply, result) = try client.handleHost(Data(hostText.utf8))
        } catch {
            t.cancel(with: .goingAway, reason: nil)
            throw ClientError.handshake(error)
        }
        try await t.send(.string(String(decoding: reply, as: UTF8.self)))
        lock.withLock { session = SecureSession(role: .phone, keys: result.keys) }
        return result.keys.sas
    }

    @discardableResult
    public func send(_ type: EventType, _ payload: [String: JSONValue]) async throws -> Int64 {
        let sealed: (frame: Data, sequence: Int64)
        do {
            sealed = try lock.withLock { () throws -> (frame: Data, sequence: Int64) in
                guard session != nil else { throw ClientError.closed }
                return try session!.seal(type, payload: payload)
            }
        } catch let e as SessionError {
            throw ClientError.session(e)
        }
        guard let task else { throw ClientError.closed }
        try await task.send(.data(sealed.frame))
        return sealed.sequence
    }

    public func receive() async throws -> Envelope {
        guard let task else { throw ClientError.closed }
        let message = try await task.receive()
        guard case .data(let frame) = message else { throw ClientError.unexpectedMessage("expected a binary frame") }
        do {
            return try lock.withLock { () throws -> Envelope in
                guard session != nil else { throw ClientError.closed }
                return try session!.open(frame)
            }
        } catch let e as SessionError {
            throw ClientError.session(e)
        }
    }

    /// Receives until an envelope of `type` arrives (skipping pushes such as host.status).
    public func receive(_ type: EventType, limit: Int = 20) async throws -> Envelope {
        for _ in 0..<limit {
            let e = try await receive()
            if e.type == type { return e }
        }
        throw ClientError.unexpectedMessage("no \(type.rawValue)")
    }

    public func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }
}
