import CryptoKit
import Foundation

/// base64url without padding (RFC 4648 §5) — the binary encoding used throughout the protocol.
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decodes strict base64url (no padding, URL alphabet only). Returns nil on any invalid input.
    public static func decode(_ string: String) -> Data? {
        guard string.utf8.allSatisfy({ byte in
            (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
                || byte == 0x2D || byte == 0x5F
        }) else { return nil }
        // A single trailing character is never valid base64.
        guard string.utf8.count % 4 != 1 else { return nil }
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: s)
    }
}

public enum Hex {
    public static func encode(_ data: some Sequence<UInt8>) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public static func decode(_ string: String) -> Data? {
        guard string.count % 2 == 0 else { return nil }
        var out = Data(capacity: string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }
}

public extension Data {
    /// 4-byte big-endian length prefix followed by the bytes (`lp()` in PROTOCOL.md).
    var lengthPrefixed: Data {
        var out = Data()
        var length = UInt32(count).bigEndian
        Swift.withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(self)
        return out
    }

    var sha256: Data { Data(SHA256.hash(data: self)) }
}

public extension String {
    var utf8Data: Data { Data(utf8) }
}

/// RFC 3339 timestamps with millisecond precision (protocol `sentAt`, report timestamps).
public enum Timestamp {
    public static func string(from date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    public static func parse(_ string: String) -> Date? {
        guard string.count <= 40 else { return nil }
        if let d = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) { return d }
        return try? Date.ISO8601FormatStyle().parse(string)
    }
}
