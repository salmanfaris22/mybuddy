package app.mybuddy.android.core.stream

/**
 * Maps a touch on the remote-screen view to normalized coordinates in the streamed frame (0…1, top-left),
 * the coordinate space of `input.*` (PROTOCOL §5.3). Mirrors how the picture is laid out in `RemoteVideo`:
 * *fit* letterboxes a box with the video's aspect ratio in the middle of the container, *fill* uses the whole
 * container and libwebrtc center-crops the frame to it; the zoom/pan transform (scale around the center, then
 * translation) is undone first. Returns null for a touch outside the picture (letterbox bars).
 */
object VideoGeometry {
    fun frameCoordinates(
        touchX: Float, touchY: Float,
        containerWidth: Float, containerHeight: Float,
        videoAspect: Float, fill: Boolean,
        scale: Float = 1f, offsetX: Float = 0f, offsetY: Float = 0f,
    ): Pair<Double, Double>? {
        if (containerWidth <= 0f || containerHeight <= 0f || videoAspect <= 0f || scale <= 0f) return null
        val containerAspect = containerWidth / containerHeight
        val (boxW, boxH) = when {
            fill -> containerWidth to containerHeight
            containerAspect > videoAspect -> containerHeight * videoAspect to containerHeight
            else -> containerWidth to containerWidth / videoAspect
        }
        // Undo the graphics-layer transform (scale about the center, then offset).
        val localX = (touchX - containerWidth / 2f - offsetX) / scale + boxW / 2f
        val localY = (touchY - containerHeight / 2f - offsetY) / scale + boxH / 2f
        var nx = localX / boxW.toDouble()
        var ny = localY / boxH.toDouble()
        if (fill) {
            // libwebrtc center-crops the frame to the container's shape.
            if (containerAspect > videoAspect) ny = 0.5 + (ny - 0.5) * (videoAspect / containerAspect)
            else nx = 0.5 + (nx - 0.5) * (containerAspect / videoAspect)
        }
        if (nx !in 0.0..1.0 || ny !in 0.0..1.0) return null
        return nx to ny
    }

    /**
     * The inverse of [frameCoordinates]: where a normalized frame point appears in the view (for drawing the Mac
     * pointer over the picture). May lie outside the container when zoomed or cropped by *fill*.
     */
    fun viewCoordinates(
        frameX: Double, frameY: Double,
        containerWidth: Float, containerHeight: Float,
        videoAspect: Float, fill: Boolean,
        scale: Float = 1f, offsetX: Float = 0f, offsetY: Float = 0f,
    ): Pair<Float, Float>? {
        if (containerWidth <= 0f || containerHeight <= 0f || videoAspect <= 0f || scale <= 0f) return null
        val containerAspect = containerWidth / containerHeight
        val (boxW, boxH) = when {
            fill -> containerWidth to containerHeight
            containerAspect > videoAspect -> containerHeight * videoAspect to containerHeight
            else -> containerWidth to containerWidth / videoAspect
        }
        var nx = frameX
        var ny = frameY
        if (fill) {
            if (containerAspect > videoAspect) ny = 0.5 + (ny - 0.5) / (videoAspect / containerAspect)
            else nx = 0.5 + (nx - 0.5) / (containerAspect / videoAspect)
        }
        val localX = (nx * boxW).toFloat()
        val localY = (ny * boxH).toFloat()
        return ((localX - boxW / 2f) * scale + containerWidth / 2f + offsetX) to ((localY - boxH / 2f) * scale + containerHeight / 2f + offsetY)
    }
}
