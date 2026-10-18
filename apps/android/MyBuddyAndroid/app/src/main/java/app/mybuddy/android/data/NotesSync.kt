package app.mybuddy.android.data

import android.content.Context
import app.mybuddy.android.core.notes.Note
import app.mybuddy.android.core.notes.NoteBook
import app.mybuddy.android.core.notes.NotesWire
import app.mybuddy.android.core.protocol.Envelope
import app.mybuddy.android.core.protocol.EventType
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import java.io.File
import java.time.Instant

/**
 * Shared notes: kept in this app's private storage (notes.json) and in step with the Mac while "Shared notes" is
 * allowed (PROTOCOL.md §5.11). Nothing is uploaded anywhere and note text is never logged.
 */
class NotesSync(context: Context, private val scope: CoroutineScope, private val link: MacLink) {
    private val file = File(context.filesDir, "notes.json")
    private val lock = Any()
    private val book = MutableStateFlow(NoteBook())
    /** Notes to show, newest first. */
    val notes: StateFlow<List<Note>> = book.map { it.visible }.stateIn(scope, SharingStarted.Eagerly, emptyList())
    /** When a note last went to or came from the Mac. */
    val lastSyncedAt = MutableStateFlow<Instant?>(null)
    private val pushJobs = HashMap<String, Job>()
    private var saveJob: Job? = null

    init {
        scope.launch(Dispatchers.IO) { load() }
    }

    val allowed: Boolean get() = link.session.value?.granted?.contains("notes.sync") == true

    fun note(id: String): Note? = book.value.notes[id]?.takeIf { !it.deleted }

    fun isDeleted(id: String): Boolean = book.value.notes[id]?.deleted == true

    /** A new note's id. It's stored (and synced) only once it has text, so empty notes never pile up. */
    fun newId(): String = Note.newId()

    fun update(id: String, text: String) {
        synchronized(lock) {
            val current = book.value.notes[id]
            if (current?.deleted == true || current?.text == text) return
            if (current == null && text.isEmpty()) return
            book.value = book.value.edit(id, text, now()).first
        }
        persist()
        schedulePush(id)
    }

    fun delete(id: String) {
        val tombstone = synchronized(lock) {
            val (next, tombstone) = book.value.delete(id, now()) ?: return
            book.value = next
            tombstone
        }
        pushJobs.remove(id)?.cancel()
        persist()
        push(tombstone)
    }

    /** Connected with "Shared notes": send this phone's index; the Mac answers with the notes it has newer. */
    fun sessionStarted() {
        if (allowed) link.send(EventType.NOTES_INDEX, NotesWire.index(book.value.index))
    }

    /** `notes.index` / `notes.put` from the Mac. */
    fun handle(e: Envelope) {
        when (e.type) {
            EventType.NOTES_INDEX -> {
                val sends = book.value.toSend(NotesWire.indexEntries(e.payload))
                sends.forEach { link.send(EventType.NOTES_PUT, NotesWire.put(it)) }
                if (sends.isNotEmpty()) lastSyncedAt.value = Instant.now()
            }
            EventType.NOTES_PUT -> {
                val incoming = NotesWire.note(e.payload) ?: return
                val replaced = synchronized(lock) {
                    book.value.apply(incoming)?.also { book.value = it } != null
                }
                if (replaced) {
                    lastSyncedAt.value = Instant.now()
                    persist()
                } else {
                    // This phone's copy wins: send it back so both devices end up with the same note.
                    book.value.notes[incoming.id]?.takeIf { it != incoming }?.let { link.send(EventType.NOTES_PUT, NotesWire.put(it)) }
                }
            }
            else -> {}
        }
    }

    private fun schedulePush(id: String) {
        pushJobs.remove(id)?.cancel()
        pushJobs[id] = scope.launch {
            delay(600)
            book.value.notes[id]?.let(::push)
        }
    }

    private fun push(n: Note) {
        if (!allowed || !link.state.value.isConnected) return
        if (link.send(EventType.NOTES_PUT, NotesWire.put(n)) != null) lastSyncedAt.value = Instant.now()
    }

    private fun persist() {
        saveJob?.cancel()
        saveJob = scope.launch(Dispatchers.IO) {
            delay(300)
            val json = buildJsonArray { book.value.all.forEach { add(NotesWire.put(it)) } }.toString()
            val tmp = File(file.parentFile, "notes.json.tmp")
            runCatching {
                tmp.writeText(json)
                if (!tmp.renameTo(file)) {
                    file.delete()
                    tmp.renameTo(file)
                }
            }
        }
    }

    private fun load() {
        val stored = runCatching {
            Json.parseToJsonElement(file.readText()).jsonArray.mapNotNull { NotesWire.note(it.jsonObject) }
        }.getOrNull() ?: return
        synchronized(lock) { book.value = NoteBook(stored + book.value.all).purged(now()) }
        // A session may have started while the file was loading: offer what this phone has.
        if (link.state.value.isConnected) sessionStarted()
    }

    private fun now() = System.currentTimeMillis()
}
