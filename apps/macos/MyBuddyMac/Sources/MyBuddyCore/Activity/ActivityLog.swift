import Foundation

public enum ActivityKind: String, Codable, CaseIterable, Sendable {
    case session, pairing, transfer, clipboard, notification, ai, voice, health, security

    public var title: String {
        switch self {
        case .session: "Sessions"
        case .pairing: "Pairing"
        case .transfer: "Transfers"
        case .clipboard: "Clipboard"
        case .notification: "Notifications"
        case .ai: "AI"
        case .voice: "Voice"
        case .health: "Health"
        case .security: "Security"
        }
    }
}

/// A privacy-safe record: what happened, never the content (no clipboard text, prompts, transcripts or file data).
public struct ActivityEvent: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let date: Date
    public let kind: ActivityKind
    public let title: String
    public let detail: String?

    public init(id: UUID = UUID(), date: Date = Date(), kind: ActivityKind, title: String, detail: String? = nil) {
        self.id = id
        self.date = date
        self.kind = kind
        self.title = Redactor.redact(String(title.prefix(160)))
        self.detail = detail.map { Redactor.redact(String($0.prefix(240))) }
    }
}

public protocol ActivityStorage: Sendable {
    func load() throws -> [ActivityEvent]
    func save(_ events: [ActivityEvent]) throws
}

/// Local, retention-bounded activity history with one-call deletion.
public final class ActivityLog: @unchecked Sendable, AIActivityRecorder {
    private let lock = NSLock()
    private let storage: (any ActivityStorage)?
    private let capacity: Int
    public var retention: TimeInterval
    private var events: [ActivityEvent] = []
    private var observers: [UUID: @Sendable ([ActivityEvent]) -> Void] = [:]

    public init(storage: (any ActivityStorage)? = nil, capacity: Int = 2_000, retention: TimeInterval = 30 * 24 * 3600) {
        self.storage = storage
        self.capacity = capacity
        self.retention = retention
        events = (try? storage?.load()) ?? []
    }

    public var all: [ActivityEvent] { lock.withLock { events } }

    public func record(_ event: ActivityEvent, now: Date = Date()) {
        let snapshot: [ActivityEvent] = lock.withLock {
            events.insert(event, at: 0)
            events.removeAll { now.timeIntervalSince($0.date) > retention }
            if events.count > capacity { events.removeLast(events.count - capacity) }
            return events
        }
        try? storage?.save(snapshot)
        notify(snapshot)
    }

    public func record(_ kind: ActivityKind, _ title: String, detail: String? = nil) {
        record(ActivityEvent(kind: kind, title: title, detail: detail))
    }

    public func deleteAll() {
        lock.withLock { events = [] }
        try? storage?.save([])
        notify([])
    }

    public func filtered(_ kinds: Set<ActivityKind>) -> [ActivityEvent] {
        kinds.isEmpty ? all : all.filter { kinds.contains($0.kind) }
    }

    @discardableResult
    public func observe(_ body: @escaping @Sendable ([ActivityEvent]) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { observers[id] = body }
        return id
    }

    private func notify(_ snapshot: [ActivityEvent]) {
        let current = lock.withLock { Array(observers.values) }
        for o in current { o(snapshot) }
    }

    // AIActivityRecorder — provider/model/outcome only.
    public func recordAI(provider: String, model: String, outcome: String) {
        record(.ai, "\(provider) · \(model)", detail: outcome)
    }
}
