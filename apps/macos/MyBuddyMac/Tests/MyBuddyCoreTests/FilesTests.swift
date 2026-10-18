import CryptoKit
import Foundation
import Testing
@testable import MyBuddyCore

@Suite("Files: path guard and transfers")
struct FilesTests {
    let base: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("mybuddy-tests-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: base.appendingPathComponent("granted/sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: base.appendingPathComponent("secret"), withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: base.appendingPathComponent("granted/sub/note.txt"))
        try Data("top secret".utf8).write(to: base.appendingPathComponent("secret/keys.txt"))
        // Escaping symlinks inside the granted folder:
        try fm.createSymbolicLink(atPath: base.appendingPathComponent("granted/escape").path, withDestinationPath: base.appendingPathComponent("secret").path)
        try fm.createSymbolicLink(atPath: base.appendingPathComponent("granted/etc").path, withDestinationPath: "/etc")
        // A symlink that stays inside is fine:
        try fm.createSymbolicLink(atPath: base.appendingPathComponent("granted/inside").path, withDestinationPath: base.appendingPathComponent("granted/sub").path)
    }

    var root: String { base.appendingPathComponent("granted").path }

    @Test func resolvesPathsInsideRoot() throws {
        #expect(try PathGuard.resolve(rootPath: root, relativePath: "sub/note.txt").lastPathComponent == "note.txt")
        #expect(try PathGuard.resolve(rootPath: root, relativePath: "").path == PathGuard.realPath(root))
        #expect(try PathGuard.resolve(rootPath: root, relativePath: "inside/note.txt").lastPathComponent == "note.txt")
    }

    @Test(arguments: ["../secret/keys.txt", "sub/../../secret", "/etc/passwd", "~/Library", "sub//note.txt", "./sub", "a\u{0}b",
                      String(repeating: "a/", count: 600)])
    func rejectsLexicalAttacks(_ path: String) {
        #expect(throws: PathGuardError.self) { try PathGuard.resolve(rootPath: root, relativePath: path) }
    }

    @Test func rejectsSymlinkEscapes() {
        #expect(throws: PathGuardError.outsideRoot) { try PathGuard.resolve(rootPath: root, relativePath: "escape/keys.txt") }
        #expect(throws: PathGuardError.outsideRoot) { try PathGuard.resolve(rootPath: root, relativePath: "etc") }
        #expect(throws: PathGuardError.notFound) { try PathGuard.resolve(rootPath: root, relativePath: "sub/missing.txt") }
        #expect(throws: PathGuardError.rootUnavailable) { try PathGuard.resolve(rootPath: base.appendingPathComponent("nope").path, relativePath: "") }
    }

    @Test func containmentIsComponentWise() {
        #expect(PathGuard.isContained("/a/granted/x", in: "/a/granted"))
        #expect(!PathGuard.isContained("/a/granted-evil/x", in: "/a/granted"), "prefix match must respect separators")
    }

    // MARK: transfers

    private func makeOffer(_ data: Data, name: String = "photo.jpg", chunk: Int = 16 * 1024) -> FileOffer {
        FileOffer(name: name, size: Int64(data.count), sha256: Hex.encode(SHA256.hash(data: data)), chunkSize: chunk)
    }

    private func chunks(_ data: Data, _ size: Int) -> [Data] {
        stride(from: 0, to: data.count, by: size).map { data.subdata(in: $0..<min($0 + size, data.count)) }
    }

    @Test func receivesVerifiesAndPlacesAtomically() throws {
        let data = Data((0..<50_000).map { UInt8($0 % 251) })
        let dir = base.appendingPathComponent("granted")
        let offer = makeOffer(data)
        let r = try FileReceiver(offer: offer, destinationDirectory: dir)
        #expect(offer.chunkCount == 4)
        for (i, c) in chunks(data, offer.chunkSize).enumerated() { try r.write(index: i, data: c) }
        try r.write(index: 1, data: chunks(data, offer.chunkSize)[1])  // duplicate is ignored
        let url = try r.finish()
        #expect(try Data(contentsOf: url) == data)
        #expect(!FileManager.default.fileExists(atPath: r.temporaryURL.path))

        // A second identical transfer never overwrites: it gets a unique name.
        let r2 = try FileReceiver(offer: makeOffer(data), destinationDirectory: dir)
        for (i, c) in chunks(data, offer.chunkSize).enumerated() { try r2.write(index: i, data: c) }
        #expect(try r2.finish().lastPathComponent == "photo (1).jpg")
    }

    @Test func rejectsCorruptionGapsAndBadOffers() throws {
        let data = Data(repeating: 7, count: 40_000)
        let dir = base.appendingPathComponent("granted")
        let r = try FileReceiver(offer: makeOffer(data), destinationDirectory: dir)
        let parts = chunks(data, 16 * 1024)
        #expect(throws: TransferError.invalidChunk("unexpected index 1")) { try r.write(index: 1, data: parts[1]) }
        #expect(throws: TransferError.invalidChunk("bad length")) { try r.write(index: 0, data: Data(count: 10)) }
        var corrupted = parts[0]
        corrupted[0] ^= 0xff
        for (i, c) in [corrupted, parts[1], parts[2]].enumerated() { try r.write(index: i, data: c) }
        #expect(throws: TransferError.checksumMismatch) { try r.finish() }
        #expect(!FileManager.default.fileExists(atPath: r.temporaryURL.path), "temp file deleted on failure")

        #expect(throws: TransferError.tooLarge) { try FileReceiver(offer: makeOffer(data), destinationDirectory: dir, maxSize: 1000) }
        #expect(throws: TransferError.self) { try FileReceiver(offer: makeOffer(data, name: "../evil.sh"), destinationDirectory: dir) }

        let incomplete = try FileReceiver(offer: makeOffer(data), destinationDirectory: dir)
        try incomplete.write(index: 0, data: parts[0])
        #expect(throws: TransferError.incomplete) { try incomplete.finish() }
        incomplete.cancel()
        #expect(!FileManager.default.fileExists(atPath: incomplete.temporaryURL.path))
    }

    @Test func chunkerProducesMatchingOffer() throws {
        let data = Data((0..<70_000).map { UInt8($0 % 13) })
        let src = base.appendingPathComponent("granted/src.bin")
        try data.write(to: src)
        let chunker = FileChunker(url: src, chunkSize: 32 * 1024)
        let offer = try chunker.makeOffer()
        #expect(offer.size == 70_000 && offer.chunkCount == 3)
        #expect(offer.sha256 == Hex.encode(SHA256.hash(data: data)))
        let r = try FileReceiver(offer: FileOffer(name: "copy.bin", size: offer.size, sha256: offer.sha256, chunkSize: offer.chunkSize),
                                 destinationDirectory: base.appendingPathComponent("granted/sub"))
        for i in 0..<offer.chunkCount { try r.write(index: i, data: try chunker.chunk(i)) }
        #expect(try Data(contentsOf: try r.finish()) == data)
    }
}
