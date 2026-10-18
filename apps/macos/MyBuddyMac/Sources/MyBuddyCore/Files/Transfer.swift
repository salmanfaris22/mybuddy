import CryptoKit
import Darwin
import Foundation

/// Metadata announced with `file.offer`.
public struct FileOffer: Codable, Sendable, Equatable {
    public let transferId: UUID
    public let name: String
    public let size: Int64
    public let sha256: String
    public let chunkSize: Int
    public let mimeType: String?

    public static let maxSize: Int64 = 2 * 1024 * 1024 * 1024
    public static let defaultChunkSize = 64 * 1024

    public init(transferId: UUID = UUID(), name: String, size: Int64, sha256: String, chunkSize: Int = FileOffer.defaultChunkSize, mimeType: String? = nil) {
        self.transferId = transferId
        self.name = name
        self.size = size
        self.sha256 = sha256
        self.chunkSize = chunkSize
        self.mimeType = mimeType
    }

    public var chunkCount: Int { Int((size + Int64(chunkSize) - 1) / Int64(chunkSize)) }

    public func expectedLength(ofChunk index: Int) -> Int {
        let start = Int64(index) * Int64(chunkSize)
        return Int(min(Int64(chunkSize), size - start))
    }
}

public enum TransferError: Error, Equatable, Sendable {
    case invalidOffer(String)
    case tooLarge
    case invalidChunk(String)
    case checksumMismatch
    case incomplete
    case cancelled
    /// The receiving side said no before any data moved (its user declined, or its limits refused it).
    case declined
    case io(String)
}

public enum TransferState: Equatable, Sendable {
    case awaitingAcceptance
    case inProgress(received: Int64, total: Int64)
    case paused(received: Int64, total: Int64)
    case verifying
    case completed(URL)
    case failed(TransferError)
    case cancelled

    public var progress: Double {
        switch self {
        case .inProgress(let r, let t), .paused(let r, let t): t > 0 ? Double(r) / Double(t) : 0
        case .verifying, .completed: 1
        default: 0
        }
    }
}

/// Receives chunks into a temporary file in the destination folder, verifies SHA-256,
/// then atomically renames to a unique final name. Never overwrites existing files.
public final class FileReceiver {
    public let offer: FileOffer
    private let directory: URL
    private let tempURL: URL
    private var handle: FileHandle?
    private var hasher = SHA256()
    private var nextIndex = 0
    private var received: Int64 = 0
    private var finished = false

    public init(offer: FileOffer, destinationDirectory: URL, maxSize: Int64 = FileOffer.maxSize) throws(TransferError) {
        guard FileNameRules.isSafe(offer.name) else { throw .invalidOffer("unsafe file name") }
        guard offer.size > 0 else { throw .invalidOffer("empty file") }
        guard offer.size <= maxSize else { throw .tooLarge }
        guard (16 * 1024...64 * 1024).contains(offer.chunkSize) else { throw .invalidOffer("chunk size") }
        guard offer.sha256.count == 64, Hex.decode(offer.sha256) != nil else { throw .invalidOffer("hash") }
        self.offer = offer
        directory = destinationDirectory
        tempURL = destinationDirectory.appendingPathComponent(".mybuddy-\(offer.transferId.uuidString.lowercased()).part")
        guard FileManager.default.createFile(atPath: tempURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let h = try? FileHandle(forWritingTo: tempURL)
        else { throw .io("cannot create temporary file") }
        handle = h
    }

    deinit { if !finished { cleanup() } }

    public var nextExpectedIndex: Int { nextIndex }
    public var bytesReceived: Int64 { received }
    public var temporaryURL: URL { tempURL }

    /// Accepts the next in-order chunk. Duplicates of already-written chunks are ignored.
    @discardableResult
    public func write(index: Int, data: Data) throws(TransferError) -> Int64 {
        guard !finished, let handle else { throw .cancelled }
        if index < nextIndex { return received }  // duplicate (e.g. after resume)
        guard index == nextIndex, index < offer.chunkCount else { throw .invalidChunk("unexpected index \(index)") }
        guard data.count == offer.expectedLength(ofChunk: index) else { throw .invalidChunk("bad length") }
        do { try handle.write(contentsOf: data) } catch { throw .io("write failed") }
        hasher.update(data: data)
        nextIndex += 1
        received += Int64(data.count)
        return received
    }

    /// Verifies the checksum and moves the file into place. Returns the final URL.
    public func finish() throws(TransferError) -> URL {
        guard !finished else { throw .cancelled }
        guard nextIndex == offer.chunkCount, received == offer.size else { throw .incomplete }
        try? handle?.close()
        handle = nil
        let digest = Hex.encode(hasher.finalize())
        guard digest == offer.sha256 else {
            cleanup()
            throw .checksumMismatch
        }
        let final = try placeUnique()
        finished = true
        return final
    }

    public func cancel() { cleanup() }

    private func cleanup() {
        finished = true
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: tempURL)
    }

    private func placeUnique() throws(TransferError) -> URL {
        let base = (offer.name as NSString).deletingPathExtension
        let ext = (offer.name as NSString).pathExtension
        for n in 0..<1000 {
            let name = n == 0 ? offer.name : "\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")
            let dest = directory.appendingPathComponent(name)
            // renamex_np with RENAME_EXCL is atomic and never replaces an existing file.
            if renamex_np(tempURL.path, dest.path, UInt32(RENAME_EXCL)) == 0 { return dest }
            if errno != EEXIST { break }
        }
        cleanup()
        throw .io("could not place file")
    }
}

/// Reads a local file as protocol chunks.
public struct FileChunker {
    public let url: URL
    public let chunkSize: Int

    public init(url: URL, chunkSize: Int = FileOffer.defaultChunkSize) {
        self.url = url
        self.chunkSize = chunkSize
    }

    /// Streams the file once to compute size and SHA-256 for the offer.
    public func makeOffer(name: String? = nil, mimeType: String? = nil) throws -> FileOffer {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while let data = try h.read(upToCount: 1 << 20), !data.isEmpty {
            hasher.update(data: data)
            size += Int64(data.count)
        }
        return FileOffer(name: name ?? url.lastPathComponent, size: size, sha256: Hex.encode(hasher.finalize()), chunkSize: chunkSize, mimeType: mimeType)
    }

    public func chunk(_ index: Int) throws -> Data {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        try h.seek(toOffset: UInt64(index) * UInt64(chunkSize))
        return try h.read(upToCount: chunkSize) ?? Data()
    }
}
