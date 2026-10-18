package app.mybuddy.android.core.notes

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.UUID

/** One shared note (PROTOCOL.md §5.11). Notes live on this phone and the paired Mac only — never on a server. */
data class Note(
    val id: String,
    val text: String,
    /** Epoch milliseconds of the last change (on the wire: ISO-8601 UTC with milliseconds). */
    val updatedAt: Long,
    /** A deletion is kept as a tombstone (empty text) so it reaches the Mac, then forgotten after 30 days. */
    val deleted: Boolean = false,
) {
    private val lines: List<String> get() = text.lines().map { it.trim() }.filter { it.isNotEmpty() }

    /** The first non-empty line, as lists show it. */
    val title: String get() = lines.firstOrNull()?.take(80) ?: "New note"

    /** The next non-empty line after the title. */
    val preview: String get() = lines.drop(1).firstOrNull()?.take(120) ?: ""

    companion object {
        fun newId(): String = UUID.randomUUID().toString()
    }
}

/** What `notes.index` lists for one note. */
data class NoteIndexEntry(val id: String, val updatedAt: Long, val deleted: Boolean)

/** Last-writer-wins, decided the same way on both devices (vectors: protocol/vectors/notes-merge-v1.json). */
object NotesMerge {
    /**
     * True when [incoming] should replace [local]: newer wins; at the same instant a deletion wins, then the larger
     * text by UTF-8 bytes (an arbitrary but shared rule, so both sides keep the same copy).
     */
    fun incomingWins(local: Note?, incoming: Note): Boolean {
        if (local == null) return true
        if (incoming.updatedAt != local.updatedAt) return incoming.updatedAt > local.updatedAt
        if (incoming.deleted != local.deleted) return incoming.deleted
        return compareUtf8(incoming.text, local.text) > 0
    }

    private fun compareUtf8(a: String, b: String): Int {
        val x = a.encodeToByteArray()
        val y = b.encodeToByteArray()
        for (i in 0 until minOf(x.size, y.size)) {
            val d = (x[i].toInt() and 0xff) - (y[i].toInt() and 0xff)
            if (d != 0) return d
        }
        return x.size - y.size
    }
}

/** All notes on this phone plus the sync rules. Immutable: every change returns a new book. */
class NoteBook(list: List<Note> = emptyList()) {
    val notes: Map<String, Note> = buildMap {
        for (n in list) if (NotesMerge.incomingWins(get(n.id), n)) put(n.id, n)
    }

    /** Notes to show, newest first. */
    val visible: List<Note> get() = notes.values.filter { !it.deleted }.sortedWith(compareByDescending<Note> { it.updatedAt }.thenBy { it.id })

    val all: List<Note> get() = notes.values.sortedBy { it.updatedAt }

    /**
     * A local edit (creates the note when needed). A note's time never goes backwards, so an edit always wins over
     * the version it replaced — even one that came from a device whose clock runs ahead.
     */
    fun edit(id: String, text: String, now: Long): Pair<NoteBook, Note> {
        val note = Note(id, text, maxOf(now, (notes[id]?.updatedAt ?: 0L) + 1))
        return replacing(note) to note
    }

    fun delete(id: String, now: Long): Pair<NoteBook, Note>? {
        val existing = notes[id]?.takeIf { !it.deleted } ?: return null
        val tombstone = Note(id, "", maxOf(now, existing.updatedAt + 1), deleted = true)
        return replacing(tombstone) to tombstone
    }

    /** A note from the Mac: the new book, or null when the local copy stays. */
    fun apply(incoming: Note): NoteBook? = if (NotesMerge.incomingWins(notes[incoming.id], incoming)) replacing(incoming) else null

    /** What `notes.index` carries: the newest entries, tombstones included. */
    val index: List<NoteIndexEntry>
        get() = notes.values.sortedByDescending { it.updatedAt }.take(INDEX_LIMIT).map { NoteIndexEntry(it.id, it.updatedAt, it.deleted) }

    /**
     * The notes the Mac should get after reading its index: live notes it lacks, and anything newer here (at the
     * same instant, a deletion still goes out). Oldest first.
     */
    fun toSend(peerIndex: List<NoteIndexEntry>): List<Note> {
        val peer = peerIndex.associateBy { it.id }
        return notes.values.filter { n ->
            val p = peer[n.id] ?: return@filter !n.deleted
            if (n.updatedAt != p.updatedAt) n.updatedAt > p.updatedAt else n.deleted && !p.deleted
        }.sortedBy { it.updatedAt }
    }

    /** Forgets tombstones older than 30 days (by then the Mac has had them). */
    fun purged(now: Long): NoteBook = NoteBook(notes.values.filter { !it.deleted || now - it.updatedAt < TOMBSTONE_LIFETIME_MS })

    private fun replacing(n: Note) = NoteBook(notes.values.filter { it.id != n.id } + n)

    override fun equals(other: Any?) = other is NoteBook && other.notes == notes
    override fun hashCode() = notes.hashCode()

    companion object {
        const val TOMBSTONE_LIFETIME_MS = 30L * 86_400_000
        const val INDEX_LIMIT = 500
    }
}

/** `notes.index` / `notes.put` payloads. */
object NotesWire {
    private val format = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC)

    fun timestamp(ms: Long): String = format.format(Instant.ofEpochMilli(ms))

    fun millis(s: String): Long? = runCatching { Instant.parse(s).toEpochMilli() }.getOrNull()

    fun put(n: Note): JsonObject = buildJsonObject {
        put("id", n.id)
        put("text", n.text)
        put("updatedAt", timestamp(n.updatedAt))
        put("deleted", n.deleted)
    }

    /** Payloads were already validated against the catalog by the envelope codec. */
    fun note(p: JsonObject): Note? {
        val id = p["id"]?.jsonPrimitive?.content?.lowercase() ?: return null
        val text = p["text"]?.jsonPrimitive?.content ?: return null
        val at = p["updatedAt"]?.jsonPrimitive?.content?.let(::millis) ?: return null
        val deleted = p["deleted"]?.jsonPrimitive?.booleanOrNull ?: return null
        return Note(id, if (deleted) "" else text, at, deleted)
    }

    fun index(entries: List<NoteIndexEntry>): JsonObject = buildJsonObject {
        put("notes", buildJsonArray {
            entries.take(NoteBook.INDEX_LIMIT).forEach { e ->
                add(buildJsonObject { put("id", e.id); put("updatedAt", timestamp(e.updatedAt)); put("deleted", e.deleted) })
            }
        })
    }

    fun indexEntries(p: JsonObject): List<NoteIndexEntry> = (p["notes"] as? JsonArray).orEmpty().mapNotNull { v ->
        val o = v.jsonObject
        val id = o["id"]?.jsonPrimitive?.content?.lowercase() ?: return@mapNotNull null
        val at = o["updatedAt"]?.jsonPrimitive?.content?.let(::millis) ?: return@mapNotNull null
        val deleted = o["deleted"]?.jsonPrimitive?.booleanOrNull ?: return@mapNotNull null
        NoteIndexEntry(id, at, deleted)
    }
}
