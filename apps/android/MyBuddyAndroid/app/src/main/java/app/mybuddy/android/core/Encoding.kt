package app.mybuddy.android.core

import java.nio.ByteBuffer
import java.security.MessageDigest
import java.security.SecureRandom
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Base64

/** base64url without padding (RFC 4648 §5) — the protocol's binary encoding. Strict like the Mac side. */
object Base64Url {
    private val alphabet = Regex("^[A-Za-z0-9_-]*$")

    fun encode(data: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(data)

    fun decode(s: String): ByteArray? {
        if (!alphabet.matches(s) || s.length % 4 == 1) return null
        return try {
            Base64.getUrlDecoder().decode(s)
        } catch (e: IllegalArgumentException) {
            null
        }
    }
}

object Hex {
    fun encode(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

    fun decode(s: String): ByteArray? {
        if (s.length % 2 != 0) return null
        return try {
            ByteArray(s.length / 2) { i -> s.substring(i * 2, i * 2 + 2).toInt(16).toByte() }
        } catch (e: NumberFormatException) {
            null
        }
    }
}

/** 4-byte big-endian length prefix followed by the bytes (`lp()` in PROTOCOL.md). */
fun ByteArray.lengthPrefixed(): ByteArray = ByteBuffer.allocate(4 + size).putInt(size).put(this).array()

fun ByteArray.sha256(): ByteArray = MessageDigest.getInstance("SHA-256").digest(this)

fun randomBytes(n: Int): ByteArray = ByteArray(n).also { SecureRandom().nextBytes(it) }

/** RFC 3339 UTC timestamps with millisecond precision. */
object Timestamp {
    private val formatter = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC)

    fun format(instant: Instant): String = formatter.format(instant)

    fun parse(s: String): Instant? {
        if (s.length > 40) return null
        return try {
            OffsetDateTime.parse(s).toInstant()
        } catch (e: Exception) {
            try {
                Instant.parse(s)
            } catch (e2: Exception) {
                null
            }
        }
    }
}
