import CryptoKit
import Foundation

/// A device's long-term ECDSA P-256 identity. Implementations keep the private key in
/// the Keychain / Secure Enclave (Mac) — see `MyBuddyHost.KeychainIdentityStore`.
public protocol DeviceIdentity: Sendable {
    /// SubjectPublicKeyInfo DER of the public key.
    var publicKeySPKI: Data { get }
    /// Signs SHA-256(message) and returns an ASN.1 DER ECDSA signature.
    func sign(_ message: Data) throws -> Data
}

public extension DeviceIdentity {
    var deviceId: String { IdentityMath.deviceId(spki: publicKeySPKI) }
    var fingerprint: String { IdentityMath.fingerprint(spki: publicKeySPKI) }
}

public enum IdentityMath {
    /// Lowercase hex of the first 16 bytes of SHA-256(SPKI).
    public static func deviceId(spki: Data) -> String { Hex.encode(spki.sha256.prefix(16)) }
    /// base64url(SHA-256(SPKI)) — pinned out of band via the pairing QR.
    public static func fingerprint(spki: Data) -> String { Base64URL.encode(spki.sha256) }

    /// Verifies a DER signature over `message` with an SPKI public key.
    public static func verify(spki: Data, message: Data, derSignature: Data) -> Bool {
        guard spki.count <= 200, derSignature.count <= 80,
              let key = try? P256.Signing.PublicKey(derRepresentation: spki),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: derSignature)
        else { return false }
        return key.isValidSignature(signature, for: message)
    }
}

/// An in-memory software identity (tests, previews). Production uses the Keychain store.
public struct SoftwareIdentity: DeviceIdentity {
    private let key: P256.Signing.PrivateKey

    public init() { key = P256.Signing.PrivateKey() }
    public init(rawScalar: Data) throws { key = try P256.Signing.PrivateKey(rawRepresentation: rawScalar) }

    public var publicKeySPKI: Data { key.publicKey.derRepresentation }
    public func sign(_ message: Data) throws -> Data { try key.signature(for: message).derRepresentation }
    public var rawRepresentation: Data { key.rawRepresentation }
}
