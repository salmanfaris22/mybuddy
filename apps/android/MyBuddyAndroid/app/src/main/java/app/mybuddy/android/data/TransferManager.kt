package app.mybuddy.android.data

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import android.provider.OpenableColumns
import app.mybuddy.android.core.Base64Url
import app.mybuddy.android.core.Hex
import app.mybuddy.android.core.files.ChunkAssembler
import app.mybuddy.android.core.files.FileOffer
import app.mybuddy.android.core.files.SendWindow
import app.mybuddy.android.core.files.TransferException
import app.mybuddy.android.core.protocol.Envelope
import app.mybuddy.android.core.protocol.EventType
import app.mybuddy.android.core.protocol.FileNameRules
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.FileInputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.security.MessageDigest
import java.util.UUID

/** One transfer as the UI shows it. */
data class TransferUi(
    val id: String,
    val name: String,
    val size: Long,
    val toMac: Boolean,
    val state: State,
    val transferred: Long = 0,
    val message: String? = null,
    val uri: Uri? = null,
    val updatedAt: Long = System.currentTimeMillis(),
) {
    enum class State { Preparing, Offered, WaitingForMac, InProgress, Paused, Verifying, Done, Failed, Cancelled }

    val active: Boolean get() = state in setOf(State.Preparing, State.Offered, State.WaitingForMac, State.InProgress, State.Paused, State.Verifying)
    val fraction: Float get() = if (size <= 0) 0f else (transferred.toFloat() / size).coerceIn(0f, 1f)
}

/**
 * File transfers with the Mac in both directions (PROTOCOL §5.5), inside the end-to-end encrypted MBH1 session
 * over a direct path — never through a server. Sending reads the file the user picked with the system picker; receiving writes into
 * Downloads/MyBuddy as a *pending* MediaStore entry (invisible to other apps) that is published only after
 * the SHA-256 matches and deleted on any failure. All state lives on one serial job queue.
 */
class TransferManager(private val context: Context, private val scope: CoroutineScope, private val link: MacLink) {
    private val jobs = Channel<suspend () -> Unit>(Channel.UNLIMITED)
    private val _items = MutableStateFlow<List<TransferUi>>(emptyList())
    val items: StateFlow<List<TransferUi>> = _items

    private inner class Outgoing(val offer: FileOffer, val pfd: ParcelFileDescriptor, val channel: FileChannel) {
        /** The offer reached the Mac in the current session (until then a session change doesn't affect it). */
        var offered = false
        var window: SendWindow? = null
        var paused = false
        var lastActivity = System.currentTimeMillis()
    }

    private inner class Incoming(val offer: FileOffer) {
        var uri: Uri? = null
        var out: OutputStream? = null
        var assembler: ChunkAssembler? = null
        var lastActivity = System.currentTimeMillis()
    }

    /** Why transfers are off right now (relayed internet sessions), or null. */
    var blockedReason: () -> String? = { null }
    /** "Save files from your Mac automatically": unsolicited offers start without the Save / Decline card. */
    var autoSave: () -> Boolean = { false }

    private val outgoing = HashMap<String, Outgoing>()
    private val incoming = HashMap<String, Incoming>()
    private val requested = HashMap<String, Long>() // requestId → time asked

    init {
        scope.launch(Dispatchers.IO) {
            for (job in jobs) runCatching { job() }
        }
        scope.launch(Dispatchers.IO) {
            while (isActive) {
                delay(5_000)
                enqueue { expireStalled() }
            }
        }
    }

    private fun enqueue(job: suspend () -> Unit) {
        jobs.trySend(job)
    }

    private fun update(id: String, change: (TransferUi) -> TransferUi) {
        _items.value = _items.value.map { if (it.id == id) change(it).copy(updatedAt = System.currentTimeMillis()) else it }
    }

    private fun add(item: TransferUi) {
        _items.value = (listOf(item) + _items.value.filterNot { it.id == item.id }).take(50)
    }

    private fun activeCount() = outgoing.size + incoming.size

    // region Sending to the Mac

    fun sendFile(uri: Uri) = enqueue {
        val resolver = context.contentResolver
        var name = "file"
        var declaredSize = -1L
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                name = c.getString(0)?.takeIf { it.isNotBlank() } ?: name
                if (!c.isNull(1)) declaredSize = c.getLong(1)
            }
        }
        if (!FileNameRules.isSafe(name)) name = name.replace(Regex("""[/\\:\u0000-\u001f]"""), "_").trim().trimEnd('.').ifEmpty { "file" }.take(200)
        val id = UUID.randomUUID().toString()
        add(TransferUi(id, name, maxOf(declaredSize, 0), toMac = true, state = TransferUi.State.Preparing))
        blockedReason()?.let { why -> return@enqueue update(id) { it.copy(state = TransferUi.State.Failed, message = why) } }
        if (activeCount() >= MAX_CONCURRENT) return@enqueue update(id) { it.copy(state = TransferUi.State.Failed, message = "Two transfers are already running.") }
        // One pass to measure and hash (the offer carries both).
        val digest = MessageDigest.getInstance("SHA-256")
        var size = 0L
        try {
            resolver.openInputStream(uri)?.use { input ->
                val buffer = ByteArray(1 shl 16)
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    digest.update(buffer, 0, n)
                    size += n
                }
            } ?: throw TransferException("denied", "can’t read the file")
        } catch (e: Exception) {
            return@enqueue update(id) { it.copy(state = TransferUi.State.Failed, message = "Couldn’t read the file.") }
        }
        if (size <= 0 || size > FileOffer.MAX_SIZE) {
            return@enqueue update(id) { it.copy(state = TransferUi.State.Failed, message = if (size <= 0) "The file is empty." else "Files up to 2 GB can be sent.") }
        }
        val pfd = try {
            resolver.openFileDescriptor(uri, "r") ?: throw TransferException("denied", "no descriptor")
        } catch (e: Exception) {
            return@enqueue update(id) { it.copy(state = TransferUi.State.Failed, message = "This file can’t be read for sending.") }
        }
        val offer = FileOffer(id, name, size, Hex.encode(digest.digest()), mimeType = resolver.getType(uri))
        outgoing[id] = Outgoing(offer, pfd, FileInputStream(pfd.fileDescriptor).channel)
        val connected = link.state.value.isConnected
        update(id) { it.copy(size = size, state = TransferUi.State.WaitingForMac, message = if (connected) null else "Reconnecting to your Mac…") }
        offerWhenConnected(id)
    }

    /**
     * Sends the offer once the link is up. The system file picker sends MyBuddy to the background, where Android
     * cuts its network within seconds; the link reconnects when the app returns, so the offer waits briefly.
     */
    private fun offerWhenConnected(id: String) {
        scope.launch {
            val connected = withTimeoutOrNull(RECONNECT_WAIT_MS) { link.state.first { it.isConnected } } != null
            enqueue {
                val t = outgoing[id] ?: return@enqueue
                if (!connected || link.send(EventType.FILE_OFFER, t.offer.toPayload()) == null) return@enqueue failOutgoing(id, "Not connected to your Mac.")
                t.offered = true
                t.lastActivity = System.currentTimeMillis()
                update(id) { it.copy(message = null) }
            }
        }
    }

    private fun pump(id: String) {
        val t = outgoing[id] ?: return
        val window = t.window ?: return
        if (t.paused) return
        for (index in window.takeSendable()) {
            val length = t.offer.expectedLength(index)
            val buffer = ByteBuffer.allocate(length)
            try {
                var position = index.toLong() * t.offer.chunkSize
                while (buffer.hasRemaining()) {
                    val n = t.channel.read(buffer, position)
                    if (n < 0) throw TransferException("invalid_chunk", "file changed while sending")
                    position += n
                }
            } catch (e: Exception) {
                link.send(EventType.FILE_CANCEL, buildJsonObject { put("transferId", id); put("reason", "The file couldn’t be read") })
                return failOutgoing(id, "The file couldn’t be read.")
            }
            link.send(EventType.FILE_CHUNK, buildJsonObject {
                put("transferId", id); put("index", index); put("data", Base64Url.encode(buffer.array()))
            })
        }
    }

    private fun closeOutgoing(id: String): Outgoing? = outgoing.remove(id)?.also { runCatching { it.channel.close(); it.pfd.close() } }

    private fun failOutgoing(id: String, message: String) {
        closeOutgoing(id)
        update(id) { it.copy(state = TransferUi.State.Failed, message = message) }
    }

    // endregion

    // region Receiving from the Mac

    /** Asks the Mac for a file in a shared folder; its offer is then accepted automatically. */
    fun requestDownload(rootId: String, path: String): Boolean {
        if (blockedReason() != null) return false
        val requestId = UUID.randomUUID().toString()
        enqueue { requested[requestId] = System.currentTimeMillis() }
        return link.send(EventType.FILE_REQUEST, buildJsonObject { put("requestId", requestId); put("rootId", rootId); put("path", path) }) != null
    }

    fun accept(id: String) = enqueue { beginReceiving(id) }

    fun decline(id: String) = enqueue {
        incoming.remove(id) ?: return@enqueue
        link.send(EventType.FILE_ERROR, buildJsonObject { put("transferId", id); put("code", "denied") })
        update(id) { it.copy(state = TransferUi.State.Cancelled, message = "Declined") }
    }

    private fun beginReceiving(id: String) {
        val t = incoming[id] ?: return
        if (t.out != null) return
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, t.offer.name)
            put(MediaStore.Downloads.MIME_TYPE, t.offer.mimeType ?: "application/octet-stream")
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/MyBuddy")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val resolver = context.contentResolver
        val uri = runCatching { resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) }.getOrNull()
        val out = uri?.let { runCatching { resolver.openOutputStream(it) }.getOrNull() }
        if (uri == null || out == null) {
            uri?.let { runCatching { resolver.delete(it, null, null) } }
            incoming.remove(id)
            link.send(EventType.FILE_ERROR, buildJsonObject { put("transferId", id); put("code", "disk_full") })
            return update(id) { it.copy(state = TransferUi.State.Failed, message = "Couldn’t create the file in Downloads.") }
        }
        t.uri = uri
        t.out = out
        t.assembler = ChunkAssembler(t.offer, out)
        t.lastActivity = System.currentTimeMillis()
        update(id) { it.copy(state = TransferUi.State.InProgress) }
        link.send(EventType.FILE_START, buildJsonObject { put("transferId", id); put("fromChunk", 0) })
    }

    private fun discardIncoming(id: String) {
        val t = incoming.remove(id) ?: return
        runCatching { t.out?.close() }
        t.uri?.let { runCatching { context.contentResolver.delete(it, null, null) } }
    }

    // endregion

    /** `file.*` from the Mac. */
    fun handle(e: Envelope) = enqueue {
        val id = e.payload["transferId"]?.jsonPrimitive?.content?.lowercase() ?: return@enqueue
        when (e.type) {
            EventType.FILE_OFFER -> {
                val offer = FileOffer.fromPayload(e.payload) ?: return@enqueue
                if (incoming.containsKey(id) || outgoing.containsKey(id)) return@enqueue
                offer.problem()?.let { code ->
                    link.send(EventType.FILE_ERROR, buildJsonObject { put("transferId", id); put("code", code) })
                    return@enqueue
                }
                if (activeCount() >= MAX_CONCURRENT) {
                    link.send(EventType.FILE_ERROR, buildJsonObject { put("transferId", id); put("code", "denied") })
                    return@enqueue
                }
                incoming[id] = Incoming(offer)
                val asked = offer.requestId?.let { requested.remove(it) } != null
                val auto = !asked && autoSave()
                add(TransferUi(id, offer.name, offer.size, toMac = false, state = TransferUi.State.Offered,
                    message = when {
                        asked -> null
                        auto -> "Saving automatically to Downloads/MyBuddy."
                        else -> "Your Mac wants to send you this file."
                    }))
                if (asked || auto) beginReceiving(id)
            }
            EventType.FILE_CHUNK -> {
                val t = incoming[id] ?: return@enqueue
                val assembler = t.assembler ?: return@enqueue
                val index = e.payload["index"]?.jsonPrimitive?.intOrNull ?: return@enqueue
                val data = e.payload["data"]?.jsonPrimitive?.content?.let(Base64Url::decode) ?: return@enqueue
                try {
                    val received = assembler.write(index, data)
                    t.lastActivity = System.currentTimeMillis()
                    link.send(EventType.FILE_ACK, buildJsonObject { put("transferId", id); put("index", assembler.nextIndex - 1) })
                    update(id) { it.copy(transferred = received, state = if (it.state == TransferUi.State.Paused) it.state else TransferUi.State.InProgress) }
                    if (assembler.complete) {
                        update(id) { it.copy(state = TransferUi.State.Verifying) }
                        val digest = assembler.finish()
                        runCatching { t.out?.close() }
                        if (digest != t.offer.sha256) {
                            discardIncoming(id)
                            link.send(EventType.FILE_ERROR, buildJsonObject { put("transferId", id); put("code", "checksum_mismatch") })
                            return@enqueue update(id) { it.copy(state = TransferUi.State.Failed, message = "The checksum didn’t match — the file was discarded.") }
                        }
                        val uri = t.uri
                        incoming.remove(id)
                        uri?.let { context.contentResolver.update(it, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null) }
                        link.send(EventType.FILE_COMPLETE, buildJsonObject { put("transferId", id); put("sha256", digest) })
                        update(id) { it.copy(state = TransferUi.State.Done, transferred = it.size, uri = uri, message = "Saved to Downloads/MyBuddy · SHA-256 verified") }
                    }
                } catch (ex: Exception) {
                    discardIncoming(id)
                    val code = (ex as? TransferException)?.code ?: "invalid_chunk"
                    link.send(EventType.FILE_ERROR, buildJsonObject { put("transferId", id); put("code", code) })
                    update(id) { it.copy(state = TransferUi.State.Failed, message = "The transfer broke off (${ex.message}).") }
                }
            }
            EventType.FILE_START -> {
                val t = outgoing[id] ?: return@enqueue
                if (t.window != null) return@enqueue
                val from = e.payload["fromChunk"]?.jsonPrimitive?.intOrNull ?: 0
                t.window = SendWindow(t.offer.chunkCount, from)
                t.lastActivity = System.currentTimeMillis()
                update(id) { it.copy(state = if (t.paused) TransferUi.State.Paused else TransferUi.State.InProgress, transferred = from.toLong() * t.offer.chunkSize) }
                pump(id)
            }
            EventType.FILE_ACK -> {
                val t = outgoing[id] ?: return@enqueue
                val window = t.window ?: return@enqueue
                val index = e.payload["index"]?.jsonPrimitive?.intOrNull ?: return@enqueue
                if (!window.ack(index)) return@enqueue failOutgoing(id, "Your Mac acknowledged data that wasn’t sent.")
                t.lastActivity = System.currentTimeMillis()
                val sent = minOf(t.offer.size, (window.highestAcked + 1).toLong() * t.offer.chunkSize)
                update(id) { it.copy(transferred = sent, state = if (window.allAcked) TransferUi.State.Verifying else it.state) }
                pump(id)
            }
            EventType.FILE_COMPLETE -> {
                val t = closeOutgoing(id) ?: return@enqueue
                val ok = e.payload["sha256"]?.jsonPrimitive?.content == t.offer.sha256 && t.window?.allAcked == true
                update(id) {
                    if (ok) it.copy(state = TransferUi.State.Done, transferred = it.size, message = "Delivered · SHA-256 verified by your Mac")
                    else it.copy(state = TransferUi.State.Failed, message = "Your Mac reported a different checksum.")
                }
            }
            EventType.FILE_PAUSE, EventType.FILE_RESUME -> {
                val paused = e.type == EventType.FILE_PAUSE
                outgoing[id]?.let { t ->
                    t.paused = paused
                    t.lastActivity = System.currentTimeMillis()
                    if (!paused) pump(id)
                }
                incoming[id]?.let { it.lastActivity = System.currentTimeMillis() }
                update(id) { if (it.active && it.state != TransferUi.State.Offered && it.state != TransferUi.State.WaitingForMac) it.copy(state = if (paused) TransferUi.State.Paused else TransferUi.State.InProgress) else it }
            }
            EventType.FILE_CANCEL, EventType.FILE_ERROR -> {
                val code = e.payload["code"]?.jsonPrimitive?.content
                closeOutgoing(id)
                discardIncoming(id)
                update(id) {
                    when (code) {
                        null -> it.copy(state = TransferUi.State.Cancelled, message = "Cancelled on your Mac")
                        "denied" -> it.copy(state = TransferUi.State.Failed, message = "Your Mac declined the file.")
                        "checksum_mismatch" -> it.copy(state = TransferUi.State.Failed, message = "Your Mac found a checksum mismatch.")
                        "timeout" -> it.copy(state = TransferUi.State.Failed, message = "The transfer timed out.")
                        else -> it.copy(state = TransferUi.State.Failed, message = "Failed ($code)")
                    }
                }
            }
            else -> {}
        }
    }

    fun pause(id: String) = userPause(id, true)
    fun resume(id: String) = userPause(id, false)

    private fun userPause(id: String, paused: Boolean) = enqueue {
        outgoing[id]?.let { t ->
            t.paused = paused
            t.lastActivity = System.currentTimeMillis()
            if (!paused) pump(id)
        }
        incoming[id]?.let { it.lastActivity = System.currentTimeMillis() }
        link.send(if (paused) EventType.FILE_PAUSE else EventType.FILE_RESUME, buildJsonObject { put("transferId", id) })
        update(id) { it.copy(state = if (paused) TransferUi.State.Paused else TransferUi.State.InProgress) }
    }

    fun cancel(id: String) = enqueue {
        if (outgoing[id] == null && incoming[id] == null) return@enqueue
        closeOutgoing(id)
        discardIncoming(id)
        link.send(EventType.FILE_CANCEL, buildJsonObject { put("transferId", id); put("reason", "Cancelled on the phone") })
        update(id) { it.copy(state = TransferUi.State.Cancelled, message = "Cancelled") }
    }

    fun clearFinished() = enqueue { _items.value = _items.value.filter { it.active } }

    /** The session ended: everything stops and partial files are deleted. */
    fun sessionEnded() = enqueue {
        (outgoing.filterValues { it.offered }.keys + incoming.keys).toList().forEach { id ->
            closeOutgoing(id)
            discardIncoming(id)
            update(id) { it.copy(state = TransferUi.State.Failed, message = "Disconnected from your Mac.") }
        }
        requested.clear()
    }

    private fun expireStalled() {
        val now = System.currentTimeMillis()
        incoming.filter { (_, t) -> t.out != null && now - t.lastActivity > STALL_MS && _items.value.firstOrNull { it.id == t.offer.transferId }?.state != TransferUi.State.Paused }
            .keys.toList().forEach { id ->
                discardIncoming(id)
                link.send(EventType.FILE_ERROR, buildJsonObject { put("transferId", id); put("code", "timeout") })
                update(id) { it.copy(state = TransferUi.State.Failed, message = "The transfer timed out.") }
            }
        outgoing.filter { (_, t) -> t.window != null && !t.paused && now - t.lastActivity > STALL_MS }.keys.toList().forEach { id ->
            link.send(EventType.FILE_ERROR, buildJsonObject { put("transferId", id); put("code", "timeout") })
            failOutgoing(id, "The transfer timed out.")
        }
        requested.entries.removeIf { now - it.value > 120_000 }
    }

    companion object {
        const val MAX_CONCURRENT = 2
        const val STALL_MS = 60_000L
        const val RECONNECT_WAIT_MS = 30_000L
    }
}
