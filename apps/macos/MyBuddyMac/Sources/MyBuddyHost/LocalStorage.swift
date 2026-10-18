import Foundation
import MyBuddyCore

/// Application Support/MyBuddy — local-only, owner-readable files.
public enum AppDirectories {
    public static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("MyBuddy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }
}

/// Atomic JSON file persistence with 0600 permissions.
public struct JSONFileStore<Value: Codable>: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Value.self, from: Data(contentsOf: url))
    }

    public func save(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Activity history on disk (metadata only; see `ActivityEvent`).
public final class FileActivityStorage: ActivityStorage, @unchecked Sendable {
    private let file: JSONFileStore<[ActivityEvent]>
    public init(url: URL = AppDirectories.support.appendingPathComponent("activity.json")) { file = JSONFileStore(url: url) }
    public func load() throws -> [ActivityEvent] { try file.load() ?? [] }
    public func save(_ events: [ActivityEvent]) throws { try file.save(events) }
}
