import CryptoKit
import Foundation

public enum PairingError: Error, Equatable, Sendable {
    case invalidInvitation(String)
    case expired
    case windowClosed
}

/// The contents of the pairing QR code (docs/PROTOCOL.md §6.1).
public struct PairingInvitation: Sendable, Equatable {
    public let addresses: [String]
    public let hostFingerprint: String
    public let secret: Data
    public let expiresAt: Date
    public let displayName: String

    public init(addresses: [String], hostFingerprint: String, secret: Data, expiresAt: Date, displayName: String) {
        self.addresses = addresses
        self.hostFingerprint = hostFingerprint
        self.secret = secret
        // The QR carries whole seconds; normalize so an invitation equals its parsed form.
        self.expiresAt = Date(timeIntervalSince1970: expiresAt.timeIntervalSince1970.rounded(.down))
        self.displayName = String(displayName.unicodeScalars.prefix(32).map(Character.init))
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = "mybuddy"
        c.host = "pair"
        c.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "h", value: addresses.joined(separator: ",")),
            URLQueryItem(name: "fp", value: hostFingerprint),
            URLQueryItem(name: "s", value: Base64URL.encode(secret)),
            URLQueryItem(name: "x", value: String(Int64(expiresAt.timeIntervalSince1970))),
            URLQueryItem(name: "n", value: displayName),
        ]
        return c.url!
    }

    public static func parse(_ string: String, now: Date = Date()) throws(PairingError) -> PairingInvitation {
        guard string.utf8.count <= 1024, let c = URLComponents(string: string), c.scheme == "mybuddy", c.host == "pair" else {
            throw .invalidInvitation("not a MyBuddy pairing code")
        }
        var q: [String: String] = [:]
        for item in c.queryItems ?? [] {
            guard q[item.name] == nil else { throw .invalidInvitation("duplicate parameter \(item.name)") }
            q[item.name] = item.value ?? ""
        }
        guard q["v"] == "1" else { throw .invalidInvitation("unsupported version") }
        let addresses = (q["h"] ?? "").split(separator: ",").map(String.init)
        guard (1...4).contains(addresses.count), addresses.allSatisfy(isValidHostPort) else {
            throw .invalidInvitation("bad host address")
        }
        guard let fp = q["fp"], fp.count == 43, Base64URL.decode(fp)?.count == 32 else { throw .invalidInvitation("bad fingerprint") }
        guard let s = q["s"], let secret = Base64URL.decode(s), secret.count == 32 else { throw .invalidInvitation("bad secret") }
        guard let xs = q["x"], let x = Int64(xs) else { throw .invalidInvitation("bad expiry") }
        let expires = Date(timeIntervalSince1970: TimeInterval(x))
        guard expires > now else { throw .expired }
        let name = q["n"] ?? ""
        guard name.unicodeScalars.count <= 32 else { throw .invalidInvitation("bad name") }
        return PairingInvitation(addresses: addresses, hostFingerprint: fp, secret: secret, expiresAt: expires, displayName: name)
    }

    static func isValidHostPort(_ s: String) -> Bool {
        let host: Substring
        let port: Substring
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]"), s.index(after: close) < s.endIndex, s[s.index(after: close)] == ":" else { return false }
            host = s[s.index(after: s.startIndex)..<close]
            port = s[s.index(close, offsetBy: 2)...]
        } else {
            let parts = s.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return false }
            host = parts[0]
            port = parts[1]
        }
        guard let p = Int(port), (1...65535).contains(p), !host.isEmpty, host.count <= 253 else { return false }
        guard host.allSatisfy({ $0.isLetter || $0.isNumber || ".-:%".contains($0) }) else { return false }
        // The phone only dials the local network (PROTOCOL.md §6.1).
        return EndpointValidator.classify(host: String(host)) != .publicInternet
    }
}

/// Host-side pairing window: one invitation at a time, short-lived, single use.
/// The secret is invalidated by a successful proof, by closing the window, by expiry,
/// or after `maxFailedAttempts` failed proofs.
public final class PairingWindow: @unchecked Sendable {
    private let lock = NSLock()
    private let lifetime: TimeInterval
    private let maxFailedAttempts: Int
    private let now: @Sendable () -> Date
    private var invitation: PairingInvitation?
    private var failedAttempts = 0

    public init(lifetime: TimeInterval = 120, maxFailedAttempts: Int = 5, now: @escaping @Sendable () -> Date = { Date() }) {
        self.lifetime = lifetime
        self.maxFailedAttempts = maxFailedAttempts
        self.now = now
    }

    /// Opens (or re-opens) the window with a fresh 256-bit secret.
    public func open(addresses: [String], hostFingerprint: String, displayName: String) -> PairingInvitation {
        lock.lock()
        defer { lock.unlock() }
        let inv = PairingInvitation(addresses: addresses, hostFingerprint: hostFingerprint, secret: MBH1.randomBytes(32),
                                    expiresAt: now().addingTimeInterval(lifetime), displayName: displayName)
        invitation = inv
        failedAttempts = 0
        return inv
    }

    public func close() {
        lock.lock()
        invitation = nil
        lock.unlock()
    }

    /// The open, unexpired invitation (nil when closed).
    public var current: PairingInvitation? {
        lock.lock()
        defer { lock.unlock() }
        if let inv = invitation, inv.expiresAt <= now() { invitation = nil }
        return invitation
    }

    public var isOpen: Bool { current != nil }

    /// Constant-time proof check. Consumes the secret on success.
    public func checkProof(_ proof: Data, th2: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let inv = invitation, inv.expiresAt > now() else {
            invitation = nil
            return false
        }
        let valid = HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: Data("MBH1/pair-proof".utf8) + th2,
                                                           using: SymmetricKey(data: inv.secret))
        if valid {
            invitation = nil
        } else {
            failedAttempts += 1
            if failedAttempts >= maxFailedAttempts { invitation = nil }
        }
        return valid
    }
}

// MARK: - Trust store

public struct TrustedDevice: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let publicKeySPKI: Data
    public var name: String
    public var platform: String
    public let pairedAt: Date
    public var lastSeenAt: Date?
    public var grant: PermissionGrant
    public var revokedAt: Date?

    public var isActive: Bool { revokedAt == nil }

    public init(id: String, publicKeySPKI: Data, name: String, platform: String, pairedAt: Date, lastSeenAt: Date?,
                grant: PermissionGrant, revokedAt: Date?) {
        self.id = id
        self.publicKeySPKI = publicKeySPKI
        self.name = name
        self.platform = platform
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
        self.grant = grant
        self.revokedAt = revokedAt
    }
}

public protocol TrustStorage: Sendable {
    func load() throws -> [TrustedDevice]
    func save(_ devices: [TrustedDevice]) throws
}

public final class InMemoryTrustStorage: TrustStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var devices: [TrustedDevice]
    public init(_ devices: [TrustedDevice] = []) { self.devices = devices }
    public func load() throws -> [TrustedDevice] { lock.withLock { devices } }
    public func save(_ devices: [TrustedDevice]) throws { lock.withLock { self.devices = devices } }
}

/// Trusted phones and their capability grants. The Mac consults this on every session.
public final class TrustStore: @unchecked Sendable {
    private let lock = NSLock()
    private let storage: any TrustStorage
    private var devices: [String: TrustedDevice] = [:]

    public init(storage: any TrustStorage) {
        self.storage = storage
        if let loaded = try? storage.load() {
            for d in loaded { devices[d.id] = d }
        }
    }

    public var all: [TrustedDevice] { lock.withLock { devices.values.sorted { $0.pairedAt < $1.pairedAt } } }
    public var active: [TrustedDevice] { all.filter(\.isActive) }

    public func device(id: String) -> TrustedDevice? { lock.withLock { devices[id] } }

    /// True only for an active device whose stored key matches exactly.
    public func isTrusted(spki: Data) -> Bool {
        lock.withLock {
            guard let d = devices[IdentityMath.deviceId(spki: spki)] else { return false }
            return d.isActive && d.publicKeySPKI == spki
        }
    }

    @discardableResult
    public func trust(spki: Data, name: String, platform: String, grant: PermissionGrant = PermissionGrant(), now: Date = Date()) throws -> TrustedDevice {
        let device = TrustedDevice(id: IdentityMath.deviceId(spki: spki), publicKeySPKI: spki, name: name, platform: platform,
                                   pairedAt: now, lastSeenAt: now, grant: grant, revokedAt: nil)
        try mutate { $0[device.id] = device }
        return device
    }

    public func revoke(id: String, now: Date = Date()) throws {
        try mutate { devices in
            guard var d = devices[id], d.revokedAt == nil else { return }
            d.revokedAt = now
            devices[id] = d
        }
    }

    public func remove(id: String) throws { try mutate { $0[id] = nil } }

    public func setCapability(_ capability: Capability, enabled: Bool, for id: String) throws {
        try mutate { devices in
            guard var d = devices[id] else { return }
            d.grant.set(capability, enabled: enabled)
            devices[id] = d
        }
    }

    public func touch(id: String, now: Date = Date()) throws {
        try mutate { devices in
            guard var d = devices[id] else { return }
            d.lastSeenAt = now
            devices[id] = d
        }
    }

    private func mutate(_ body: (inout [String: TrustedDevice]) -> Void) throws {
        try lock.withLock {
            var copy = devices
            body(&copy)
            try storage.save(copy.values.sorted { $0.pairedAt < $1.pairedAt })
            devices = copy
        }
    }
}
