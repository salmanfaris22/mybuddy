import Foundation
import MyBuddyCore

/// HTTPS client for a self-hosted MyBuddy Connect server (PROTOCOL §7). The device key is the only
/// credential: registration proves possession of it, and each sign-in answers a fresh challenge. The
/// resulting 15-minute bearer token lives in memory only and is never logged.
public final class ConnectClient: @unchecked Sendable {
    public struct Pairing: Sendable, Equatable, Decodable {
        public let pairingId: String
        public let hostDeviceId: String
        public let clientDeviceId: String
        public let createdAt: String
        public let revokedAt: String?
    }

    public let server: URL
    private let identity: any DeviceIdentity
    private let platform: String
    private let session: URLSession
    private let lock = NSLock()
    private var cachedToken: (value: String, expires: Date)?
    private var registered = false

    public init(server: URL, identity: any DeviceIdentity, platform: String = "macos", session: URLSession? = nil) {
        self.server = server
        self.identity = identity
        self.platform = platform
        self.session = session ?? URLSession(configuration: Self.configuration())
    }

    static func configuration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral  // no cookies, no cache on disk
        c.timeoutIntervalForRequest = 15
        c.httpShouldSetCookies = false
        c.urlCache = nil
        return c
    }

    public var deviceId: String { identity.deviceId }

    // MARK: device + token

    /// Registers this device's key (idempotent: an existing identical registration is fine).
    public func ensureRegistered() async throws {
        if lock.withLock({ registered }) { return }
        let spki = identity.publicKeySPKI
        let proof = try identity.sign(ConnectStatements.register(spki: spki, platform: platform))
        let body: [String: String] = ["publicKey": Base64URL.encode(spki), "platform": platform, "proof": Base64URL.encode(proof)]
        let (data, status) = try await send("POST", "/v1/devices", json: body, token: nil)
        guard status == 200 || status == 201 else { throw Self.error(data, status) }
        let answer = try JSONDecoder().decode([String: String].self, from: data)
        guard answer["deviceId"] == identity.deviceId else { throw ConnectError.invalid("server returned a different device id") }
        lock.withLock { registered = true }
    }

    /// A valid bearer token (signs a new challenge when the cached one is about to expire).
    public func token() async throws -> String {
        if let t = lock.withLock({ cachedToken }), t.expires.timeIntervalSinceNow > 60 { return t.value }
        try await ensureRegistered()
        let (challengeData, s1) = try await send("POST", "/v1/auth/challenge", json: ["deviceId": identity.deviceId], token: nil)
        guard s1 == 200 else { throw Self.error(challengeData, s1) }
        let challenge = try JSONDecoder().decode([String: String].self, from: challengeData)
        guard let challengeId = challenge["challengeId"], let nonceText = challenge["nonce"], let nonce = Base64URL.decode(nonceText) else {
            throw ConnectError.invalid("malformed challenge")
        }
        let signature = try identity.sign(ConnectStatements.auth(challengeId: challengeId, nonce: nonce, deviceId: identity.deviceId))
        let (tokenData, s2) = try await send("POST", "/v1/auth/token",
                                             json: ["challengeId": challengeId, "deviceId": identity.deviceId, "signature": Base64URL.encode(signature)], token: nil)
        guard s2 == 200 else { throw Self.error(tokenData, s2) }
        let answer = try JSONDecoder().decode([String: String].self, from: tokenData)
        guard let value = answer["token"], value.utf8.count == 43 else { throw ConnectError.invalid("malformed token") }
        let expires = answer["expiresAt"].flatMap(ConnectTime.parse) ?? Date().addingTimeInterval(14 * 60)
        lock.withLock { cachedToken = (value, expires) }
        return value
    }

    /// Forgets the cached token (after the server rejected it).
    public func dropToken() { lock.withLock { cachedToken = nil } }

    // MARK: pairings

    /// Registers a pairing both devices signed (the caller is the host). Returns the pairing id.
    public func registerPairing(clientDeviceId: String, createdAt: String, clientSignature: Data) async throws -> String {
        let statement = ConnectStatements.pairing(hostDeviceId: identity.deviceId, clientDeviceId: clientDeviceId, createdAt: createdAt)
        let hostSignature = try identity.sign(statement)
        let body = ["hostDeviceId": identity.deviceId, "clientDeviceId": clientDeviceId, "createdAt": createdAt,
                    "hostSignature": Base64URL.encode(hostSignature), "clientSignature": Base64URL.encode(clientSignature)]
        let (data, status) = try await authed("POST", "/v1/pairings", json: body)
        guard status == 200 || status == 201 else { throw Self.error(data, status) }
        return try JSONDecoder().decode(Pairing.self, from: data).pairingId
    }

    public func pairings() async throws -> [Pairing] {
        let (data, status) = try await authed("GET", "/v1/pairings", json: nil)
        guard status == 200 else { throw Self.error(data, status) }
        struct List: Decodable { let pairings: [Pairing] }
        return try JSONDecoder().decode(List.self, from: data).pairings
    }

    public func revokePairing(id: String) async throws {
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "_-"))) ?? id
        let (data, status) = try await authed("DELETE", "/v1/pairings/\(escaped)", json: nil)
        guard status == 204 || status == 404 else { throw Self.error(data, status) }
    }

    /// Short-lived TURN credentials, or nil when the server has no TURN relay configured.
    public func turnCredentials() async throws -> TurnCredentials? {
        let (data, status) = try await authed("GET", "/v1/turn-credentials", json: nil)
        if status == 503 { return nil }
        guard status == 200 else { throw Self.error(data, status) }
        return try JSONDecoder().decode(TurnCredentials.self, from: data)
    }

    /// `GET /healthz` — used to show whether the server answers at all.
    public func healthy() async -> Bool {
        (try? await send("GET", "/healthz", json: nil, token: nil).1) == 200
    }

    // MARK: plumbing

    private func authed(_ method: String, _ path: String, json: [String: String]?) async throws -> (Data, Int) {
        let first = try await send(method, path, json: json, token: try await token())
        guard first.1 == 401 else { return first }
        dropToken()  // expired or revoked on the server: sign in again once
        return try await send(method, path, json: json, token: try await token())
    }

    private func send(_ method: String, _ path: String, json: [String: String]?, token: String?) async throws -> (Data, Int) {
        guard let url = URL(string: path, relativeTo: server) else { throw ConnectError.invalid("bad path") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        }
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw ConnectError.transport((error as? URLError)?.localizedDescription ?? "Couldn’t reach the server")
        }
    }

    static func error(_ data: Data, _ status: Int) -> ConnectError {
        struct Body: Decodable { struct E: Decodable { let code: String; let message: String }; let error: E }
        if let body = try? JSONDecoder().decode(Body.self, from: data) {
            return .server(code: String(body.error.code.prefix(64)), message: String(body.error.message.prefix(200)), status: status)
        }
        return .server(code: "http_\(status)", message: "Unexpected answer from the server (HTTP \(status))", status: status)
    }
}

/// The `/v1/signal` WebSocket: relays signed rendezvous messages between paired devices and reports
/// presence. Reconnects with bounded backoff while running; a new token is fetched for every connection.
public final class ConnectSignal: @unchecked Sendable {
    public enum Event: Sendable {
        case connected
        case disconnected(String)
        case relay(from: String, id: String, data: Data)
        case presence([String: Bool])
        case pairingRevoked(pairingId: String, peer: String)
        case serverError(code: String, message: String, id: String?)
    }

    private let client: ConnectClient
    private let session: URLSession
    private let onEvent: @Sendable (Event) -> Void
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var running = false
    private var attempt = 0
    private var generation = 0

    public init(client: ConnectClient, onEvent: @escaping @Sendable (Event) -> Void) {
        self.client = client
        self.onEvent = onEvent
        session = URLSession(configuration: ConnectClient.configuration())
    }

    public var isConnected: Bool { lock.withLock { task != nil && running } }

    public func start() {
        let start = lock.withLock { () -> Bool in
            guard !running else { return false }
            running = true
            attempt = 0
            return true
        }
        if start { Task { await self.connect() } }
    }

    public func stop() {
        let t = lock.withLock { () -> URLSessionWebSocketTask? in
            running = false
            generation += 1
            defer { task = nil }
            return task
        }
        t?.cancel(with: .normalClosure, reason: nil)
    }

    /// Sends one relay message to `peer`; false when not connected.
    @discardableResult
    public func relay(to peer: String, data: Data) -> Bool {
        guard let t = lock.withLock({ task }) else { return false }
        let id = "m" + Base64URL.encode(Data((0..<9).map { _ in UInt8.random(in: 0...255) }))
        let outer: [String: String] = ["type": "relay", "to": peer, "id": id, "data": Base64URL.encode(data)]
        guard let json = try? JSONSerialization.data(withJSONObject: outer, options: [.sortedKeys]), let text = String(data: json, encoding: .utf8) else { return false }
        t.send(.string(text)) { _ in }
        return true
    }

    public func requestPresence() {
        lock.withLock { task }?.send(.string(#"{"type":"presence"}"#)) { _ in }
    }

    private func connect() async {
        let gen = lock.withLock { generation }
        do {
            let token = try await client.token()
            guard let url = ConnectServerURL.signalURL(client.server) else { throw ConnectError.invalid("bad server URL") }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let t = session.webSocketTask(with: request)
            t.maximumMessageSize = 128 * 1024
            let current = lock.withLock { () -> Bool in
                guard running, gen == generation else { return false }
                task = t
                return true
            }
            guard current else { return t.cancel() }
            t.resume()
            // The first successful receive proves the upgrade worked; ask for presence right away.
            t.send(.string(#"{"type":"presence"}"#)) { _ in }
            receive(t, gen: gen, announced: false)
        } catch {
            scheduleReconnect(gen: gen, reason: Self.describe(error))
        }
    }

    private func receive(_ t: URLSessionWebSocketTask, gen: Int, announced: Bool) {
        t.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.lock.withLock { if self.task === t { self.task = nil } }
                self.scheduleReconnect(gen: gen, reason: Self.describe(error))
            case .success(let message):
                if !announced {
                    self.lock.withLock { self.attempt = 0 }
                    self.onEvent(.connected)
                }
                if case .string(let text) = message { self.handle(text) }
                self.receive(t, gen: gen, announced: true)
            }
        }
    }

    private func handle(_ text: String) {
        guard text.utf8.count <= 128 * 1024, let data = text.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = o["type"] as? String else { return }
        switch type {
        case "relay":
            guard let from = o["from"] as? String, ConnectIDs.isDeviceId(from), let id = o["id"] as? String,
                  let payload = (o["data"] as? String).flatMap(Base64URL.decode) else { return }
            onEvent(.relay(from: from, id: id, data: payload))
        case "presence":
            var peers: [String: Bool] = [:]
            for p in (o["peers"] as? [[String: Any]]) ?? [] {
                if let id = p["deviceId"] as? String, let online = p["online"] as? Bool { peers[id] = online }
            }
            onEvent(.presence(peers))
        case "pairing.revoked":
            onEvent(.pairingRevoked(pairingId: o["pairingId"] as? String ?? "", peer: o["peerDeviceId"] as? String ?? ""))
        case "error":
            let code = o["code"] as? String ?? "error"
            if code == "token_expired" { client.dropToken() }
            onEvent(.serverError(code: code, message: String((o["message"] as? String ?? "").prefix(200)), id: o["id"] as? String))
        default:
            break
        }
    }

    private func scheduleReconnect(gen: Int, reason: String) {
        let delay: Double? = lock.withLock {
            guard running, gen == generation else { return nil }
            task = nil
            attempt += 1
            // 1 s, 2 s, 4 s … capped at 60 s; keeps trying while internet access is on (the state is visible).
            return min(60, pow(2, Double(min(attempt - 1, 6)))) * Double.random(in: 0.7...1.0)
        }
        onEvent(.disconnected(reason))
        guard let delay else { return }
        Task {
            try? await Task.sleep(for: .seconds(delay))
            guard self.lock.withLock({ self.running && gen == self.generation }) else { return }
            await self.connect()
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case ConnectError.server(_, let message, _): message
        case ConnectError.transport(let why): why
        case ConnectError.invalid(let why): why
        default: (error as? URLError)?.localizedDescription ?? "connection lost"
        }
    }
}
