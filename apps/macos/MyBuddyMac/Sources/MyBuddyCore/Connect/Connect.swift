import Foundation

/// MyBuddy Connect statements (PROTOCOL §7). Each is `label ‖ lp(field)…` with 4-byte big-endian length
/// prefixes, signed by the device key (ECDSA P-256, SHA-256, DER). Byte layout is pinned by the shared vectors.
public enum ConnectStatements {
    static func lp(_ data: Data) -> Data {
        var length = UInt32(data.count).bigEndian
        return Data(bytes: &length, count: 4) + data
    }

    static func lp(_ string: String) -> Data { lp(Data(string.utf8)) }

    public static func register(spki: Data, platform: String) -> Data {
        Data("MBC1/register".utf8) + lp(spki) + lp(platform)
    }

    public static func auth(challengeId: String, nonce: Data, deviceId: String) -> Data {
        Data("MBC1/auth".utf8) + lp(challengeId) + lp(nonce) + lp(deviceId)
    }

    public static func pairing(hostDeviceId: String, clientDeviceId: String, createdAt: String) -> Data {
        Data("MBC1/pairing".utf8) + lp(hostDeviceId) + lp(clientDeviceId) + lp(createdAt)
    }

    /// Binds a WebRTC offer/answer to both devices, one rendezvous and a time, so the server can neither
    /// alter it (DTLS fingerprints) nor replay it elsewhere.
    public static func rtc(kind: String, rid: String, from: String, to: String, at: String, sdp: String) -> Data {
        Data("MBC1/rtc".utf8) + lp(kind) + lp(rid) + lp(from) + lp(to) + lp(at) + lp(sdp)
    }
}

/// One message of the WebRTC introduction, carried base64url-encoded in a `/v1/signal` relay message.
/// Offers and answers are signed; ICE candidates and `bye` are bound to the rendezvous id only.
public struct RendezvousMessage: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case offer, answer, ice, bye }

    public var v: Int
    public var kind: Kind
    public var rid: String
    public var from: String
    public var to: String
    public var at: String?
    public var sdp: String?
    public var sig: String?
    public var candidate: String?
    public var sdpMid: String?
    public var sdpMLineIndex: Int?
    public var reason: String?

    public static let maxBytes = 60 * 1024
    public static let maxSkew: TimeInterval = 120

    public init(kind: Kind, rid: String, from: String, to: String, at: String? = nil, sdp: String? = nil, sig: String? = nil,
                candidate: String? = nil, sdpMid: String? = nil, sdpMLineIndex: Int? = nil, reason: String? = nil) {
        v = 1
        self.kind = kind
        self.rid = rid
        self.from = from
        self.to = to
        self.at = at
        self.sdp = sdp
        self.sig = sig
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
        self.reason = reason
    }

    /// A signed offer or answer from `identity`.
    public static func signed(_ kind: Kind, rid: String, identity: any DeviceIdentity, to: String, sdp: String, now: Date = Date()) throws -> RendezvousMessage {
        precondition(kind == .offer || kind == .answer)
        let at = ConnectTime.format(now)
        let statement = ConnectStatements.rtc(kind: kind.rawValue, rid: rid, from: identity.deviceId, to: to, at: at, sdp: sdp)
        return RendezvousMessage(kind: kind, rid: rid, from: identity.deviceId, to: to, at: at, sdp: sdp,
                                 sig: Base64URL.encode(try identity.sign(statement)))
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maxBytes else { throw ConnectError.invalid("rendezvous message too large") }
        return data
    }

    /// Parses and shape-checks a relayed message (ids, sizes, required fields per kind).
    public static func decode(_ data: Data) throws -> RendezvousMessage {
        guard data.count <= maxBytes else { throw ConnectError.invalid("rendezvous message too large") }
        let m = try JSONDecoder().decode(RendezvousMessage.self, from: data)
        guard m.v == 1, ConnectIDs.isDeviceId(m.from), ConnectIDs.isDeviceId(m.to), ConnectIDs.isRendezvousId(m.rid) else {
            throw ConnectError.invalid("bad rendezvous ids")
        }
        switch m.kind {
        case .offer, .answer:
            guard let sdp = m.sdp, !sdp.isEmpty, sdp.utf8.count <= 32 * 1024, m.at != nil, m.sig != nil else { throw ConnectError.invalid("unsigned description") }
        case .ice:
            guard (m.candidate?.utf8.count ?? 0) <= 1024, (m.sdpMid?.count ?? 0) <= 32, (m.sdpMLineIndex ?? 0) >= 0, (m.sdpMLineIndex ?? 0) <= 15 else {
                throw ConnectError.invalid("bad candidate")
            }
        case .bye:
            guard (m.reason?.count ?? 0) <= 64 else { throw ConnectError.invalid("bad reason") }
        }
        return m
    }

    /// True when this offer/answer was signed by `spki` for `expectedTo`, within ±2 minutes of `now`.
    public func verify(signerSPKI spki: Data, expectedTo: String, now: Date = Date()) -> Bool {
        guard kind == .offer || kind == .answer, to == expectedTo, IdentityMath.deviceId(spki: spki) == from,
              let at, let sdp, let sigText = sig, let signature = Base64URL.decode(sigText),
              let time = ConnectTime.parse(at), abs(time.timeIntervalSince(now)) <= Self.maxSkew
        else { return false }
        let statement = ConnectStatements.rtc(kind: kind.rawValue, rid: rid, from: from, to: to, at: at, sdp: sdp)
        return IdentityMath.verify(spki: spki, message: statement, derSignature: signature)
    }
}

/// Remembers recent rendezvous ids so a captured offer can't be replayed within its validity window.
public final class RendezvousReplayGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String: Date] = [:]
    private let window: TimeInterval

    public init(window: TimeInterval = 10 * 60) { self.window = window }

    /// False if `from`+`rid` was already accepted for this kind.
    public func firstUse(from: String, rid: String, kind: RendezvousMessage.Kind, now: Date = Date()) -> Bool {
        lock.withLock {
            seen = seen.filter { now.timeIntervalSince($0.value) < window }
            let key = "\(from)/\(rid)/\(kind.rawValue)"
            guard seen[key] == nil else { return false }
            seen[key] = now
            return true
        }
    }
}

public enum ConnectError: Error, Equatable, Sendable {
    case invalid(String)
    case server(code: String, message: String, status: Int)
    case transport(String)
    case notConfigured
}

public enum ConnectIDs {
    public static func isDeviceId(_ s: String) -> Bool {
        s.utf8.count == 32 && s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// `r_` + 8–64 base64url characters (the server's message-id alphabet).
    public static func isRendezvousId(_ s: String) -> Bool {
        guard s.hasPrefix("r_"), (10...66).contains(s.utf8.count) else { return false }
        return s.utf8.dropFirst(2).allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F }
    }

    public static func newRendezvousId() -> String {
        var bytes = [UInt8](repeating: 0, count: 12)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return "r_" + Base64URL.encode(Data(bytes))
    }
}

/// RFC 3339 with milliseconds in UTC, as the server and the statements use.
public enum ConnectTime {
    public static func format(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    public static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// Which server addresses MyBuddy accepts for Connect: `https://host[:port]` (no path, query, credentials or
/// fragment). Plain `http://` only for this machine's loopback, for local development.
public enum ConnectServerURL {
    public static func normalize(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= 256, let c = URLComponents(string: trimmed), let scheme = c.scheme?.lowercased(),
              let host = c.host?.lowercased(), !host.isEmpty, c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path.isEmpty || c.path == "/"
        else { return nil }
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
        guard scheme == "https" || (scheme == "http" && loopback) else { return nil }
        var out = URLComponents()
        out.scheme = scheme
        out.host = host
        out.port = c.port
        return out.url
    }

    /// The `/v1/signal` WebSocket URL for a normalized server URL.
    public static func signalURL(_ server: URL) -> URL? {
        guard var c = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = c.scheme == "https" ? "wss" : "ws"
        c.path = "/v1/signal"
        return c.url
    }
}

/// `GET /v1/turn-credentials` (coturn REST convention).
public struct TurnCredentials: Codable, Sendable, Equatable {
    public var urls: [String]
    public var username: String
    public var credential: String
    public var ttlSeconds: Int

    public init(urls: [String], username: String, credential: String, ttlSeconds: Int) {
        self.urls = urls
        self.username = username
        self.credential = credential
        self.ttlSeconds = ttlSeconds
    }
}

/// Whether a WebRTC connection's selected candidate pair goes through a TURN relay (from `getStats`).
public enum ICERoute {
    /// nil until a pair is selected; true when either end of the selected pair is a `relay` candidate.
    public static func isRelayed(_ entries: [RTCStatsEntry]) -> Bool? {
        let byId = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let selected = entries.first { $0.type == "transport" }?.string("selectedCandidatePairId")
            ?? entries.first { $0.type == "candidate-pair" && $0.number("nominated") == 1 && $0.string("state") == "succeeded" }?.id
        guard let selected, let pair = byId[selected] else { return nil }
        let local = pair.string("localCandidateId").flatMap { byId[$0] }
        let remote = pair.string("remoteCandidateId").flatMap { byId[$0] }
        guard local != nil || remote != nil else { return nil }
        return local?.string("candidateType") == "relay" || remote?.string("candidateType") == "relay"
    }
}

/// How a session reached the Mac.
public enum SessionRoute: String, Codable, Sendable, Equatable {
    case localNetwork, tailscale, internetDirect, internetRelayed

    public var title: String {
        switch self {
        case .localNetwork: "Local network"
        case .tailscale: "Tailscale"
        case .internetDirect: "Internet · direct"
        case .internetRelayed: "Internet · relayed (TURN)"
        }
    }

    /// File bytes never pass through a server, even encrypted.
    public var allowsFileTransfer: Bool { self != .internetRelayed }
}
