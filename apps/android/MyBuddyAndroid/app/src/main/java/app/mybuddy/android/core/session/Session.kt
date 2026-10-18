package app.mybuddy.android.core.session

import app.mybuddy.android.core.Base64Url
import java.net.URLDecoder
import java.time.Instant
import kotlin.math.min
import kotlin.math.pow
import kotlin.random.Random

class PairingException(message: String) : Exception(message)

/** The contents of the Mac's pairing QR code (docs/PROTOCOL.md §6.1). */
data class PairingInvitation(
    val addresses: List<String>,
    val hostFingerprint: String,
    val secret: ByteArray,
    val expiresAt: Instant,
    val displayName: String,
) {
    override fun equals(other: Any?): Boolean = other is PairingInvitation && addresses == other.addresses &&
        hostFingerprint == other.hostFingerprint && secret.contentEquals(other.secret) && expiresAt == other.expiresAt && displayName == other.displayName

    override fun hashCode(): Int = hostFingerprint.hashCode()

    companion object {
        fun parse(text: String, now: Instant = Instant.now()): PairingInvitation {
            val trimmed = text.trim()
            val prefix = "mybuddy://pair?"
            if (trimmed.length > 1024 || !trimmed.startsWith(prefix)) throw PairingException("not a MyBuddy pairing code")
            val q = mutableMapOf<String, String>()
            for (part in trimmed.substring(prefix.length).substringBefore('#').split("&").filter { it.isNotEmpty() }) {
                val i = part.indexOf('=')
                val key = URLDecoder.decode(if (i < 0) part else part.substring(0, i), "UTF-8")
                val value = if (i < 0) "" else URLDecoder.decode(part.substring(i + 1), "UTF-8")
                if (q.containsKey(key)) throw PairingException("duplicate parameter $key")
                q[key] = value
            }
            if (q["v"] != "1") throw PairingException("unsupported version")
            val addresses = (q["h"] ?: "").split(",").filter { it.isNotEmpty() }
            if (addresses.size !in 1..4 || !addresses.all(::isValidHostPort)) throw PairingException("bad host address")
            val fp = q["fp"]
            if (fp == null || fp.length != 43 || Base64Url.decode(fp)?.size != 32) throw PairingException("bad fingerprint")
            val secret = q["s"]?.let { Base64Url.decode(it) }
            if (secret == null || secret.size != 32) throw PairingException("bad secret")
            val expires = q["x"]?.toLongOrNull()?.let { Instant.ofEpochSecond(it) } ?: throw PairingException("bad expiry")
            if (!expires.isAfter(now)) throw PairingException("This pairing code has expired. Show a new one on your Mac.")
            val name = q["n"] ?: ""
            if (name.codePointCount(0, name.length) > 32) throw PairingException("bad name")
            return PairingInvitation(addresses, fp, secret, expires, name)
        }

        fun isValidHostPort(s: String): Boolean {
            val host: String
            val port: String
            if (s.startsWith("[")) {
                val close = s.indexOf(']')
                if (close < 0 || close + 1 >= s.length || s[close + 1] != ':') return false
                host = s.substring(1, close)
                port = s.substring(close + 2)
            } else {
                val parts = s.split(":")
                if (parts.size != 2) return false
                host = parts[0]
                port = parts[1]
            }
            val p = port.toIntOrNull() ?: return false
            if (p !in 1..65535 || host.isEmpty() || host.length > 253) return false
            if (!host.all { it.isLetterOrDigit() || it in ".-:%" }) return false
            // The phone only dials the local network (PROTOCOL.md §6.1).
            return isLanHost(host)
        }

        /** Mirrors the Mac's EndpointValidator: loopback, private, CGNAT, link-local, ULA or `.local`. */
        fun isLanHost(raw: String): Boolean {
            val host = raw.lowercase().trim('[', ']')
            if (host == "localhost" || host.endsWith(".localhost") || host.endsWith(".local")) return true
            val octets = host.split(".")
            if (octets.size == 4 && octets.all { o -> o.length in 1..3 && o.all(Char::isDigit) && o.toInt() <= 255 }) {
                val a = octets[0].toInt()
                val b = octets[1].toInt()
                return a == 127 || a == 10 || a == 0 || (a == 192 && b == 168) || (a == 169 && b == 254) ||
                    (a == 172 && b in 16..31) || (a == 100 && b in 64..127)
            }
            if (host.contains(":")) {
                return host == "::1" || listOf("fe8", "fe9", "fea", "feb", "fc", "fd").any { host.startsWith(it) }
            }
            return false
        }
    }
}

/** Connection states shared with the Mac (docs/ARCHITECTURE.md §5). */
sealed class ConnectionState(val title: String) {
    object Offline : ConnectionState("Offline")
    object Discovering : ConnectionState("Looking for your Mac")
    object Pairing : ConnectionState("Pairing")
    class AwaitingApproval(val code: String) : ConnectionState("Waiting for approval on your Mac")
    object Connecting : ConnectionState("Connecting")
    object DirectConnected : ConnectionState("Connected · direct")
    object RelayedConnected : ConnectionState("Connected · relayed")
    class Reconnecting(val attempt: Int, val nextRetrySeconds: Double) : ConnectionState("Reconnecting (attempt $attempt)")
    object Suspended : ConnectionState("Paused in the background")
    class Failed(val reason: String) : ConnectionState("Connection failed")
    object Disconnected : ConnectionState("Disconnected")

    val isConnected: Boolean get() = this is DirectConnected || this is RelayedConnected
}

/** Bounded exponential backoff with full jitter. Never retries forever. */
class Backoff(private val base: Double = 0.5, private val cap: Double = 30.0, private val maxAttempts: Int = 8) {
    var attempt = 0
        private set

    fun ceiling(n: Int): Double = min(cap, base * 2.0.pow((n - 1).coerceAtLeast(0)))

    /** Seconds to wait, or null when attempts are exhausted (surface Failed). */
    fun nextDelay(random: (Double) -> Double = { Random.nextDouble(0.0, it.coerceAtLeast(1e-9)) }): Double? {
        if (attempt >= maxAttempts) return null
        attempt++
        return random(ceiling(attempt))
    }

    fun reset() {
        attempt = 0
    }
}
