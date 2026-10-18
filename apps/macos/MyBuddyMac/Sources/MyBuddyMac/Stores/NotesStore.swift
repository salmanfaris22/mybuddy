import AppKit
import Foundation
import MyBuddyCore
import MyBuddyHost
import Observation

/// Shared notes: kept on this Mac (Application Support/MyBuddy/notes.json) and in step with every connected phone
/// that has "Shared notes" (PROTOCOL.md §5.11). Nothing is uploaded anywhere and note text is never logged.
@MainActor
@Observable
final class NotesStore {
    @ObservationIgnored var app: AppModel!
    let demo: Bool
    private(set) var book: NoteBook
    var selectedId: String?
    /// A new note being written: it's stored (and synced) only once it has text, so empty notes never pile up.
    private(set) var draftId: String?
    /// When a note last went to or came from a phone.
    private(set) var lastSyncedAt: Date?
    @ObservationIgnored private var syncedSessions: Set<String> = []
    @ObservationIgnored private var pushTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    private nonisolated static let file = JSONFileStore<[Note]>(url: AppDirectories.support.appendingPathComponent("notes.json"))

    init(demo: Bool) {
        self.demo = demo
        var book = NoteBook(demo ? DemoData.notes : ((try? Self.file.load()) ?? []))
        book.purge(now: Note.nowMs())
        self.book = book
        selectedId = book.visible.first?.id
        if !demo {
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush() }
            }
        }
    }

    var visible: [Note] { book.visible }
    var selected: Note? {
        guard let id = selectedId else { return nil }
        if let n = book.notes[id], !n.deleted { return n }
        return id == draftId ? Note(id: id, text: "", updatedAt: Note.nowMs()) : nil
    }

    /// Phones that get notes right now.
    private var syncSessions: [ActiveSessionInfo] { app.connection.sessions.filter { $0.grantedCapabilities.contains(.notesSync) } }

    var syncStatus: String {
        let phones = syncSessions
        if let s = phones.first {
            let when = lastSyncedAt.map { " · synced \($0.formatted(.relative(presentation: .named)))" } ?? ""
            return "In step with \(s.deviceName)\(when)"
        }
        if app.connection.activeSession != nil { return "“Shared notes” is off for this phone (Settings → Devices)" }
        return "Saved on this Mac · syncs when your phone connects"
    }

    // MARK: Editing

    func newNote() {
        let id = Note.newId()
        draftId = id
        selectedId = id
    }

    func update(_ id: String, text: String) {
        let current = book.notes[id]
        if current?.deleted == true || current?.text == text { return }
        if current == nil {
            guard id == draftId, !text.isEmpty else { return }
            draftId = nil
        }
        book.edit(id, text: text, now: Note.nowMs())
        persist()
        schedulePush(id)
    }

    func delete(_ id: String) {
        if id == draftId {
            draftId = nil
            selectedId = visible.first?.id
            return
        }
        guard let tombstone = book.delete(id, now: Note.nowMs()) else { return }
        if selectedId == id { selectedId = visible.first?.id }
        pushTasks[id]?.cancel()
        persist()
        push(tombstone)
    }

    // MARK: Sync

    /// A phone with "Shared notes" connected: send it this Mac's index; it answers with what it has newer.
    func sessionsChanged(_ sessions: [ActiveSessionInfo]) {
        let live = Set(sessions.filter { $0.grantedCapabilities.contains(.notesSync) }.map(\.id))
        for id in live.subtracting(syncedSessions) {
            app.connection.push(OutgoingEvent(.notesIndex, NotesWire.index(book.index)), toSession: id)
        }
        syncedSessions = live
    }

    /// `notes.index` / `notes.put` from a phone (the server already checked "Shared notes").
    func handle(_ e: Envelope) -> [OutgoingEvent] {
        switch e.type {
        case .notesIndex:
            let sends = book.toSend(peerIndex: NotesWire.indexEntries(from: e.payload))
            if !sends.isEmpty { lastSyncedAt = Date() }
            return sends.map { OutgoingEvent(.notesPut, NotesWire.put($0)) }
        case .notesPut:
            guard let incoming = NotesWire.note(from: e.payload) else { return [] }
            if book.apply(incoming) {
                lastSyncedAt = Date()
                if selectedId == nil, !incoming.deleted { selectedId = incoming.id }
                if selectedId == incoming.id, incoming.deleted { selectedId = visible.first?.id }
                persist()
                push(incoming, except: e.sessionId)  // any other connected phone
                return []
            }
            // This Mac's copy wins: send it back so both devices end up with the same note.
            if let mine = book.notes[incoming.id], mine != incoming { return [OutgoingEvent(.notesPut, NotesWire.put(mine))] }
            return []
        default:
            return []
        }
    }

    private func schedulePush(_ id: String) {
        pushTasks[id]?.cancel()
        pushTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self, let note = self.book.notes[id] else { return }
            self.push(note)
        }
    }

    private func push(_ note: Note, except sessionId: String? = nil) {
        let targets = syncSessions.filter { $0.id != sessionId }
        for s in targets { app.connection.push(OutgoingEvent(.notesPut, NotesWire.put(note)), toSession: s.id) }
        if !targets.isEmpty { lastSyncedAt = Date() }
    }

    // MARK: Storage

    private func persist() {
        guard !demo else { return }
        saveTask?.cancel()
        let notes = book.all
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            try? Self.file.save(notes)
        }
    }

    /// Writes immediately (on quit).
    func flush() {
        guard !demo else { return }
        saveTask?.cancel()
        try? Self.file.save(book.all)
    }
}
