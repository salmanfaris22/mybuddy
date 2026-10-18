import CryptoKit
import Foundation

/// MBH1: the MyBuddy mutual-authentication handshake and frame protection
/// (docs/PROTOCOL.md §6). Pure and transport-agnostic.
public enum MBH1 {
    public static let protocolVersion = 1
    public static let maxFrameBytes = 192 * 1024

    public enum Mode: String, Sendable, Codable { case pair, resume }

    static func th1(mode: Mode, clientEphemeral: Data, clientNonce: Data, hostEphemeral: Data, hostNonce: Data, hostIdentityKey: Data) -> Data {
        var d = Data("MBH1/th1".utf8)
        d += Data(mode.rawValue.utf8).lengthPrefixed
        d += clientEphemeral.lengthPrefixed
        d += clientNonce.lengthPrefixed
        d += hostEphemeral.lengthPrefixed
        d += hostNonce.lengthPrefixed
        d += hostIdentityKey.lengthPrefixed
        return d.sha256
    }

    static func th2(th1: Data, clientIdentityKey: Data, clientName: String, platform: String) -> Data {
        var d = Data("MBH1/th2".utf8)
        d += th1
        d += clientIdentityKey.lengthPrefixed
        d += Data(clientName.utf8).lengthPrefixed
        d += Data(platform.utf8).lengthPrefixed
        return d.sha256
    }

    static func hostSignedMessage(th1: Data) -> Data { Data("MBH1/host-sig".utf8) + th1 }
    static func clientSignedMessage(th2: Data) -> Data { Data("MBH1/client-sig".utf8) + th2 }

    /// HMAC-SHA256(secret, "MBH1/pair-proof" ‖ TH2) — proves the client scanned the QR.
    public static func pairingProof(secret: Data, th2: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("MBH1/pair-proof".utf8) + th2, using: SymmetricKey(data: secret)))
    }

    /// Derives directional keys, the 6-digit SAS and the session id from the ECDH secret.
    public static func deriveSession(sharedSecret: Data, th2: Data) -> SessionKeys {
        let ikm = SymmetricKey(data: sharedSecret)
        func hkdf(_ info: String, _ count: Int) -> Data {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: th2, info: Data(info.utf8), outputByteCount: count)
                .withUnsafeBytes { Data($0) }
        }
        let okm = hkdf("MBH1/keys", 64)
        let sasValue = hkdf("MBH1/sas", 4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        return SessionKeys(
            c2h: SymmetricKey(data: okm.prefix(32)),
            h2c: SymmetricKey(data: okm.suffix(32)),
            sas: String(format: "%06u", sasValue),
            sessionId: "s_" + Base64URL.encode(hkdf("MBH1/session-id", 12))
        )
    }

    public static func randomBytes(_ count: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &g) })
    }
}

public struct SessionKeys: Sendable {
    public let c2h: SymmetricKey
    public let h2c: SymmetricKey
    /// 6-digit short authentication string shown on both screens during pairing.
    public let sas: String
    public let sessionId: String
}

public enum HandshakeError: Error, Equatable, Sendable {
    case malformed(String)
    case unsupportedProtocol
    case wrongState
    case hostKeyMismatch
    case badHostSignature
    case badClientSignature
    case pairingProofInvalid
    case notTrusted
}

// MARK: - Wire messages

struct HelloMessage: Codable {
    var type = "hs.hello"
    var protocolVersion: Int
    var mode: MBH1.Mode
    var clientEphemeral: String
    var clientNonce: String

    enum CodingKeys: String, CodingKey {
        case type, mode, clientEphemeral, clientNonce
        case protocolVersion = "protocol"
    }
}

struct HostMessage: Codable {
    var type = "hs.host"
    var hostEphemeral: String
    var hostNonce: String
    var hostIdentityKey: String
    var signature: String
}

struct ClientMessage: Codable {
    var type = "hs.client"
    var clientIdentityKey: String
    var clientName: String
    var platform: String
    var signature: String
    var pairingProof: String?
}

private func encodeJSON(_ value: some Encodable) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(value)) ?? Data()
}

private func decodeJSON<T: Decodable>(_: T.Type, _ data: Data, type: String) throws(HandshakeError) -> T {
    guard data.count <= 4096 else { throw .malformed("handshake message too large") }
    guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw .malformed("cannot decode \(type)") }
    return value
}

private func decodeField(_ s: String, exact: Int? = nil, max: Int = 200, _ name: String) throws(HandshakeError) -> Data {
    guard let d = Base64URL.decode(s), !d.isEmpty, d.count <= max else { throw .malformed(name) }
    if let exact, d.count != exact { throw .malformed(name) }
    return d
}

private func validName(_ s: String) -> Bool {
    let n = s.unicodeScalars.count
    return n >= 1 && n <= 64 && !s.unicodeScalars.contains { $0.properties.generalCategory == .control }
}

// MARK: - Client (phone side; also used by Mac tests and tools)

public struct MBH1Client {
    public struct Result: Sendable {
        public let keys: SessionKeys
        public let hostIdentityKey: Data
        public var hostDeviceId: String { IdentityMath.deviceId(spki: hostIdentityKey) }
    }

    private let mode: MBH1.Mode
    private let identity: any DeviceIdentity
    private let clientName: String
    private let platform: String
    private let pinnedFingerprint: String
    private let pairingSecret: Data?
    private let ephemeral: P256.KeyAgreement.PrivateKey
    private let nonce: Data
    private var sentHello = false

    public init(mode: MBH1.Mode, identity: any DeviceIdentity, clientName: String, platform: String,
                pinnedHostFingerprint: String, pairingSecret: Data?,
                ephemeral: P256.KeyAgreement.PrivateKey = .init(), nonce: Data = MBH1.randomBytes(32)) {
        self.mode = mode
        self.identity = identity
        self.clientName = clientName
        self.platform = platform
        self.pinnedFingerprint = pinnedHostFingerprint
        self.pairingSecret = pairingSecret
        self.ephemeral = ephemeral
        self.nonce = nonce
    }

    public mutating func makeHello() -> Data {
        sentHello = true
        return encodeJSON(HelloMessage(protocolVersion: MBH1.protocolVersion, mode: mode,
                                       clientEphemeral: Base64URL.encode(ephemeral.publicKey.x963Representation),
                                       clientNonce: Base64URL.encode(nonce)))
    }

    /// Verifies the host and returns the `hs.client` reply plus session keys.
    public mutating func handleHost(_ data: Data) throws(HandshakeError) -> (reply: Data, result: Result) {
        guard sentHello else { throw .wrongState }
        sentHello = false
        let msg = try decodeJSON(HostMessage.self, data, type: "hs.host")
        guard msg.type == "hs.host" else { throw .malformed("type") }
        let hostEph = try decodeField(msg.hostEphemeral, exact: 65, "hostEphemeral")
        let hostNonce = try decodeField(msg.hostNonce, exact: 32, "hostNonce")
        let hostKey = try decodeField(msg.hostIdentityKey, "hostIdentityKey")
        let hostSig = try decodeField(msg.signature, max: 80, "signature")

        guard IdentityMath.fingerprint(spki: hostKey) == pinnedFingerprint else { throw .hostKeyMismatch }
        let clientEph = ephemeral.publicKey.x963Representation
        let th1 = MBH1.th1(mode: mode, clientEphemeral: clientEph, clientNonce: nonce, hostEphemeral: hostEph,
                           hostNonce: hostNonce, hostIdentityKey: hostKey)
        guard IdentityMath.verify(spki: hostKey, message: MBH1.hostSignedMessage(th1: th1), derSignature: hostSig) else {
            throw .badHostSignature
        }
        let clientKey = identity.publicKeySPKI
        let th2 = MBH1.th2(th1: th1, clientIdentityKey: clientKey, clientName: clientName, platform: platform)
        guard let signature = try? identity.sign(MBH1.clientSignedMessage(th2: th2)) else { throw .malformed("signing failed") }
        guard let hostPublic = try? P256.KeyAgreement.PublicKey(x963Representation: hostEph),
              let shared = try? ephemeral.sharedSecretFromKeyAgreement(with: hostPublic)
        else { throw .malformed("hostEphemeral") }
        let keys = MBH1.deriveSession(sharedSecret: shared.withUnsafeBytes { Data($0) }, th2: th2)
        var reply = ClientMessage(clientIdentityKey: Base64URL.encode(clientKey), clientName: clientName, platform: platform,
                                  signature: Base64URL.encode(signature))
        if mode == .pair, let secret = pairingSecret {
            reply.pairingProof = Base64URL.encode(MBH1.pairingProof(secret: secret, th2: th2))
        }
        return (encodeJSON(reply), Result(keys: keys, hostIdentityKey: hostKey))
    }
}

// MARK: - Host (Mac side)

public struct MBH1Host {
    public struct Result: Sendable {
        public let mode: MBH1.Mode
        public let keys: SessionKeys
        public let clientIdentityKey: Data
        public let clientName: String
        public let platform: String
        public var clientDeviceId: String { IdentityMath.deviceId(spki: clientIdentityKey) }
    }

    /// Policy hooks supplied by the pairing window and trust store.
    public struct Verifier: Sendable {
        /// Pair mode: returns true only if `proof` matches the open pairing window's secret.
        /// Implementations must invalidate the secret after one attempt.
        public var checkPairingProof: @Sendable (_ proof: Data, _ th2: Data) -> Bool
        /// Resume mode: returns true if the SPKI belongs to a trusted, non-revoked device.
        public var isTrusted: @Sendable (_ spki: Data) -> Bool

        public init(checkPairingProof: @escaping @Sendable (Data, Data) -> Bool, isTrusted: @escaping @Sendable (Data) -> Bool) {
            self.checkPairingProof = checkPairingProof
            self.isTrusted = isTrusted
        }
    }

    private let identity: any DeviceIdentity
    private let ephemeral: P256.KeyAgreement.PrivateKey
    private let nonce: Data
    private var pending: (mode: MBH1.Mode, th1: Data, clientEphemeral: Data)?

    public init(identity: any DeviceIdentity, ephemeral: P256.KeyAgreement.PrivateKey = .init(), nonce: Data = MBH1.randomBytes(32)) {
        self.identity = identity
        self.ephemeral = ephemeral
        self.nonce = nonce
    }

    public mutating func handleHello(_ data: Data) throws(HandshakeError) -> Data {
        guard pending == nil else { throw .wrongState }
        let msg = try decodeJSON(HelloMessage.self, data, type: "hs.hello")
        guard msg.type == "hs.hello" else { throw .malformed("type") }
        guard msg.protocolVersion == MBH1.protocolVersion else { throw .unsupportedProtocol }
        let clientEph = try decodeField(msg.clientEphemeral, exact: 65, "clientEphemeral")
        let clientNonce = try decodeField(msg.clientNonce, exact: 32, "clientNonce")
        guard (try? P256.KeyAgreement.PublicKey(x963Representation: clientEph)) != nil else { throw .malformed("clientEphemeral") }
        let hostKey = identity.publicKeySPKI
        let hostEph = ephemeral.publicKey.x963Representation
        let th1 = MBH1.th1(mode: msg.mode, clientEphemeral: clientEph, clientNonce: clientNonce, hostEphemeral: hostEph,
                           hostNonce: nonce, hostIdentityKey: hostKey)
        guard let signature = try? identity.sign(MBH1.hostSignedMessage(th1: th1)) else { throw .malformed("signing failed") }
        pending = (msg.mode, th1, clientEph)
        return encodeJSON(HostMessage(hostEphemeral: Base64URL.encode(hostEph), hostNonce: Base64URL.encode(nonce),
                                      hostIdentityKey: Base64URL.encode(hostKey), signature: Base64URL.encode(signature)))
    }

    public mutating func handleClient(_ data: Data, verifier: Verifier) throws(HandshakeError) -> Result {
        guard let state = pending else { throw .wrongState }
        pending = nil
        let msg = try decodeJSON(ClientMessage.self, data, type: "hs.client")
        guard msg.type == "hs.client" else { throw .malformed("type") }
        let clientKey = try decodeField(msg.clientIdentityKey, "clientIdentityKey")
        let signature = try decodeField(msg.signature, max: 80, "signature")
        guard validName(msg.clientName) else { throw .malformed("clientName") }
        guard msg.platform == "android" || msg.platform == "macos" else { throw .malformed("platform") }
        let th2 = MBH1.th2(th1: state.th1, clientIdentityKey: clientKey, clientName: msg.clientName, platform: msg.platform)
        guard IdentityMath.verify(spki: clientKey, message: MBH1.clientSignedMessage(th2: th2), derSignature: signature) else {
            throw .badClientSignature
        }
        switch state.mode {
        case .pair:
            guard let proofString = msg.pairingProof,
                  let proof = Base64URL.decode(proofString), proof.count == 32,
                  verifier.checkPairingProof(proof, th2)
            else { throw .pairingProofInvalid }
        case .resume:
            guard verifier.isTrusted(clientKey) else { throw .notTrusted }
        }
        guard let clientPublic = try? P256.KeyAgreement.PublicKey(x963Representation: state.clientEphemeral),
              let shared = try? ephemeral.sharedSecretFromKeyAgreement(with: clientPublic)
        else { throw .malformed("clientEphemeral") }
        let keys = MBH1.deriveSession(sharedSecret: shared.withUnsafeBytes { Data($0) }, th2: th2)
        return Result(mode: state.mode, keys: keys, clientIdentityKey: clientKey, clientName: msg.clientName, platform: msg.platform)
    }
}

// MARK: - Frames

public enum FrameDirection: UInt8, Sendable {
    case clientToHost = 1
    case hostToClient = 2
}

public enum FrameError: Error, Equatable, Sendable {
    case tooLarge
    case truncated
    case unexpectedCounter(expected: UInt64, got: UInt64)
    case authenticationFailed
    case counterExhausted
}

private func frameNonceAndAAD(direction: FrameDirection, counter: UInt64) -> (AES.GCM.Nonce, Data) {
    var be = counter.bigEndian
    let counterBytes = withUnsafeBytes(of: &be) { Data($0) }
    let nonce = try! AES.GCM.Nonce(data: Data(count: 4) + counterBytes)
    return (nonce, Data("MBH1/frame".utf8) + Data([direction.rawValue]) + counterBytes)
}

public struct FrameSealer: Sendable {
    private let key: SymmetricKey
    private let direction: FrameDirection
    public private(set) var counter: UInt64

    public init(key: SymmetricKey, direction: FrameDirection, startCounter: UInt64 = 0) {
        self.key = key
        self.direction = direction
        self.counter = startCounter
    }

    public mutating func seal(_ plaintext: Data) throws(FrameError) -> Data {
        guard counter < UInt64.max else { throw .counterExhausted }
        guard plaintext.count + 24 <= MBH1.maxFrameBytes else { throw .tooLarge }
        let (nonce, aad) = frameNonceAndAAD(direction: direction, counter: counter)
        guard let box = try? AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad) else {
            throw .authenticationFailed
        }
        var be = counter.bigEndian
        counter += 1
        return withUnsafeBytes(of: &be) { Data($0) } + box.ciphertext + box.tag
    }
}

public struct FrameOpener: Sendable {
    private let key: SymmetricKey
    private let direction: FrameDirection
    public private(set) var expected: UInt64 = 0

    public init(key: SymmetricKey, direction: FrameDirection) {
        self.key = key
        self.direction = direction
    }

    public mutating func open(_ frame: Data) throws(FrameError) -> Data {
        guard frame.count <= MBH1.maxFrameBytes else { throw .tooLarge }
        guard frame.count >= 8 + 16 else { throw .truncated }
        let bytes = [UInt8](frame)
        let counter = bytes[0..<8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard counter == expected else { throw .unexpectedCounter(expected: expected, got: counter) }
        let (nonce, aad) = frameNonceAndAAD(direction: direction, counter: counter)
        let body = Data(bytes[8...])
        guard let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: body.dropLast(16), tag: body.suffix(16)),
              let plaintext = try? AES.GCM.open(box, using: key, authenticating: aad)
        else { throw .authenticationFailed }
        expected += 1
        return plaintext
    }
}

// MARK: - Session (frames + envelopes)

public enum SessionError: Error, Equatable, Sendable {
    case frame(FrameError)
    case protocolViolation(ProtocolError)
    case sessionMismatch
}

/// An established MBH1 session: encrypts/decrypts frames and enforces envelope rules.
public struct SecureSession: Sendable {
    public let role: ProtocolRole
    public let sessionId: String
    public let sas: String
    private var sealer: FrameSealer
    private var opener: FrameOpener
    private var outgoing = SequenceCounter()
    private var incoming = SequenceGuard()

    public init(role: ProtocolRole, keys: SessionKeys) {
        self.role = role
        sessionId = keys.sessionId
        sas = keys.sas
        switch role {
        case .mac:
            sealer = FrameSealer(key: keys.h2c, direction: .hostToClient)
            opener = FrameOpener(key: keys.c2h, direction: .clientToHost)
        case .phone:
            sealer = FrameSealer(key: keys.c2h, direction: .clientToHost)
            opener = FrameOpener(key: keys.h2c, direction: .hostToClient)
        }
    }

    private var peer: ProtocolRole { role == .mac ? .phone : .mac }

    /// Builds, validates and encrypts an outgoing envelope.
    public mutating func seal(_ type: EventType, payload: [String: JSONValue], replyTo: Int64? = nil, now: Date = Date()) throws(SessionError) -> (frame: Data, sequence: Int64) {
        let sequence = outgoing.next()
        let envelope = Envelope(type: type, sessionId: sessionId, sequence: sequence, sentAt: now, replyTo: replyTo, payload: payload)
        let data: Data
        do { data = try EnvelopeCodec.encode(envelope, receiver: peer) } catch { throw .protocolViolation(error) }
        do { return (try sealer.seal(data), sequence) } catch { throw .frame(error) }
    }

    /// Decrypts and validates an incoming frame. Frame errors are fatal for the session;
    /// protocol errors may be answered with an `error` event.
    public mutating func open(_ frame: Data) throws(SessionError) -> Envelope {
        let plaintext: Data
        do { plaintext = try opener.open(frame) } catch { throw .frame(error) }
        let envelope: Envelope
        do { envelope = try EnvelopeCodec.decode(plaintext, receiver: role) } catch { throw .protocolViolation(error) }
        guard envelope.sessionId == sessionId else { throw .sessionMismatch }
        do { try incoming.accept(envelope) } catch { throw .protocolViolation(error) }
        return envelope
    }
}
