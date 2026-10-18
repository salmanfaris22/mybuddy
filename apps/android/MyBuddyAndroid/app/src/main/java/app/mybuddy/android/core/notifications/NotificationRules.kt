package app.mybuddy.android.core.notifications

import app.mybuddy.android.core.Base64Url
import app.mybuddy.android.core.files.ClipboardRules
import java.security.MessageDigest

/** What the Mac may see of a mirrored notification (PROTOCOL §5.10). */
enum class PreviewPolicy(val wire: String, val title: String) {
    HIDDEN("content_hidden", "App name only"),
    TITLE("title_only", "Title only"),
    FULL("none", "Title and text"),
}

/** A notification as the listener sees it, reduced to what the rules need. */
data class SeenNotification(
    val key: String,
    val packageName: String,
    val appLabel: String,
    val title: String?,
    val text: String?,
    val category: String?,
    val ongoing: Boolean,
    val groupSummary: Boolean,
    val clearable: Boolean,
)

/** The payload fields of `notification.posted` after filtering and redaction. */
data class MirroredNotification(
    val notificationId: String,
    val appPackage: String,
    val appLabel: String,
    val title: String?,
    val text: String?,
    val redaction: String,
    val category: String?,
)

/**
 * Which notifications leave the phone, and how much of them. Pure, so it is unit-tested: ongoing, persistent and
 * silent group-summary notifications and MyBuddy's own are never sent; blocked apps are skipped; the preview
 * policy decides title/text; with full previews, anything that looks like a one-time code, key or card number is
 * masked (`partial`). Ids are salted hashes of Android's key, so the Mac never learns it.
 */
class NotificationRules(private val ownPackage: String, private val salt: ByteArray) {
    fun shouldMirror(n: SeenNotification, blocked: Set<String>): Boolean = when {
        n.packageName == ownPackage -> false
        n.ongoing || !n.clearable || n.groupSummary -> false
        n.category in NEVER -> false
        n.packageName in blocked -> false
        n.title.isNullOrBlank() && n.text.isNullOrBlank() -> false
        else -> true
    }

    fun mirror(n: SeenNotification, policy: PreviewPolicy): MirroredNotification {
        val title = n.title?.trim()?.take(256)?.takeIf { it.isNotEmpty() }
        val text = n.text?.trim()?.take(1024)?.takeIf { it.isNotEmpty() }
        return when (policy) {
            PreviewPolicy.HIDDEN -> MirroredNotification(id(n.key), n.packageName.take(255), label(n), null, null, PreviewPolicy.HIDDEN.wire, category(n))
            PreviewPolicy.TITLE -> MirroredNotification(id(n.key), n.packageName.take(255), label(n), title?.let(::mask), null, PreviewPolicy.TITLE.wire, category(n))
            PreviewPolicy.FULL -> {
                val maskedTitle = title?.let(::mask)
                val maskedText = text?.let(::mask)
                val changed = maskedTitle != title || maskedText != text
                MirroredNotification(id(n.key), n.packageName.take(255), label(n), maskedTitle, maskedText, if (changed) "partial" else "none", category(n))
            }
        }
    }

    /** Opaque, stable per key for this install (removal events must match), unlinkable across installs. */
    fun id(key: String): String {
        val digest = MessageDigest.getInstance("SHA-256").apply { update(salt); update(key.toByteArray()) }.digest()
        return "n_" + Base64Url.encode(digest.copyOf(12))
    }

    private fun label(n: SeenNotification) = n.appLabel.trim().ifEmpty { n.packageName }.take(128)
    private fun category(n: SeenNotification) = n.category?.takeIf { it.length in 1..32 }

    companion object {
        /** Categories that are never mirrored (system/transport noise or explicitly private). */
        private val NEVER = setOf("transport", "sys", "service", "progress", "status")
        private val code = Regex("""(?<![\d-])(\d[ -]?){4,8}(?![\d-])""")
        private val codeContext = Regex("""(?i)\b(code|otp|passcode|pin|verification|verify|2fa|one[- ]time|login|sign[- ]in|security)\b""")

        /** Masks one-time codes (digits near words like "code"/"OTP"), keys/tokens and card numbers. */
        fun mask(s: String): String {
            var out = s
            if (ClipboardRules.looksSensitive(out) != null) {
                out = out.replace(Regex("""\b(sk-[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{30,}|xox[abposr]-[A-Za-z0-9-]{10,})"""), "•••")
                out = out.replace(Regex("""-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*"""), "•••")
                out = out.replace(Regex("""\b(\d[ -]?){13,19}\b"""), "•••• •••• •••• ••••")
            }
            if (codeContext.containsMatchIn(out)) out = code.replace(out) { "•".repeat(it.value.count(Char::isDigit)) }
            return out
        }
    }
}
