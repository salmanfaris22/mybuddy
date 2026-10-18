import Foundation

/// Sender-side flow control for `file.chunk` (PROTOCOL §5.5): at most `window` chunks may be un-acknowledged,
/// so a large transfer can never flood the connection that also carries input and control traffic.
public struct SendWindow: Sendable, Equatable {
    public static let defaultWindow = 8

    public let chunkCount: Int
    public let window: Int
    public private(set) var nextToSend: Int
    /// Highest contiguous index the receiver has written (-1 before the first ack).
    public private(set) var highestAcked: Int

    public init(chunkCount: Int, from start: Int = 0, window: Int = SendWindow.defaultWindow) {
        self.chunkCount = max(0, chunkCount)
        self.window = max(1, window)
        nextToSend = min(max(0, start), self.chunkCount)
        highestAcked = nextToSend - 1
    }

    /// Indices that may be sent now, in order (the caller sends all of them).
    public mutating func takeSendable() -> [Int] {
        var out: [Int] = []
        while nextToSend < chunkCount, nextToSend - (highestAcked + 1) < window {
            out.append(nextToSend)
            nextToSend += 1
        }
        return out
    }

    /// Records an ack. Returns false for an index that was never sent (a protocol violation).
    @discardableResult
    public mutating func ack(_ index: Int) -> Bool {
        guard index < nextToSend, index >= 0 else { return false }
        highestAcked = max(highestAcked, index)
        return true
    }

    public var allAcked: Bool { highestAcked == chunkCount - 1 }
    public var ackedBytesFraction: Double { chunkCount == 0 ? 1 : Double(highestAcked + 1) / Double(chunkCount) }
}

extension FileOffer {
    /// Parses a validated `file.offer` payload.
    public init?(payload p: [String: JSONValue]) {
        guard let id = p["transferId"]?.stringValue.flatMap(UUID.init(uuidString:)), let name = p["name"]?.stringValue,
              let size = p["size"]?.intValue, let sha = p["sha256"]?.stringValue, let chunk = p["chunkSize"]?.intValue
        else { return nil }
        self.init(transferId: id, name: name, size: size, sha256: sha, chunkSize: Int(chunk), mimeType: p["mimeType"]?.stringValue)
    }

    public var payload: [String: JSONValue] {
        var p: [String: JSONValue] = ["transferId": .string(transferId.uuidString.lowercased()), "name": .string(name), "size": .int(size),
                                      "sha256": .string(sha256), "chunkSize": .int(Int64(chunkSize))]
        if let mimeType { p["mimeType"] = .string(String(mimeType.prefix(128))) }
        return p
    }
}

/// `file.error.code` values.
public enum TransferErrorCode: String, Sendable {
    case checksumMismatch = "checksum_mismatch"
    case tooLarge = "too_large"
    case diskFull = "disk_full"
    case denied, timeout
    case invalidChunk = "invalid_chunk"
    case cancelled
}
