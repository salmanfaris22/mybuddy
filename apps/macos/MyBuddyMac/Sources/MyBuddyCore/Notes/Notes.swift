import Foundation

/// One shared note (PROTOCOL.md §5.11). Notes live on this Mac and the paired phone only — never on a server.
public struct Note: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var text: String
    /// Epoch milliseconds of the last change (on the wire: ISO-8601 UTC with milliseconds).
    public var updatedAt: Int64
    /// A deletion is kept as a tombstone (empty text) so it reaches the other device, then forgotten after 30 days.
    public var deleted: Bool

    public init(id: String, text: String, updatedAt: Int64, deleted: Bool = false) {
        self.id = id
        self.text = text
        self.updatedAt = updatedAt
        self.deleted = deleted
    }

    /// The first non-empty line, as lists show it.
    public var title: String {
        lines.first.map { String($0.prefix(80)) } ?? "New note"
    }

    /// The next non-empty line after the title.
    public var preview: String {
        lines.dropFirst().first.map { String($0.prefix(120)) } ?? ""
    }

    private var lines: [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public static func newId() -> String { UUID().uuidString.lowercased() }
    public static func nowMs(_ date: Date = Date()) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded(.down)) }
}

/// What `notes.index` lists for one note.
public struct NoteIndexEntry: Sendable, Equatable {
    public let id: String
    public let updatedAt: Int64
    public let deleted: Bool

    public init(id: String, updatedAt: Int64, deleted: Bool) {
        self.id = id
        self.updatedAt = updatedAt
        self.deleted = deleted
    }
}

/// Last-writer-wins, decided the same way on both devices (vectors: protocol/vectors/notes-merge-v1.json).
public enum NotesMerge {
    /// True when `incoming` should replace `local`: newer wins; at the same instant a deletion wins, then the
    /// larger text by UTF-8 bytes (an arbitrary but shared rule, so both sides keep the same copy).
    public static func incomingWins(local: Note?, incoming: Note) -> Bool {
        guard let local else { return true }
        if incoming.updatedAt != local.updatedAt { return incoming.updatedAt > local.updatedAt }
        if incoming.deleted != local.deleted { return incoming.deleted }
        return Array(local.text.utf8).lexicographicallyPrecedes(Array(incoming.text.utf8))
    }
}

/// All notes on this device plus the sync rules. Pure value type: the stores persist it and move it over the wire.
public struct NoteBook: Sendable, Equatable {
    public private(set) var notes: [String: Note]
    public static let tombstoneLifetimeMs: Int64 = 30 * 86_400_000
    public static let indexLimit = 500

    public init(_ list: [Note] = []) {
        var notes: [String: Note] = [:]
        for n in list where NotesMerge.incomingWins(local: notes[n.id], incoming: n) { notes[n.id] = n }
        self.notes = notes
    }

    /// Notes to show, newest first.
    public var visible: [Note] {
        notes.values.filter { !$0.deleted }.sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id < $1.id }
    }

    public var all: [Note] { notes.values.sorted { $0.updatedAt < $1.updatedAt } }

    /// A local edit (creates the note when needed). A note's time never goes backwards, so an edit always wins over
    /// the version it replaced — even one that came from a device whose clock runs ahead.
    @discardableResult
    public mutating func edit(_ id: String, text: String, now: Int64) -> Note {
        let note = Note(id: id, text: text, updatedAt: max(now, (notes[id]?.updatedAt ?? 0) + 1))
        notes[id] = note
        return note
    }

    @discardableResult
    public mutating func delete(_ id: String, now: Int64) -> Note? {
        guard let existing = notes[id], !existing.deleted else { return nil }
        let tombstone = Note(id: id, text: "", updatedAt: max(now, existing.updatedAt + 1), deleted: true)
        notes[id] = tombstone
        return tombstone
    }

    /// A note from the other device. Returns true when it replaced the local copy.
    @discardableResult
    public mutating func apply(_ incoming: Note) -> Bool {
        guard NotesMerge.incomingWins(local: notes[incoming.id], incoming: incoming) else { return false }
        notes[incoming.id] = incoming
        return true
    }

    /// What `notes.index` carries: the newest entries, tombstones included.
    public var index: [NoteIndexEntry] {
        notes.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(Self.indexLimit)
            .map { NoteIndexEntry(id: $0.id, updatedAt: $0.updatedAt, deleted: $0.deleted) }
    }

    /// The notes the other device should get after reading its index: live notes it lacks, and anything newer here
    /// (at the same instant, a deletion still goes out). Oldest first.
    public func toSend(peerIndex: [NoteIndexEntry]) -> [Note] {
        let peer = Dictionary(peerIndex.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return notes.values.filter { n in
            guard let p = peer[n.id] else { return !n.deleted }
            if n.updatedAt != p.updatedAt { return n.updatedAt > p.updatedAt }
            return n.deleted && !p.deleted
        }.sorted { $0.updatedAt < $1.updatedAt }
    }

    /// Forgets tombstones older than 30 days (by then the other device has had them).
    public mutating func purge(now: Int64) {
        notes = notes.filter { !$0.value.deleted || now - $0.value.updatedAt < Self.tombstoneLifetimeMs }
    }
}

/// `notes.index` / `notes.put` payloads.
public enum NotesWire {
    nonisolated(unsafe) private static let withMillis: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let lock = NSLock()

    public static func timestamp(_ ms: Int64) -> String {
        lock.withLock { withMillis.string(from: Date(timeIntervalSince1970: Double(ms) / 1000)) }
    }

    public static func millis(_ s: String) -> Int64? {
        let date = lock.withLock { withMillis.date(from: s) ?? plain.date(from: s) }
        return date.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
    }

    public static func put(_ n: Note) -> [String: JSONValue] {
        ["id": .string(n.id), "text": .string(n.text), "updatedAt": .string(timestamp(n.updatedAt)), "deleted": .bool(n.deleted)]
    }

    /// Payloads were already validated against the catalog by the envelope codec.
    public static func note(from p: [String: JSONValue]) -> Note? {
        guard let id = p["id"]?.stringValue?.lowercased(), let text = p["text"]?.stringValue,
              let at = p["updatedAt"]?.stringValue.flatMap(millis), let deleted = p["deleted"]?.boolValue else { return nil }
        return Note(id: id, text: deleted ? "" : text, updatedAt: at, deleted: deleted)
    }

    public static func index(_ entries: [NoteIndexEntry]) -> [String: JSONValue] {
        ["notes": .array(entries.prefix(NoteBook.indexLimit).map {
            .object(["id": .string($0.id), "updatedAt": .string(timestamp($0.updatedAt)), "deleted": .bool($0.deleted)])
        })]
    }

    public static func indexEntries(from p: [String: JSONValue]) -> [NoteIndexEntry] {
        (p["notes"]?.arrayValue ?? []).compactMap { v in
            guard let id = v["id"]?.stringValue?.lowercased(), let at = v["updatedAt"]?.stringValue.flatMap(millis),
                  let deleted = v["deleted"]?.boolValue else { return nil }
            return NoteIndexEntry(id: id, updatedAt: at, deleted: deleted)
        }
    }
}
