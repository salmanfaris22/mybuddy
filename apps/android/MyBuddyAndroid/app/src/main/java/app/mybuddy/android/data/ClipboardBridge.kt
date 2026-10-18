package app.mybuddy.android.data

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.PersistableBundle
import app.mybuddy.android.core.files.ClipboardLoopGuard
import app.mybuddy.android.core.files.ClipboardRules
import app.mybuddy.android.core.protocol.Envelope
import app.mybuddy.android.core.protocol.EventType
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.util.UUID

/**
 * Plain-text clipboard sync with the Mac (PROTOCOL §5.6). Android only lets apps read the clipboard while
 * they are in the foreground, so sending is an explicit action (or typed text); receiving follows the mode:
 * Off (refused), Ask (shown, copied on tap) or Auto (copied, unless it looks like a secret).
 */
class ClipboardBridge(private val context: Context, private val link: MacLink, private val deviceId: String) {
    enum class Mode { Off, Ask, Auto }

    data class Incoming(val revisionId: String, val text: String, val sensitive: String?)

    val mode = MutableStateFlow(Mode.Ask)
    private val _pending = MutableStateFlow<Incoming?>(null)
    val pending: StateFlow<Incoming?> = _pending
    private val _log = MutableStateFlow<List<String>>(emptyList())
    val log: StateFlow<List<String>> = _log

    private val loopGuard = ClipboardLoopGuard()
    private val peerOffers = HashMap<String, String>() // revisionId → expected hash
    private var ourOffer: Pair<String, String>? = null // revisionId → text
    private val clipboard get() = context.getSystemService(ClipboardManager::class.java)

    private fun note(line: String) {
        _log.value = (listOf(line) + _log.value).take(8)
    }

    /** Sends what's on the phone's clipboard now (call from a user action, while the app is visible). */
    fun sendClipboard(): String? {
        val text = clipboard?.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(context)?.toString()
            ?: return "The phone’s clipboard is empty (or holds something other than text)."
        return sendText(text)
    }

    /** Puts [text] on the Mac's clipboard (subject to the Mac's own clipboard setting). */
    fun sendText(text: String): String? {
        if (text.isEmpty()) return "Nothing to send."
        val bytes = text.toByteArray(Charsets.UTF_8).size
        if (bytes > ClipboardRules.MAX_BYTES) return "Clipboard text is limited to 64 KB."
        val hash = ClipboardRules.hash(text)
        if (!loopGuard.shouldOffer(hash)) return "That text just came from your Mac."
        val revision = UUID.randomUUID().toString()
        ourOffer = revision to text
        val sent = link.send(EventType.CLIPBOARD_OFFER, buildJsonObject {
            put("revisionId", revision)
            put("originDeviceId", deviceId)
            put("contentHash", hash)
            put("size", bytes)
            put("mime", "text/plain")
        })
        if (sent == null) return "Not connected to your Mac."
        note("Offered ${text.length} characters to your Mac")
        return null
    }

    /** `clipboard.*` from the Mac. */
    fun handle(e: Envelope) {
        val revision = e.payload["revisionId"]?.jsonPrimitive?.content
        when (e.type) {
            EventType.CLIPBOARD_OFFER -> {
                revision ?: return
                if (mode.value == Mode.Off) {
                    link.send(EventType.CLIPBOARD_PAUSED, buildJsonObject { put("paused", true) })
                    return
                }
                peerOffers[revision] = e.payload["contentHash"]?.jsonPrimitive?.content ?: return
                link.send(EventType.CLIPBOARD_REQUEST, buildJsonObject { put("revisionId", revision) })
            }
            EventType.CLIPBOARD_CONTENT -> {
                revision ?: return
                val expected = peerOffers.remove(revision) ?: return
                val text = e.payload["text"]?.jsonPrimitive?.content ?: return
                if (ClipboardRules.hash(text) != expected) {
                    note("Ignored clipboard text whose checksum didn’t match")
                    return
                }
                val sensitive = ClipboardRules.looksSensitive(text)
                if (mode.value == Mode.Auto && sensitive == null) apply(revision, text, sensitive)
                else {
                    _pending.value = Incoming(revision, text, sensitive)
                    note("Your Mac copied ${text.length} characters — waiting for you")
                }
            }
            EventType.CLIPBOARD_REQUEST -> {
                val offer = ourOffer ?: return
                if (offer.first != revision) return
                link.send(EventType.CLIPBOARD_CONTENT, buildJsonObject { put("revisionId", offer.first); put("text", offer.second) })
            }
            EventType.CLIPBOARD_APPLIED -> note("Your Mac pasted it onto its clipboard")
            EventType.CLIPBOARD_PAUSED -> note("Clipboard sync is off or paused on your Mac")
            else -> {}
        }
    }

    fun acceptPending() {
        val p = _pending.value ?: return
        _pending.value = null
        apply(p.revisionId, p.text, p.sensitive)
    }

    fun dismissPending() {
        _pending.value = null
    }

    private fun apply(revisionId: String, text: String, sensitive: String?) {
        loopGuard.noteApplied(ClipboardRules.hash(text))
        val clip = ClipData.newPlainText("From your Mac", text)
        if (sensitive != null && Build.VERSION.SDK_INT >= 33) {
            // Hides the preview in Android's clipboard UI (Android 13+).
            clip.description.extras = PersistableBundle().apply { putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true) }
        }
        clipboard?.setPrimaryClip(clip)
        link.send(EventType.CLIPBOARD_APPLIED, buildJsonObject { put("revisionId", revisionId) })
        note("Copied ${text.length} characters from your Mac")
    }

    fun sessionEnded() {
        peerOffers.clear()
        ourOffer = null
        _pending.value = null
    }
}
