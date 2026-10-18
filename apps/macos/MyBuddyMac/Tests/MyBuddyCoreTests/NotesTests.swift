import Foundation
import Testing
@testable import MyBuddyCore

@Suite("Shared notes")
struct NotesTests {
    private static var vectors: [String: Any] { try! Repo.json("protocol/vectors/notes-merge-v1.json") }

    private func note(_ o: [String: Any], id: String = "6f1c2b9e-1d2a-4c7e-9a51-3b8f0d2e4a10") -> Note {
        Note(id: id, text: o["text"] as? String ?? "", updatedAt: (o["updatedAt"] as! NSNumber).int64Value, deleted: o["deleted"] as! Bool)
    }

    @Test func mergeFollowsTheSharedVectors() {
        for c in Self.vectors["merge"] as! [[String: Any]] {
            let local = (c["local"] as? [String: Any]).map { note($0) }
            let incoming = note(c["incoming"] as! [String: Any])
            #expect(NotesMerge.incomingWins(local: local, incoming: incoming) == (c["incomingWins"] as! Bool), "\(c["name"]!)")
        }
    }

    @Test func whatToSendFollowsTheSharedVectors() {
        for c in Self.vectors["toSend"] as! [[String: Any]] {
            let book = NoteBook((c["local"] as! [[String: Any]]).map { note($0, id: $0["id"] as! String) })
            let peer = (c["peer"] as! [[String: Any]]).map {
                NoteIndexEntry(id: $0["id"] as! String, updatedAt: ($0["updatedAt"] as! NSNumber).int64Value, deleted: $0["deleted"] as! Bool)
            }
            #expect(Set(book.toSend(peerIndex: peer).map(\.id)) == Set(c["send"] as! [String]), "\(c["name"]!)")
        }
    }

    @Test func editsNeverGoBackInTimeAndTombstonesExpire() {
        var book = NoteBook()
        let id = Note.newId()
        book.edit(id, text: "From the phone", now: 1_000)
        let applied = book.apply(Note(id: id, text: "Phone clock runs ahead", updatedAt: 5_000))
        #expect(applied)
        // This Mac's clock is behind, yet the edit must win over what it replaced.
        let edited = book.edit(id, text: "Edited on the Mac", now: 2_000)
        #expect(edited.updatedAt == 5_001)
        #expect(book.visible.first?.title == "Edited on the Mac")
        let tombstone = book.delete(id, now: 6_000)
        #expect(tombstone?.deleted == true && tombstone?.text == "")
        #expect(book.visible.isEmpty && book.index.count == 1)
        book.purge(now: 6_000 + NoteBook.tombstoneLifetimeMs - 1)
        #expect(book.index.count == 1)
        book.purge(now: 6_000 + NoteBook.tombstoneLifetimeMs)
        #expect(book.index.isEmpty)
    }

    @Test func twoDevicesConvergeThroughIndexAndPut() {
        var mac = NoteBook()
        var phone = NoteBook()
        let a = Note.newId(), b = Note.newId()
        mac.edit(a, text: "Mac note", now: 100)
        phone.edit(a, text: "Older phone copy", now: 50)
        phone.edit(b, text: "Phone note", now: 200)
        let macIndex = mac.index, phoneIndex = phone.index
        for n in mac.toSend(peerIndex: phoneIndex) { phone.apply(n) }
        for n in phone.toSend(peerIndex: macIndex) { mac.apply(n) }
        #expect(mac == phone)
        #expect(mac.notes[a]?.text == "Mac note" && mac.notes[b]?.text == "Phone note")
    }

    @Test func titlesAndWireFormat() {
        let n = Note(id: "6f1c2b9e-1d2a-4c7e-9a51-3b8f0d2e4a10", text: "\n  Shopping list \n\nmilk", updatedAt: 1_792_310_400_123)
        #expect(n.title == "Shopping list" && n.preview == "milk")
        #expect(Note(id: "x", text: " \n", updatedAt: 0).title == "New note")
        #expect(NotesWire.note(from: NotesWire.put(n)) == n)
        #expect(NotesWire.timestamp(n.updatedAt).hasSuffix(".123Z"))
        #expect(NotesWire.millis("2026-10-16T08:30:00Z") == NotesWire.millis("2026-10-16T08:30:00.000Z"))
        let entry = NoteIndexEntry(id: n.id, updatedAt: n.updatedAt, deleted: false)
        #expect(NotesWire.indexEntries(from: NotesWire.index([entry])) == [entry])
        // A tombstone never carries text, whatever arrives.
        var payload = NotesWire.put(n)
        payload["deleted"] = .bool(true)
        #expect(NotesWire.note(from: payload)?.text == "")
    }

    @Test func notesEventsAreGatedBySharedNotes() {
        #expect(EventType.notesPut.requiredCapability == .notesSync)
        #expect(EventType.notesIndex.requiredCapability == .notesSync)
        #expect(Capability.defaultGrants.contains(.notesSync))
    }
}
