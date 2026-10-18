import CryptoKit
import Foundation
import MyBuddyCore
import Security

/// Generic-password Keychain helpers (login keychain, this device only, never synced).
enum Keychain {
    static func read(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return item as? Data
    }

    static func write(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attributes) { $1 }
            add[kSecAttrSynchronizable as String] = kCFBooleanFalse
            add[kSecAttrLabel as String] = "MyBuddy — \(account)"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

public struct KeychainError: Error, CustomStringConvertible, Sendable {
    public let status: OSStatus
    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        return "Keychain error \(status): \(message)"
    }
}

/// Provider API keys in the Keychain. Values never leave this type except to the provider adapter.
public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    public init() {}
    public func read(_ ref: SecretReference) throws -> String? {
        try Keychain.read(service: ref.service, account: ref.account).map { String(decoding: $0, as: UTF8.self) }
    }
    public func write(_ value: String, for ref: SecretReference) throws {
        try Keychain.write(Data(value.utf8), service: ref.service, account: ref.account)
    }
    public func delete(_ ref: SecretReference) throws {
        try Keychain.delete(service: ref.service, account: ref.account)
    }
}

/// Where the device identity private key lives.
public enum IdentityBackend: String, Sendable {
    case secureEnclave = "Secure Enclave"
    case keychainSoftwareKey = "Keychain (software key)"
}

/// Secure Enclave–backed identity: the private key never exists outside the SE.
struct SecureEnclaveIdentity: DeviceIdentity {
    let key: SecureEnclave.P256.Signing.PrivateKey
    var publicKeySPKI: Data { key.publicKey.derRepresentation }
    func sign(_ message: Data) throws -> Data { try key.signature(for: message).derRepresentation }
}

/// Loads or creates this Mac's long-term identity.
public enum KeychainIdentityStore {
    static let service = "app.mybuddy.mac.identity"

    public static func loadOrCreate(account: String = "device-identity-v1", preferSecureEnclave: Bool = true) throws -> (identity: any DeviceIdentity, backend: IdentityBackend) {
        if let blob = try Keychain.read(service: service, account: account + ".se"),
           let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob) {
            return (SecureEnclaveIdentity(key: key), .secureEnclave)
        }
        if let raw = try Keychain.read(service: service, account: account + ".sw") {
            return (try SoftwareIdentity(rawScalar: raw), .keychainSoftwareKey)
        }
        if preferSecureEnclave, SecureEnclave.isAvailable, let key = try? SecureEnclave.P256.Signing.PrivateKey() {
            // dataRepresentation is an SE-wrapped blob, useless off this Mac.
            try Keychain.write(key.dataRepresentation, service: service, account: account + ".se")
            return (SecureEnclaveIdentity(key: key), .secureEnclave)
        }
        let software = SoftwareIdentity()
        try Keychain.write(software.rawRepresentation, service: service, account: account + ".sw")
        return (software, .keychainSoftwareKey)
    }

    /// Deletes the identity (used by "Reset MyBuddy identity"; all pairings must be redone).
    public static func reset(account: String = "device-identity-v1") throws {
        try Keychain.delete(service: service, account: account + ".se")
        try Keychain.delete(service: service, account: account + ".sw")
    }
}

/// Trusted-device list stored as JSON in a Keychain item.
public final class KeychainTrustStorage: TrustStorage, @unchecked Sendable {
    private let account: String
    public init(account: String = "trusted-devices-v1") { self.account = account }

    public func load() throws -> [TrustedDevice] {
        guard let data = try Keychain.read(service: "app.mybuddy.mac.trust", account: account) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([TrustedDevice].self, from: data)
    }

    public func save(_ devices: [TrustedDevice]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try Keychain.write(try encoder.encode(devices), service: "app.mybuddy.mac.trust", account: account)
    }

    public func deleteAll() throws { try Keychain.delete(service: "app.mybuddy.mac.trust", account: account) }
}
