package app.mybuddy.android

import app.mybuddy.android.core.stream.CandidateBuffer
import app.mybuddy.android.core.stream.HostStreamState
import app.mybuddy.android.core.stream.InboundStatsParser
import app.mybuddy.android.core.stream.MediaPath
import app.mybuddy.android.core.stream.RemoteCandidate
import app.mybuddy.android.core.stream.ScreenEvents
import app.mybuddy.android.core.stream.StatsEntry
import app.mybuddy.android.core.stream.StreamPhase
import app.mybuddy.android.core.stream.StreamStats
import app.mybuddy.android.core.stream.StreamText
import app.mybuddy.android.core.stream.StreamUi
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class ScreenStreamTest {
    private fun fixturePayload(name: String) =
        Json.parseToJsonElement(File(repoRoot(), "protocol/fixtures/valid/$name.json").readText()).jsonObject.getValue("payload").jsonObject

    private fun repoRoot(): File {
        var dir: File? = File("").absoluteFile
        while (dir != null && !File(dir, "protocol/schema/events.v1.json").exists()) dir = dir.parentFile
        return dir ?: error("repository root not found")
    }

    @Test
    fun parsesLiveStateFromTheSharedFixture() {
        val h = HostStreamState.parse(fixturePayload("screen.state.live"))
        assertEquals("live", h.state)
        assertEquals(1280, h.width)
        assertEquals(800, h.height)
        assertEquals("balanced", h.tier)
        assertEquals("display", h.source)
        assertEquals(1, h.displays.size)
        assertTrue(h.displays[0].main)
        assertEquals("Built-in Retina Display", h.displays[0].name)
    }

    @Test
    fun failedStateCarriesReasonAndFriendlyText() {
        val h = HostStreamState.parse(fixturePayload("screen.state.failed"))
        assertEquals("not_authorized", h.reason)
        assertTrue(StreamText.reason(h.reason, h.message).contains("Screen Recording"))
        // Unknown reasons fall back to the Mac's message.
        assertEquals("Something new happened", StreamText.reason("future_reason", "Something new happened"))
        assertEquals("Screen sharing stopped.", StreamText.reason(null, null))
    }

    @Test
    fun activePhasesAreExactlyTheOnesWithAStreamInFlight() {
        val active = StreamPhase.entries.filter { StreamUi(it).isActive }.toSet()
        assertEquals(setOf(StreamPhase.Requesting, StreamPhase.Starting, StreamPhase.AwaitingSelection, StreamPhase.Connecting, StreamPhase.Live, StreamPhase.Reconnecting), active)
    }

    private fun inbound(bytes: Double, us: Double, local: String = "host", remote: String = "host") = listOf(
        StatsEntry("IT1", "inbound-rtp", us, mapOf("kind" to "video", "bytesReceived" to bytes, "framesPerSecond" to 29.0, "frameWidth" to 1280L,
            "frameHeight" to 800L, "codecId" to "C1", "decoderImplementation" to "MediaCodec", "powerEfficientDecoder" to true, "packetsLost" to 2L,
            "framesDecoded" to 300L)),
        StatsEntry("C1", "codec", us, mapOf("mimeType" to "video/H264")),
        StatsEntry("T1", "transport", us, mapOf("selectedCandidatePairId" to "CP1")),
        StatsEntry("CP1", "candidate-pair", us, mapOf("localCandidateId" to "L1", "remoteCandidateId" to "R1", "currentRoundTripTime" to 0.008,
            "state" to "succeeded", "nominated" to true)),
        StatsEntry("L1", "local-candidate", us, mapOf("candidateType" to local)),
        StatsEntry("R1", "remote-candidate", us, mapOf("candidateType" to remote)),
    )

    @Test
    fun parsesInboundVideoStatsAndBitrateOverTheRealInterval() {
        val parser = InboundStatsParser()
        assertNull(parser.sample(inbound(1_000_000.0, 1_000_000.0)).bitrateKbps)
        val s = parser.sample(inbound(1_500_000.0, 3_000_000.0))
        assertEquals(2000.0, s.bitrateKbps!!, 0.001)
        assertEquals(29.0, s.fps!!, 0.0)
        assertEquals(1280, s.width)
        assertEquals("H264", s.codec)
        assertEquals("MediaCodec", s.implementation)
        assertEquals(true, s.hardwareAccelerated)
        assertEquals(8.0, s.rttMs!!, 1e-9)
        assertEquals(MediaPath.Direct, s.path)
        assertEquals(2L, s.packetsLost)
        assertEquals("1280×800 · 29 fps · H264 (hardware) · 2.0 Mbps", StreamText.summary(s))
    }

    @Test
    fun relayAndUnknownPaths() {
        assertEquals(MediaPath.Relayed, InboundStatsParser().sample(inbound(1.0, 1.0, local = "relay")).path)
        assertEquals(MediaPath.Unknown, InboundStatsParser().sample(listOf(StatsEntry("x", "inbound-rtp", 1.0, mapOf("kind" to "video")))).path)
        assertEquals("—", StreamText.path(null))
        assertEquals("measuring…", StreamText.summary(StreamStats()))
    }

    @Test
    fun candidatesWaitForTheOfferAndTheBufferIsBounded() {
        val buffer = CandidateBuffer(limit = 3)
        val c = RemoteCandidate("candidate:1 1 udp 1 192.168.1.2 5000 typ host", "0", 0)
        repeat(5) { assertFalse(buffer.offer(c)) }
        assertEquals(3, buffer.size)
        assertEquals(3, buffer.drain().size)
        assertTrue("after the offer is applied, candidates go straight in", buffer.offer(c))
        buffer.reset()
        assertFalse(buffer.offer(c))
    }

    @Test
    fun candidatesBeforeTheOfferSurviveAndIceRestartsKeepGenerationsApart() {
        fun cand(port: Int, ufrag: String) = RemoteCandidate("candidate:1 1 udp 2122260223 192.168.1.20 $port typ host generation 0 ufrag $ufrag network-id 1", "0", 0)
        val buffer = CandidateBuffer()
        // The Mac's first candidates can beat its offer: they must wait, not vanish when the offer is applied.
        assertFalse(buffer.offer(cand(5000, "aaaa")))
        buffer.hold()
        assertEquals(listOf(cand(5000, "aaaa")), buffer.drain(CandidateBuffer.ufragOfSdp("v=0\r\na=ice-ufrag:aaaa\r\na=ice-pwd:x\r\n")))
        assertTrue(buffer.offer(cand(5001, "aaaa")))
        // ICE restart: the new generation's candidates arrive before the new offer and wait for it.
        assertFalse(buffer.offer(cand(6000, "bbbb")))
        buffer.hold()
        assertEquals(listOf(cand(6000, "bbbb")), buffer.drain("bbbb"))
        assertFalse("a late candidate of the retired generation is dropped", buffer.offer(cand(5002, "aaaa")))
        assertEquals(0, buffer.size)
        assertTrue(buffer.offer(cand(6001, "bbbb")))
        assertEquals("aaaa", CandidateBuffer.ufragOf(cand(1, "aaaa").sdp))
    }

    @Test
    fun parsesCandidatesAndIgnoresEndOfCandidates() {
        val ice = fixturePayload("webrtc.ice")
        val c = ScreenEvents.parseCandidate(ice)!!
        assertEquals("0", c.sdpMid)
        assertEquals(0, c.sdpMLineIndex)
        assertTrue(c.sdp.startsWith("candidate:"))
        assertNull(ScreenEvents.parseCandidate(fixturePayload("webrtc.ice.end")))
    }
}
