package app.mybuddy.android

import app.mybuddy.android.core.stream.VideoGeometry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class VideoGeometryTest {
    private fun assertPoint(expected: Pair<Double, Double>, actual: Pair<Double, Double>?) {
        requireNotNull(actual) { "expected a point inside the picture" }
        assertEquals(expected.first, actual.first, 1e-6)
        assertEquals(expected.second, actual.second, 1e-6)
    }

    @Test
    fun fitWithMatchingAspectMapsCornersAndCenter() {
        // 1000×625 container shows a 16:10 frame exactly.
        assertPoint(0.5 to 0.5, VideoGeometry.frameCoordinates(500f, 312.5f, 1000f, 625f, 1.6f, fill = false))
        assertPoint(0.0 to 0.0, VideoGeometry.frameCoordinates(0f, 0f, 1000f, 625f, 1.6f, fill = false))
        assertPoint(1.0 to 1.0, VideoGeometry.frameCoordinates(1000f, 625f, 1000f, 625f, 1.6f, fill = false))
    }

    @Test
    fun fitInATallerContainerIgnoresTheLetterboxBars() {
        // Portrait phone: 1000×2000 container, 16:10 picture is 1000×625 in the middle (y 687.5…1312.5).
        assertNull(VideoGeometry.frameCoordinates(500f, 100f, 1000f, 2000f, 1.6f, fill = false))
        assertPoint(0.5 to 0.0, VideoGeometry.frameCoordinates(500f, 687.5f, 1000f, 2000f, 1.6f, fill = false))
        assertPoint(0.25 to 0.5, VideoGeometry.frameCoordinates(250f, 1000f, 1000f, 2000f, 1.6f, fill = false))
    }

    @Test
    fun fillCropsTheFrameToTheContainer() {
        // Landscape 2000×1000 (2:1) filled with a 16:10 frame: top/bottom cropped, visible height fraction 0.8.
        assertPoint(0.5 to 0.1, VideoGeometry.frameCoordinates(1000f, 0f, 2000f, 1000f, 1.6f, fill = true))
        assertPoint(0.0 to 0.9, VideoGeometry.frameCoordinates(0f, 1000f, 2000f, 1000f, 1.6f, fill = true))
    }

    @Test
    fun zoomAndPanAreUndone() {
        // 2× zoom about the center of a 1000×625 view: the view center is still the frame center…
        assertPoint(0.5 to 0.5, VideoGeometry.frameCoordinates(500f, 312.5f, 1000f, 625f, 1.6f, fill = false, scale = 2f))
        // …and the view's top-left corner shows the frame's point (0.25, 0.25).
        assertPoint(0.25 to 0.25, VideoGeometry.frameCoordinates(0f, 0f, 1000f, 625f, 1.6f, fill = false, scale = 2f))
        // Panning right by 250 px (at 2×) moves the view over the frame's left half.
        assertPoint(0.125 to 0.25, VideoGeometry.frameCoordinates(0f, 0f, 1000f, 625f, 1.6f, fill = false, scale = 2f, offsetX = 250f))
    }

    @Test
    fun degenerateInputsGiveNoPoint() {
        assertNull(VideoGeometry.frameCoordinates(1f, 1f, 0f, 100f, 1.6f, fill = false))
        assertNull(VideoGeometry.frameCoordinates(1f, 1f, 100f, 100f, 0f, fill = false))
    }
}
