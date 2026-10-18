package app.mybuddy.android.core.connect

import app.mybuddy.android.core.Base64Url
import app.mybuddy.android.core.crypto.DeviceIdentity
import app.mybuddy.android.core.crypto.IdentityMath
import app.mybuddy.android.core.crypto.deviceId
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.ByteArrayOutputStream
import java.net.URI
import java.nio.ByteBuffer
import java.security.SecureRandom
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import kotlin.math.abs

/**
 * MyBuddy Connect statements (PROTOCOL §7): `label ‖ lp(field)…` with 4-byte big-endian length prefixes,
 * signed with the device key. Byte layout pinned by the shared vectors (the Go server verifies the same).
 */
object ConnectStatements {
    private fun build(label: String, vararg fields: ByteArray): ByteArray = ByteArrayOutputStream().apply {
        write(label.toByteArray())
        for (f in fields) {
            write(ByteBuffer.allocate(4).putInt(f.size).array())
            write(f)
        }
    }.toByteArray()

    private fun String.b() = toByteArray(Charsets.UTF_8)

    fun register(spki: ByteArray, platform: String) = build("MBC1/register", spki, platform.b())
    fun auth(challengeId: String, nonce: ByteArray, deviceId: String) = build("MBC1/auth", challengeId.b(), nonce, deviceId.b())
    fun pairing(hostDeviceId: String, clientDeviceId: String, createdAt: String) = build("MBC1/pairing", hostDeviceId.b(), clientDeviceId.b(), createdAt.b())
    fun rtc(kind: String, rid: String, from: String, to: String, at: String, sdp: String) =
        build("MBC1/rtc", kind.b(), rid.b(), from.b(), to.b(), at.b(), sdp.b())
}

/** One message of the WebRTC introduction relayed through `/v1/signal` (offers/answers signed). */
@Serializable
data class RendezvousMessage(
    val v: Int = 1,
    val kind: String,
    val rid: String,
    val from: String,
    val to: String,
    val at: String? = null,
    val sdp: String? = null,
    val sig: String? = null,
    val candidate: String? = null,
    val sdpMid: String? = null,
    val sdpMLineIndex: Int? = null,
    val reason: String? = null,
) {
    fun encode(): ByteArray = json.encodeToString(this).toByteArray(Charsets.UTF_8).also { require(it.size <= MAX_BYTES) { "too large" } }

    /** True when this offer/answer was signed by [spki] for [expectedTo], within ±2 minutes of [now]. */
    fun verify(spki: ByteArray, expectedTo: String, now: Instant = Instant.now()): Boolean {
        if (kind != OFFER && kind != ANSWER || to != expectedTo || IdentityMath.deviceId(spki) != from) return false
        val at = at ?: return false
        val sdp = sdp ?: return false
        val signature = sig?.let { Base64Url.decode(it) } ?: return false
        val time = ConnectTime.parse(at) ?: return false
        if (abs(time.epochSecond - now.epochSecond) > MAX_SKEW_SECONDS) return false
        return IdentityMath.verify(spki, ConnectStatements.rtc(kind, rid, from, to, at, sdp), signature)
    }

    companion object {
        const val OFFER = "offer"
        const val ANSWER = "answer"
        const val ICE = "ice"
        const val BYE = "bye"
        const val MAX_BYTES = 60 * 1024
        const val MAX_SKEW_SECONDS = 120L
        private val json = Json { encodeDefaults = true; explicitNulls = false; ignoreUnknownKeys = false }

        fun signed(kind: String, rid: String, identity: DeviceIdentity, to: String, sdp: String, now: Instant = Instant.now()): RendezvousMessage {
            val at = ConnectTime.format(now)
            val sig = identity.sign(ConnectStatements.rtc(kind, rid, identity.deviceId, to, at, sdp))
            return RendezvousMessage(kind = kind, rid = rid, from = identity.deviceId, to = to, at = at, sdp = sdp, sig = Base64Url.encode(sig))
        }

        /** Parses and shape-checks a relayed message; null when malformed. */
        fun decode(bytes: ByteArray): RendezvousMessage? {
            if (bytes.size > MAX_BYTES) return null
            val m = runCatching { json.decodeFromString<RendezvousMessage>(bytes.toString(Charsets.UTF_8)) }.getOrNull() ?: return null
            if (m.v != 1 || !ConnectIds.isDeviceId(m.from) || !ConnectIds.isDeviceId(m.to) || !ConnectIds.isRendezvousId(m.rid)) return null
            return when (m.kind) {
                OFFER, ANSWER -> m.takeIf { !it.sdp.isNullOrEmpty() && it.sdp.length <= 32 * 1024 && it.at != null && it.sig != null }
                ICE -> m.takeIf { (it.candidate?.length ?: 0) <= 1024 && (it.sdpMid?.length ?: 0) <= 32 && (it.sdpMLineIndex ?: 0) in 0..15 }
                BYE -> m.takeIf { (it.reason?.length ?: 0) <= 64 }
                else -> null
            }
        }
    }
}

object ConnectIds {
    private val deviceId = Regex("^[0-9a-f]{32}$")
    private val rendezvousId = Regex("^r_[A-Za-z0-9_-]{8,64}$")
    private val random = SecureRandom()

    fun isDeviceId(s: String) = deviceId.matches(s)
    fun isRendezvousId(s: String) = rendezvousId.matches(s)
    fun newRendezvousId(): String = "r_" + Base64Url.encode(ByteArray(12).also(random::nextBytes))
    fun newMessageId(): String = "m" + Base64Url.encode(ByteArray(9).also(random::nextBytes))
}

/** RFC 3339 with milliseconds, UTC — what the statements and the server use. */
object ConnectTime {
    private val formatter = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC)
    fun format(t: Instant): String = formatter.format(t)
    fun parse(s: String): Instant? = runCatching { Instant.parse(s) }.getOrNull()
}

/**
 * Accepted Connect server addresses: `https://host[:port]` without path, query, credentials or fragment.
 * Plain `http://` only for local development hosts (the emulator's 10.0.2.2, loopback) and only in debug builds.
 */
object ConnectServerUrl {
    private val devHosts = setOf("10.0.2.2", "127.0.0.1", "localhost")

    fun normalize(input: String, allowDevCleartext: Boolean): String? {
        val text = input.trim()
        if (text.length > 256) return null
        val uri = runCatching { URI(text) }.getOrNull() ?: return null
        val scheme = uri.scheme?.lowercase() ?: return null
        val host = uri.host?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
        if (uri.rawUserInfo != null || uri.rawQuery != null || uri.rawFragment != null) return null
        if (!(uri.rawPath.isNullOrEmpty() || uri.rawPath == "/")) return null
        if (!(scheme == "https" || (scheme == "http" && allowDevCleartext && host in devHosts))) return null
        return "$scheme://$host${if (uri.port > 0) ":${uri.port}" else ""}"
    }

    fun signalUrl(server: String): String = server.replaceFirst("https://", "wss://").replaceFirst("http://", "ws://") + "/v1/signal"
}

/** How the session reaches the Mac. */
enum class SessionRoute(val label: String) {
    WIFI("Wi-Fi"), TAILSCALE("Tailscale"), INTERNET_DIRECT("Internet"), INTERNET_RELAYED("Internet (relayed)");

    val isInternet get() = this == INTERNET_DIRECT || this == INTERNET_RELAYED
    /** File bytes never pass through a server, even encrypted. */
    val allowsFileTransfer get() = this != INTERNET_RELAYED
}

/** A stats entry reduced to what route detection needs (type + string/number members). */
data class StatsLite(val id: String, val type: String, val members: Map<String, Any?>)

/** Whether a WebRTC connection's selected candidate pair goes through a TURN relay; null until selected. */
object IceRoute {
    fun isRelayed(entries: List<StatsLite>): Boolean? {
        val byId = entries.associateBy { it.id }
        val selected = entries.firstOrNull { it.type == "transport" }?.members?.get("selectedCandidatePairId") as? String
            ?: entries.firstOrNull { it.type == "candidate-pair" && it.members["nominated"] == true && it.members["state"] == "succeeded" }?.id
            ?: return null
        val pair = byId[selected] ?: return null
        val local = (pair.members["localCandidateId"] as? String)?.let(byId::get)
        val remote = (pair.members["remoteCandidateId"] as? String)?.let(byId::get)
        if (local == null && remote == null) return null
        return local?.members?.get("candidateType") == "relay" || remote?.members?.get("candidateType") == "relay"
    }
}

/** `GET /v1/turn-credentials` (coturn REST convention). */
@Serializable
data class TurnCredentials(val urls: List<String>, val username: String, val credential: String, val ttlSeconds: Int)
