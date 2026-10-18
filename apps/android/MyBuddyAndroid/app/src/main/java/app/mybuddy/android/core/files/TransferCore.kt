package app.mybuddy.android.core.files

import app.mybuddy.android.core.Hex
import app.mybuddy.android.core.protocol.FileNameRules
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import java.io.OutputStream
import java.security.MessageDigest
import java.util.UUID

/** `file.offer` (PROTOCOL §5.5); mirrors the Mac's `FileOffer`. */
data class FileOffer(
    val transferId: String,
    val name: String,
    val size: Long,
    val sha256: String,
    val chunkSize: Int = DEFAULT_CHUNK,
    val mimeType: String? = null,
    val requestId: String? = null,
) {
    val chunkCount: Int get() = ((size + chunkSize - 1) / chunkSize).toInt()

    fun expectedLength(index: Int): Int = minOf(chunkSize.toLong(), size - index.toLong() * chunkSize).toInt()

    fun toPayload(): JsonObject = buildJsonObject {
        put("transferId", transferId)
        put("name", name)
        put("size", size)
        put("sha256", sha256)
        put("chunkSize", chunkSize)
        mimeType?.let { put("mimeType", it.take(128)) }
    }

    /** Why this offer must be refused, or null when it is acceptable. */
    fun problem(maxSize: Long = MAX_SIZE): String? = when {
        !FileNameRules.isSafe(name) -> "denied"
        size <= 0 -> "denied"
        size > maxSize -> "too_large"
        chunkSize !in 16 * 1024..64 * 1024 -> "denied"
        sha256.length != 64 || Hex.decode(sha256) == null -> "denied"
        else -> null
    }

    companion object {
        const val DEFAULT_CHUNK = 64 * 1024
        const val MAX_SIZE = 2L * 1024 * 1024 * 1024

        /** Parses a validated `file.offer` payload. */
        fun fromPayload(p: JsonObject): FileOffer? {
            val id = p["transferId"]?.jsonPrimitive?.content ?: return null
            runCatching { UUID.fromString(id) }.getOrNull() ?: return null
            return FileOffer(
                transferId = id.lowercase(),
                name = p["name"]?.jsonPrimitive?.content ?: return null,
                size = p["size"]?.jsonPrimitive?.longOrNull ?: return null,
                sha256 = p["sha256"]?.jsonPrimitive?.content ?: return null,
                chunkSize = p["chunkSize"]?.jsonPrimitive?.longOrNull?.toInt() ?: return null,
                mimeType = p["mimeType"]?.jsonPrimitive?.content,
                requestId = p["requestId"]?.jsonPrimitive?.content?.lowercase(),
            )
        }
    }
}

/** Sender flow control: at most [window] chunks un-acknowledged (mirrors the Mac's `SendWindow`). */
class SendWindow(val chunkCount: Int, from: Int = 0, val window: Int = 8) {
    var nextToSend = from.coerceIn(0, chunkCount)
        private set
    var highestAcked = nextToSend - 1
        private set

    fun takeSendable(): List<Int> {
        val out = ArrayList<Int>()
        while (nextToSend < chunkCount && nextToSend - (highestAcked + 1) < window) out += nextToSend++
        return out
    }

    /** False for an index that was never sent (protocol violation). */
    fun ack(index: Int): Boolean {
        if (index < 0 || index >= nextToSend) return false
        highestAcked = maxOf(highestAcked, index)
        return true
    }

    val allAcked: Boolean get() = highestAcked == chunkCount - 1
    val fraction: Float get() = if (chunkCount == 0) 1f else (highestAcked + 1).toFloat() / chunkCount
}

class TransferException(val code: String, message: String) : Exception(message)

/**
 * Writes chunks strictly in order to [out] while hashing them; duplicates of written chunks are ignored,
 * anything else out of order or of the wrong length is an error. [finish] returns the SHA-256 hex digest.
 */
class ChunkAssembler(private val offer: FileOffer, private val out: OutputStream) {
    private val digest = MessageDigest.getInstance("SHA-256")
    var nextIndex = 0
        private set
    var received = 0L
        private set

    fun write(index: Int, data: ByteArray): Long {
        if (index < nextIndex) return received // duplicate
        if (index != nextIndex || index >= offer.chunkCount) throw TransferException("invalid_chunk", "unexpected chunk $index")
        if (data.size != offer.expectedLength(index)) throw TransferException("invalid_chunk", "bad chunk length")
        out.write(data)
        digest.update(data)
        nextIndex++
        received += data.size
        return received
    }

    val complete: Boolean get() = nextIndex == offer.chunkCount

    fun finish(): String {
        if (!complete || received != offer.size) throw TransferException("invalid_chunk", "incomplete")
        out.flush()
        return Hex.encode(digest.digest())
    }
}

/** Clipboard rules shared with the Mac (PROTOCOL §5.6). */
object ClipboardRules {
    const val MAX_BYTES = 65_536

    fun hash(text: String): String = Hex.encode(MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8)))

    /** A reason this text looks like a secret (then it is never synced automatically), or null. */
    fun looksSensitive(text: String): String? {
        val t = text.trim()
        return when {
            Regex("""-----BEGIN [A-Z ]*PRIVATE KEY-----""").containsMatchIn(t) -> "private key"
            Regex("""\b(sk-[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{30,}|xox[abposr]-[A-Za-z0-9-]{10,})""").containsMatchIn(t) -> "API key or token"
            Regex("""\b\d{4}[ -]?\d{4}[ -]?\d{4}[ -]?\d{1,7}\b""").containsMatchIn(t) && luhnCandidate(t) -> "card number"
            else -> null
        }
    }

    private fun luhnCandidate(t: String): Boolean = Regex("""\d[\d -]{11,22}\d""").findAll(t).any { m ->
        val digits = m.value.filter(Char::isDigit)
        digits.length in 13..19 && digits.reversed().mapIndexed { i, c ->
            val d = c - '0'
            if (i % 2 == 1) (d * 2).let { if (it > 9) it - 9 else it } else d
        }.sum() % 10 == 0
    }
}

/** Content applied from the Mac is never offered back (ping-pong prevention). */
class ClipboardLoopGuard(private val capacity: Int = 16) {
    private val recent = ArrayDeque<String>()

    fun noteApplied(hash: String) {
        recent.remove(hash)
        recent.addLast(hash)
        while (recent.size > capacity) recent.removeFirst()
    }

    fun shouldOffer(hash: String): Boolean = hash !in recent
}
