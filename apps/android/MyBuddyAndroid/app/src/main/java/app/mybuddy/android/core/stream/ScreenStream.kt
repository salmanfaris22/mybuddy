package app.mybuddy.android.core.stream

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** A display the Mac offers (`screen.state.displays`). */
data class StreamDisplay(val id: String, val name: String, val width: Int, val height: Int, val main: Boolean)

/** One `screen.state` message from the Mac. */
data class HostStreamState(
    val state: String,
    val reason: String? = null,
    val message: String? = null,
    val quality: String? = null,
    val tier: String? = null,
    val displayId: String? = null,
    val width: Int? = null,
    val height: Int? = null,
    val fps: Int? = null,
    val source: String? = null,
    val displays: List<StreamDisplay> = emptyList(),
) {
    companion object {
        /** The payload was already validated against the catalog by the envelope codec. */
        fun parse(p: JsonObject): HostStreamState {
            fun s(k: String) = p[k]?.jsonPrimitive?.content
            fun i(k: String) = p[k]?.jsonPrimitive?.intOrNull
            val displays = (p["displays"] as? JsonArray)?.mapNotNull {
                val o = it.jsonObject
                StreamDisplay(
                    o["displayId"]?.jsonPrimitive?.content ?: return@mapNotNull null,
                    o["name"]?.jsonPrimitive?.content ?: "Display",
                    o["width"]?.jsonPrimitive?.intOrNull ?: 0,
                    o["height"]?.jsonPrimitive?.intOrNull ?: 0,
                    o["main"]?.jsonPrimitive?.booleanOrNull ?: false,
                )
            } ?: emptyList()
            return HostStreamState(s("state") ?: "failed", s("reason"), s("message"), s("quality"), s("tier"), s("displayId"),
                i("width"), i("height"), i("fps"), s("source"), displays)
        }
    }
}

/** What the phone shows for the remote screen. Never "Live" without a decoded picture from the Mac. */
enum class StreamPhase { Idle, Requesting, Starting, AwaitingSelection, Connecting, Live, Reconnecting, Stopped, Failed, NotAuthorized }

data class StreamUi(
    val phase: StreamPhase = StreamPhase.Idle,
    val message: String? = null,
    val host: HostStreamState? = null,
    val stats: StreamStats? = null,
    val quality: String = "auto",
    val framesRendered: Long = 0,
    /** The video connection's network check (ICE state, e.g. "checking"), shown while connecting. */
    val ice: String? = null,
) {
    val isActive: Boolean get() = phase in setOf(StreamPhase.Requesting, StreamPhase.Starting, StreamPhase.AwaitingSelection, StreamPhase.Connecting, StreamPhase.Live, StreamPhase.Reconnecting)
}

object StreamText {
    /** Human text for a `screen.state` reason; unknown reasons fall back to the Mac's own message. */
    fun reason(reason: String?, message: String?): String = when (reason) {
        "not_authorized" -> "Your Mac hasn’t allowed screen recording for MyBuddy yet. On the Mac: MyBuddy → Remote Desktop → Screen Recording → Allow."
        "busy" -> message ?: "Another device is already viewing this Mac."
        "no_display" -> "Your Mac has no display to share right now."
        "capture_failed" -> message ?: "Your Mac couldn’t start capturing the screen."
        "capture_stopped" -> message ?: "Your Mac stopped sharing its screen."
        "connection_failed" -> "The video connection to your Mac was lost."
        "negotiation_failed" -> "Couldn’t set up the video connection."
        "stopped_on_mac" -> "Screen sharing was stopped on your Mac."
        "emergency_stop" -> "Your Mac ended screen sharing with Emergency Stop."
        "selection_cancelled" -> "Nothing was chosen to share on your Mac."
        "user", "background" -> "Stopped."
        else -> message ?: "Screen sharing stopped."
    }

    /** What the phone adds on top of the network, e.g. "buffer 40 ms · decode 5 ms · 0 freezes". */
    fun latency(s: StreamStats): String? = listOfNotNull(
        s.jitterBufferMs?.let { "buffer %.0f ms".format(it) },
        s.decodeMs?.let { "decode %.0f ms".format(it) },
        s.freezeCount?.let { "$it freeze" + if (it == 1L) "" else "s" },
    ).joinToString(" · ").ifEmpty { null }

    fun bitrate(kbps: Double?): String? = kbps?.let { if (it >= 1000) "%.1f Mbps".format(it / 1000) else "%.0f kbps".format(it) }

    /** e.g. "1280×800 · 30 fps · H264 (hardware) · 2.1 Mbps". */
    fun summary(s: StreamStats): String = listOfNotNull(
        if (s.width != null && s.height != null) "${s.width}×${s.height}" else null,
        s.fps?.let { "%.0f fps".format(it) },
        s.codec?.let { it + if (s.hardwareAccelerated == true) " (hardware)" else "" },
        bitrate(s.bitrateKbps),
    ).joinToString(" · ").ifEmpty { "measuring…" }

    fun path(s: StreamStats?): String = when (s?.path) {
        MediaPath.Direct -> "Direct"
        MediaPath.Relayed -> "Relayed (TURN)"
        else -> "—"
    }
}

enum class MediaPath { Direct, Relayed, Unknown }

/** A one-second view of the received video, as measured by WebRTC. */
data class StreamStats(
    val fps: Double? = null,
    val bitrateKbps: Double? = null,
    val width: Int? = null,
    val height: Int? = null,
    val codec: String? = null,
    val implementation: String? = null,
    val hardwareAccelerated: Boolean? = null,
    val rttMs: Double? = null,
    val path: MediaPath = MediaPath.Unknown,
    val localCandidateType: String? = null,
    val remoteCandidateType: String? = null,
    val packetsLost: Long? = null,
    val framesDropped: Long? = null,
    val framesDecoded: Long? = null,
    /** Average time a frame waited in the jitter buffer over the last interval (ms). */
    val jitterBufferMs: Double? = null,
    /** Average decode time per frame over the last interval (ms). */
    val decodeMs: Double? = null,
    /** Video freezes since the stream started (W3C `freezeCount`). */
    val freezeCount: Long? = null,
)

/** One webrtc-stats object (W3C), reduced to plain values so parsing is JVM-testable. */
data class StatsEntry(val id: String, val type: String, val timestampUs: Double, val values: Map<String, Any?>) {
    fun num(k: String): Double? = when (val v = values[k]) {
        is Number -> v.toDouble()
        is Boolean -> if (v) 1.0 else 0.0
        else -> null
    }

    fun str(k: String): String? = values[k] as? String
}

/** Mirrors the Mac's StreamStatsParser for the receiving side. */
class InboundStatsParser {
    private var lastBytes: Double? = null
    private var lastTimestampUs: Double? = null
    private var lastJitterDelay: Double? = null
    private var lastJitterEmitted: Double? = null
    private var lastDecodeTime: Double? = null
    private var lastDecoded: Double? = null

    /** Δa / Δb over the last interval (e.g. seconds per frame), or null without a usable previous sample. */
    private fun rate(a: Double?, b: Double?, lastA: Double?, lastB: Double?): Double? {
        if (a == null || b == null || lastA == null || lastB == null) return null
        val db = b - lastB
        return if (db > 0 && a >= lastA) (a - lastA) / db else null
    }

    fun sample(entries: List<StatsEntry>): StreamStats {
        val byId = entries.associateBy { it.id }
        val rtp = entries.filter { it.type == "inbound-rtp" && (it.str("kind") ?: it.str("mediaType")) == "video" }
            .maxByOrNull { it.num("bytesReceived") ?: 0.0 }
        var bitrate: Double? = null
        if (rtp != null) {
            val bytes = rtp.num("bytesReceived")
            val lb = lastBytes
            val lt = lastTimestampUs
            if (bytes != null && lb != null && lt != null && rtp.timestampUs > lt && bytes >= lb) {
                bitrate = (bytes - lb) * 8 / ((rtp.timestampUs - lt) / 1_000_000) / 1000
            }
            lastBytes = bytes
            lastTimestampUs = rtp.timestampUs
        }
        val jitterDelay = rtp?.num("jitterBufferDelay")
        val jitterEmitted = rtp?.num("jitterBufferEmittedCount")
        val decodeTime = rtp?.num("totalDecodeTime")
        val decoded = rtp?.num("framesDecoded")
        val jitterMs = rate(jitterDelay, jitterEmitted, lastJitterDelay, lastJitterEmitted)?.times(1000)
        val decodeMs = rate(decodeTime, decoded, lastDecodeTime, lastDecoded)?.times(1000)
        if (rtp != null) {
            lastJitterDelay = jitterDelay
            lastJitterEmitted = jitterEmitted
            lastDecodeTime = decodeTime
            lastDecoded = decoded
        }
        val pairId = entries.firstOrNull { it.type == "transport" && it.str("selectedCandidatePairId") != null }?.str("selectedCandidatePairId")
        val pair = pairId?.let { byId[it] }
            ?: entries.firstOrNull { it.type == "candidate-pair" && it.str("state") == "succeeded" && it.num("nominated") == 1.0 }
        val local = pair?.str("localCandidateId")?.let { byId[it]?.str("candidateType") }
        val remote = pair?.str("remoteCandidateId")?.let { byId[it]?.str("candidateType") }
        val path = when {
            local == null && remote == null -> MediaPath.Unknown
            local == "relay" || remote == "relay" -> MediaPath.Relayed
            else -> MediaPath.Direct
        }
        return StreamStats(
            fps = rtp?.num("framesPerSecond"),
            bitrateKbps = bitrate,
            width = rtp?.num("frameWidth")?.toInt()?.takeIf { it > 0 },
            height = rtp?.num("frameHeight")?.toInt()?.takeIf { it > 0 },
            codec = rtp?.str("codecId")?.let { byId[it]?.str("mimeType") }?.substringAfterLast('/'),
            implementation = rtp?.str("decoderImplementation"),
            hardwareAccelerated = rtp?.num("powerEfficientDecoder")?.let { it != 0.0 },
            rttMs = pair?.num("currentRoundTripTime")?.let { it * 1000 },
            path = path,
            localCandidateType = local,
            remoteCandidateType = remote,
            packetsLost = rtp?.num("packetsLost")?.toLong(),
            framesDropped = rtp?.num("framesDropped")?.toLong(),
            framesDecoded = rtp?.num("framesDecoded")?.toLong(),
            jitterBufferMs = jitterMs,
            decodeMs = decodeMs,
            freezeCount = rtp?.num("freezeCount")?.toLong(),
        )
    }
}

/** A remote ICE candidate as carried by `webrtc.ice`. */
data class RemoteCandidate(val sdp: String, val sdpMid: String?, val sdpMLineIndex: Int)

/**
 * Holds remote candidates until the offer they belong to has been applied (bounded so a misbehaving peer cannot grow
 * it without limit). The Mac starts gathering the moment it sets its offer, so its first candidates can arrive just
 * *before* the offer: they wait here instead of being dropped (dropping them left ICE with no Mac address to try —
 * "stuck on Connecting video…"). Candidates name their ICE generation (`ufrag`): after an ICE restart, early
 * candidates of the new generation wait for the new offer and late ones of a retired generation are discarded.
 */
class CandidateBuffer(private val limit: Int = 64) {
    private val pending = ArrayList<RemoteCandidate>()
    private val retired = HashSet<String>()
    private var current: String? = null
    var ready = false
        private set

    /** Returns true when the candidate should be applied now. */
    fun offer(c: RemoteCandidate): Boolean {
        val u = ufragOf(c.sdp)
        if (u != null && u in retired) return false
        if (ready && (u == null || current == null || u == current)) return true
        if (pending.size < limit) pending += c
        return false
    }

    /** A new offer is about to be applied: candidates wait until [drain]. */
    fun hold() {
        ready = false
    }

    /** The offer whose ICE username fragment is [ufrag] is applied: returns the waiting candidates that belong to it. */
    fun drain(ufrag: String? = null): List<RemoteCandidate> {
        ready = true
        current?.let { if (it != ufrag) retired += it }
        current = ufrag
        val now = pending.filter { c -> ufragOf(c.sdp).let { it == null || ufrag == null || it == ufrag } }
        pending.removeAll { c -> c in now || ufragOf(c.sdp)?.let { it in retired } == true }
        return now
    }

    /** The connection is gone: forget everything. */
    fun reset() {
        ready = false
        current = null
        retired.clear()
        pending.clear()
    }

    val size: Int get() = pending.size

    companion object {
        private val CANDIDATE_UFRAG = Regex("""\bufrag (\S+)""")
        private val SDP_UFRAG = Regex("""a=ice-ufrag:(\S+)""")
        fun ufragOf(candidate: String): String? = CANDIDATE_UFRAG.find(candidate)?.groupValues?.get(1)
        fun ufragOfSdp(sdp: String): String? = SDP_UFRAG.find(sdp)?.groupValues?.get(1)
    }
}

object ScreenEvents {
    fun parseCandidate(p: JsonObject): RemoteCandidate? {
        if (p["endOfCandidates"]?.jsonPrimitive?.booleanOrNull == true) return null
        val sdp = p["candidate"]?.jsonPrimitive?.content?.takeIf { it.isNotEmpty() } ?: return null
        return RemoteCandidate(sdp, p["sdpMid"]?.jsonPrimitive?.content, p["sdpMLineIndex"]?.jsonPrimitive?.intOrNull ?: 0)
    }
}
