package app.mybuddy.android

import app.mybuddy.android.core.stream.InboundStatsParser
import app.mybuddy.android.core.stream.LiveTyping
import app.mybuddy.android.core.stream.StatsEntry
import app.mybuddy.android.core.stream.Trackpad
import app.mybuddy.android.core.stream.VideoGeometry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TrackpadTest {
    @Test
    fun accelerationIsPreciseWhenSlowAndFastWhenFlicked() {
        assertEquals(0.8, Trackpad.gain(0.05f), 1e-9)
        assertEquals(2.6, Trackpad.gain(5f), 1e-9)
        assertTrue(Trackpad.gain(0.5f) < Trackpad.gain(1.5f))
    }

    @Test
    fun movementUsesOnePhysicalScaleForBothAxes() {
        // A slow 100 px move on a 1000 px-wide view over a 16:10 Mac.
        val (dx, dy) = Trackpad.delta(100f, 100f, 1000, 1000f, 1.6f)
        assertEquals(0.08, dx, 1e-6)
        assertEquals(0.128, dy, 1e-6) // y spans the shorter side, so the same finger distance is a larger fraction
        val (fastX, _) = Trackpad.delta(100f, 0f, 10, 1000f, 1.6f)
        assertTrue("a flick moves further", fastX > dx)
        assertEquals(0.0 to 0.0, Trackpad.delta(10f, 10f, 16, 0f, 1.6f))
    }

    @Test
    fun threeFingerSwipesMapToMacShortcuts() {
        assertNull(Trackpad.classifySwipe(30f, 0f, 80f))
        assertNull("too diagonal", Trackpad.classifySwipe(100f, 90f, 80f))
        assertEquals(Trackpad.Swipe.LEFT, Trackpad.classifySwipe(-120f, 10f, 80f))
        assertEquals(Trackpad.Swipe.UP, Trackpad.classifySwipe(5f, -150f, 80f))
        // Swiping left shows the Space on the right, as on a Mac trackpad.
        assertEquals("ArrowRight" to listOf("control"), Trackpad.shortcut(Trackpad.Swipe.LEFT))
        assertEquals("ArrowUp" to listOf("control"), Trackpad.shortcut(Trackpad.Swipe.UP))
    }

    @Test
    fun liveTypingSendsBackspacesThenTheNewText() {
        assertEquals(0 to "c", Trackpad.typingDiff("ab", "abc"))
        assertEquals(1 to "", Trackpad.typingDiff("abc", "ab"))
        assertEquals(2 to "here", Trackpad.typingDiff("hi teh", "hi there")) // autocorrect replaced a word: minimal edit
    }

    @Test
    fun liveKeyboardKeepsASentinelSoBackspaceOnAnEmptyFieldReachesTheMac() {
        val z = LiveTyping.SENTINEL
        assertEquals(LiveTyping.Step(0, "h", z + "h"), LiveTyping.step(z, z + "h"))
        assertEquals(LiveTyping.Step(1, "", z), LiveTyping.step(z + "h", z))
        assertEquals("backspace on the empty field", LiveTyping.Step(1, "", z), LiveTyping.step(z, ""))
        assertEquals("select-all + delete removes what was typed", LiveTyping.Step(3, "", z), LiveTyping.step(z + "abc", ""))
        val long = "x".repeat(201)
        assertEquals(LiveTyping.Step(0, "x", z), LiveTyping.step(z + long.drop(1), z + long))
    }

    @Test
    fun pointerPositionsRoundTripThroughTheView() {
        for (fill in listOf(false, true)) {
            val view = VideoGeometry.viewCoordinates(0.25, 0.75, 1080f, 2000f, 1.6f, fill, scale = 1.5f, offsetX = 40f, offsetY = -30f)
            assertNotNull(view)
            val back = VideoGeometry.frameCoordinates(view!!.first, view.second, 1080f, 2000f, 1.6f, fill, 1.5f, 40f, -30f)
            assertNotNull("fill=$fill", back)
            assertEquals(0.25, back!!.first, 1e-4)
            assertEquals(0.75, back.second, 1e-4)
        }
    }

    @Test
    fun statsReportJitterDelayDecodeTimeAndFreezes() {
        fun rtp(t: Double, delay: Double, emitted: Double, decode: Double, decoded: Double) = StatsEntry("R", "inbound-rtp", t,
            mapOf("kind" to "video", "bytesReceived" to t, "jitterBufferDelay" to delay, "jitterBufferEmittedCount" to emitted,
                "totalDecodeTime" to decode, "framesDecoded" to decoded, "freezeCount" to 2))
        val p = InboundStatsParser()
        assertNull(p.sample(listOf(rtp(1e6, 1.0, 50.0, 0.1, 50.0))).jitterBufferMs)
        val s = p.sample(listOf(rtp(2e6, 4.0, 80.0, 0.25, 80.0)))
        assertEquals(100.0, s.jitterBufferMs!!, 1e-6) // 3 s over 30 frames
        assertEquals(5.0, s.decodeMs!!, 1e-6)         // 0.15 s over 30 frames
        assertEquals(2L, s.freezeCount)
    }
}
