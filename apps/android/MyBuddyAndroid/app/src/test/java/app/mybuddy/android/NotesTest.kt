package app.mybuddy.android

import app.mybuddy.android.core.notes.Note
import app.mybuddy.android.core.notes.NoteBook
import app.mybuddy.android.core.notes.NoteIndexEntry
import app.mybuddy.android.core.notes.NotesMerge
import app.mybuddy.android.core.notes.NotesWire
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NotesTest {
    private val vectors = Json.parseToJsonElement(Repo.text("protocol/vectors/notes-merge-v1.json")).jsonObject

    private fun note(o: JsonObject, id: String = "6f1c2b9e-1d2a-4c7e-9a51-3b8f0d2e4a10") =
        Note(id, o["text"]?.jsonPrimitive?.content ?: "", o.getValue("updatedAt").jsonPrimitive.long, o.getValue("deleted").jsonPrimitive.boolean)

    @Test
    fun mergeFollowsTheSharedVectors() {
        for (c in vectors.getValue("merge").jsonArray.map { it.jsonObject }) {
            val local = c.getValue("local").let { if (it is JsonNull) null else note(it.jsonObject) }
            val incoming = note(c.getValue("incoming").jsonObject)
            assertEquals(c.getValue("name").jsonPrimitive.content, c.getValue("incomingWins").jsonPrimitive.boolean, NotesMerge.incomingWins(local, incoming))
        }
    }

    @Test
    fun whatToSendFollowsTheSharedVectors() {
        for (c in vectors.getValue("toSend").jsonArray.map { it.jsonObject }) {
            val book = NoteBook(c.getValue("local").jsonArray.map { val o = it.jsonObject; note(o, o.getValue("id").jsonPrimitive.content) })
            val peer = c.getValue("peer").jsonArray.map {
                val o = it.jsonObject
                NoteIndexEntry(o.getValue("id").jsonPrimitive.content, o.getValue("updatedAt").jsonPrimitive.long, o.getValue("deleted").jsonPrimitive.boolean)
            }
            assertEquals(c.getValue("name").jsonPrimitive.content, c.getValue("send").jsonArray.map { it.jsonPrimitive.content }.toSet(),
                book.toSend(peer).map { it.id }.toSet())
        }
    }

    @Test
    fun editsNeverGoBackInTimeAndTombstonesExpire() {
        val id = Note.newId()
        var book = NoteBook().edit(id, "From the Mac", 1_000).first
        val applied = book.apply(Note(id, "Mac clock runs ahead", 5_000))
        assertNotNull(applied)
        book = applied!!
        // This phone's clock is behind, yet the edit must win over what it replaced.
        val (edited, note) = book.edit(id, "Edited on the phone", 2_000)
        assertEquals(5_001L, note.updatedAt)
        assertEquals("Edited on the phone", edited.visible.first().title)
        val (deleted, tombstone) = edited.delete(id, 6_000)!!
        assertTrue(tombstone.deleted && tombstone.text.isEmpty())
        assertTrue(deleted.visible.isEmpty())
        assertEquals(1, deleted.index.size)
        assertEquals(1, deleted.purged(6_000 + NoteBook.TOMBSTONE_LIFETIME_MS - 1).index.size)
        assertEquals(0, deleted.purged(6_000 + NoteBook.TOMBSTONE_LIFETIME_MS).index.size)
        assertNull("deleting twice does nothing", deleted.delete(id, 7_000))
    }

    @Test
    fun twoDevicesConvergeThroughIndexAndPut() {
        val a = Note.newId()
        val b = Note.newId()
        var mac = NoteBook().edit(a, "Mac note", 100).first
        var phone = NoteBook().edit(a, "Older phone copy", 50).first.edit(b, "Phone note", 200).first
        val macIndex = mac.index
        val phoneIndex = phone.index
        for (n in mac.toSend(phoneIndex)) phone = phone.apply(n) ?: phone
        for (n in phone.toSend(macIndex)) mac = mac.apply(n) ?: mac
        assertEquals(mac, phone)
        assertEquals("Mac note", mac.notes.getValue(a).text)
        assertEquals("Phone note", mac.notes.getValue(b).text)
    }

    @Test
    fun titlesAndWireFormat() {
        val n = Note("6f1c2b9e-1d2a-4c7e-9a51-3b8f0d2e4a10", "\n  Shopping list \n\nmilk", 1_792_310_400_123)
        assertEquals("Shopping list", n.title)
        assertEquals("milk", n.preview)
        assertEquals("New note", Note("x", " \n", 0).title)
        assertEquals(n, NotesWire.note(NotesWire.put(n)))
        assertTrue(NotesWire.timestamp(n.updatedAt).endsWith(".123Z"))
        assertEquals(NotesWire.millis("2026-10-16T08:30:00Z"), NotesWire.millis("2026-10-16T08:30:00.000Z"))
        val entry = NoteIndexEntry(n.id, n.updatedAt, false)
        assertEquals(listOf(entry), NotesWire.indexEntries(NotesWire.index(listOf(entry))))
        // A tombstone never carries text, whatever arrives; the fixture parses.
        val tomb = JsonObject(NotesWire.put(n) + ("deleted" to JsonPrimitive(true)))
        assertEquals("", NotesWire.note(tomb)?.text)
        val fixture = Json.parseToJsonElement(Repo.text("protocol/fixtures/valid/notes.put.json")).jsonObject.getValue("payload").jsonObject
        assertEquals("Groceries", NotesWire.note(fixture)?.title)
    }
}
