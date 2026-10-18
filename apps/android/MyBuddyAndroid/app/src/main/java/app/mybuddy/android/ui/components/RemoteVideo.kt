package app.mybuddy.android.ui.components

import android.content.Context
import android.graphics.SurfaceTexture
import android.view.TextureView
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import app.mybuddy.android.core.stream.Trackpad
import app.mybuddy.android.core.stream.VideoGeometry
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.webrtc.EglBase
import org.webrtc.EglRenderer
import org.webrtc.GlRectDrawer
import org.webrtc.VideoFrame
import org.webrtc.VideoSink
import org.webrtc.VideoTrack
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Renders WebRTC frames into a TextureView (not a SurfaceView) so the picture can be zoomed and panned
 * with ordinary view/graphics-layer transforms. Drawing happens on libwebrtc's EGL render thread.
 */
class TextureViewRenderer(context: Context) : TextureView(context), TextureView.SurfaceTextureListener, VideoSink {
    private val egl = EglRenderer("MyBuddyRemote")
    private var initialized = false
    private var frameWidth = 0
    private var frameHeight = 0
    private var firstFrame = true
    var onVideoSize: ((Int, Int) -> Unit)? = null
    var onFirstFrame: (() -> Unit)? = null

    init {
        surfaceTextureListener = this
        isOpaque = false
    }

    fun init(context: EglBase.Context) {
        if (initialized) return
        egl.init(context, EglBase.CONFIG_PLAIN, GlRectDrawer())
        initialized = true
        surfaceTexture?.let { egl.createEglSurface(it) }
    }

    fun release() {
        if (!initialized) return
        initialized = false
        egl.release()
    }

    override fun onFrame(frame: VideoFrame) {
        val w = frame.rotatedWidth
        val h = frame.rotatedHeight
        if (w != frameWidth || h != frameHeight) {
            frameWidth = w
            frameHeight = h
            post { onVideoSize?.invoke(w, h) }
        }
        if (firstFrame) {
            firstFrame = false
            post { onFirstFrame?.invoke() }
        }
        egl.onFrame(frame)
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        super.onLayout(changed, left, top, right, bottom)
        // Crop (never stretch) the frame to this view's shape; for "fit" the view already has the video's shape.
        if (right > left && bottom > top) egl.setLayoutAspectRatio((right - left).toFloat() / (bottom - top))
    }

    override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) {
        if (initialized) egl.createEglSurface(surface)
    }

    override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) {}

    override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
        // The texture must not be drawn to after this returns.
        val done = CountDownLatch(1)
        egl.releaseEglSurface { done.countDown() }
        done.await(1, TimeUnit.SECONDS)
        return true
    }

    override fun onSurfaceTextureUpdated(surface: SurfaceTexture) {}
}

/** How touches on the picture behave. */
enum class InputMode {
    /** Touches only zoom and pan the view; nothing reaches the Mac. */
    VIEW,
    /** The pointer jumps to the finger: tap clicks there, long-press right-clicks, drag moves, two fingers scroll. */
    TOUCH,
    /** Like a laptop trackpad: drag moves the pointer relatively, tap clicks at the pointer, hold-then-drag drags. */
    TRACKPAD,
}

/** A gesture for the Mac. Positions are normalized frame coordinates (0…1, top-left). */
sealed interface ControlGesture {
    data class Tap(val x: Double, val y: Double) : ControlGesture
    data class DoubleTap(val x: Double, val y: Double) : ControlGesture
    data class LongPress(val x: Double, val y: Double) : ControlGesture
    data class Move(val x: Double, val y: Double) : ControlGesture
    data class Scroll(val dx: Double, val dy: Double) : ControlGesture
    /** Trackpad: relative pointer movement (normalized). */
    data class MoveBy(val dx: Double, val dy: Double) : ControlGesture
    /** Trackpad: a click at the current pointer. */
    data class PointerClick(val button: String, val action: String) : ControlGesture
    /** Trackpad: hold-to-drag — left button down / up at the pointer. */
    data class PointerButton(val down: Boolean) : ControlGesture
    /** Three fingers, either control mode: Spaces / Mission Control / App windows. */
    data class Swipe(val direction: Trackpad.Swipe) : ControlGesture
}

/**
 * The remote screen. VIEW only changes the view (pinch to zoom, drag to pan when zoomed, double-tap to reset) and
 * never reaches the Mac. TOUCH and TRACKPAD (offered only when the Mac granted `input.control`) send input; the modes
 * never mix, so zooming in VIEW can't click by accident. [pointer] draws the Mac pointer where MyBuddy last put it.
 */
@Composable
fun RemoteVideo(
    track: VideoTrack?,
    eglContext: EglBase.Context,
    videoAspect: Float,
    fill: Boolean,
    modifier: Modifier = Modifier,
    mode: InputMode = InputMode.VIEW,
    pointer: Pair<Double, Double>? = null,
    onControl: (ControlGesture) -> Unit = {},
    onVideoSize: (Int, Int) -> Unit = { _, _ -> },
    onFirstFrame: () -> Unit = {},
) {
    val context = LocalContext.current
    val renderer = remember { TextureViewRenderer(context) }
    renderer.onVideoSize = onVideoSize
    renderer.onFirstFrame = onFirstFrame
    DisposableEffect(renderer) {
        renderer.init(eglContext)
        onDispose { renderer.release() }
    }
    DisposableEffect(track, renderer) {
        track?.addSink(renderer)
        onDispose { track?.removeSink(renderer) }
    }
    var scale by remember { mutableFloatStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    val scope = rememberCoroutineScope()
    val pendingTap = remember { arrayOfNulls<Job>(1) }
    val density = LocalDensity.current
    val haptic = LocalHapticFeedback.current
    val swipeDistance = with(density) { 60.dp.toPx() }

    fun zoomBy(factor: Float, width: Float, height: Float) {
        scale = (scale * factor).coerceIn(1f, 5f)
        val maxX = (scale - 1f) * width / 2f
        val maxY = (scale - 1f) * height / 2f
        offset = Offset(offset.x.coerceIn(-maxX, maxX), offset.y.coerceIn(-maxY, maxY))
    }

    fun singleOrDouble(single: () -> Unit, double: () -> Unit) {
        if (pendingTap[0]?.isActive == true) {
            // Second tap within the window: one double-click instead of two clicks.
            pendingTap[0]?.cancel()
            double()
        } else {
            pendingTap[0] = scope.launch {
                delay(250)
                single()
            }
        }
    }

    val gestures = when (mode) {
        InputMode.TOUCH -> Modifier
            .semantics { contentDescription = "Your Mac’s screen. Touch control: tap to click, long-press to right-click, drag to move the pointer, two fingers to scroll, three fingers to switch spaces." }
            .pointerInput(fill, videoAspect, mode) {
                val slop = viewConfiguration.touchSlop
                fun map(p: Offset) = VideoGeometry.frameCoordinates(p.x, p.y, size.width.toFloat(), size.height.toFloat(), videoAspect, fill, scale, offset.x, offset.y)
                awaitEachGesture {
                    val down = awaitFirstDown()
                    val started = System.currentTimeMillis()
                    var last = down.position
                    var travelled = 0f
                    var maxPointers = 1
                    var lastCentroid: Offset? = null
                    var threeStart: Offset? = null
                    var swiped = false
                    do {
                        val event = awaitPointerEvent()
                        val pressed = event.changes.filter { it.pressed }
                        maxPointers = max(maxPointers, pressed.size)
                        if (pressed.size >= 3) {
                            val c = centroid(pressed.map { it.position })
                            val start = threeStart ?: c.also { threeStart = it }
                            if (!swiped) Trackpad.classifySwipe(c.x - start.x, c.y - start.y, swipeDistance)?.let { swiped = true; onControl(ControlGesture.Swipe(it)) }
                        } else if (pressed.size == 2 && maxPointers == 2) {
                            val c = centroid(pressed.map { it.position })
                            lastCentroid?.let { lc ->
                                val d = c - lc
                                if (abs(d.x) > 0.5f || abs(d.y) > 0.5f) onControl(ControlGesture.Scroll(-d.x * 2.0, -d.y * 2.0))
                            }
                            lastCentroid = c
                        } else if (pressed.size == 1 && maxPointers == 1) {
                            val p = pressed[0].position
                            travelled += (p - last).getDistance()
                            last = p
                            if (travelled > slop) map(p)?.let { onControl(ControlGesture.Move(it.first, it.second)) }
                        }
                        event.changes.forEach { it.consume() }
                    } while (event.changes.any { it.pressed })
                    if (maxPointers == 1 && travelled <= slop) {
                        val point = map(down.position) ?: return@awaitEachGesture
                        if (System.currentTimeMillis() - started > 500) {
                            onControl(ControlGesture.LongPress(point.first, point.second))
                        } else {
                            singleOrDouble({ onControl(ControlGesture.Tap(point.first, point.second)) },
                                { onControl(ControlGesture.DoubleTap(point.first, point.second)) })
                        }
                    }
                }
            }
        InputMode.TRACKPAD -> Modifier
            .semantics { contentDescription = "Your Mac’s screen. Trackpad: drag to move the pointer, tap to click, hold then drag to drag, two-finger tap to right-click, two fingers to scroll, three fingers to switch spaces." }
            .pointerInput(fill, videoAspect, mode) {
                val slop = viewConfiguration.touchSlop
                val pinchSlop = with(density) { 24.dp.toPx() }
                awaitEachGesture {
                    val down = awaitFirstDown()
                    val startedAt = down.uptimeMillis
                    var last = down.position
                    var lastTime = down.uptimeMillis
                    var endedAt = down.uptimeMillis
                    var travelled = 0f
                    var maxPointers = 1
                    var dragging = false
                    var twoStart: Offset? = null
                    var twoLast: Offset? = null
                    var twoStartDist = 0f
                    var twoLastDist = 0f
                    var twoMode = 0 // 0 undecided · 1 scroll · 2 pinch (zooms the view)
                    var threeStart: Offset? = null
                    var swiped = false
                    // Holding still before moving starts a drag (left button held); a buzz says so.
                    var pending = withTimeoutOrNull(HOLD_TO_DRAG_MS) { awaitPointerEvent() }
                    if (pending == null) {
                        dragging = true
                        haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                        onControl(ControlGesture.PointerButton(true))
                    }
                    while (true) {
                        val event = pending ?: awaitPointerEvent()
                        pending = null
                        val pressed = event.changes.filter { it.pressed }
                        maxPointers = max(maxPointers, pressed.size)
                        event.changes.firstOrNull()?.let { endedAt = it.uptimeMillis }
                        when {
                            pressed.size >= 3 -> {
                                val c = centroid(pressed.map { it.position })
                                val start = threeStart ?: c.also { threeStart = it }
                                if (!swiped) Trackpad.classifySwipe(c.x - start.x, c.y - start.y, swipeDistance)?.let { swiped = true; onControl(ControlGesture.Swipe(it)) }
                            }
                            pressed.size == 2 && maxPointers == 2 -> {
                                val c = centroid(pressed.map { it.position })
                                val dist = (pressed[0].position - pressed[1].position).getDistance()
                                if (twoStart == null) {
                                    twoStart = c; twoLast = c; twoStartDist = dist; twoLastDist = dist
                                } else {
                                    if (twoMode == 0) {
                                        if (abs(dist - twoStartDist) > pinchSlop) twoMode = 2
                                        else if ((c - twoStart!!).getDistance() > slop) twoMode = 1
                                    }
                                    when (twoMode) {
                                        1 -> {
                                            val d = c - twoLast!!
                                            if (abs(d.x) > 0.5f || abs(d.y) > 0.5f) onControl(ControlGesture.Scroll(-d.x * 2.0, -d.y * 2.0))
                                        }
                                        2 -> if (twoLastDist > 0f) zoomBy(dist / twoLastDist, size.width.toFloat(), size.height.toFloat())
                                    }
                                    twoLast = c
                                    twoLastDist = dist
                                }
                            }
                            pressed.size == 1 && maxPointers == 1 -> {
                                val ch = pressed[0]
                                val d = ch.position - last
                                // Still (within slop) until now and held long enough: this movement drags.
                                if (!dragging && travelled <= slop && ch.uptimeMillis - startedAt > HOLD_TO_DRAG_MS) {
                                    dragging = true
                                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                    onControl(ControlGesture.PointerButton(true))
                                }
                                travelled += d.getDistance()
                                if (travelled > slop || dragging) {
                                    val (dx, dy) = Trackpad.delta(d.x, d.y, ch.uptimeMillis - lastTime, size.width.toFloat(), videoAspect)
                                    if (dx != 0.0 || dy != 0.0) onControl(ControlGesture.MoveBy(dx, dy))
                                }
                                last = ch.position
                                lastTime = ch.uptimeMillis
                            }
                        }
                        event.changes.forEach { it.consume() }
                        if (event.changes.none { it.pressed }) break
                    }
                    when {
                        dragging -> onControl(ControlGesture.PointerButton(false))
                        maxPointers == 1 && travelled <= slop -> singleOrDouble(
                            { onControl(ControlGesture.PointerClick("left", "click")) },
                            { onControl(ControlGesture.PointerClick("left", "doubleClick")) })
                        maxPointers == 2 && twoMode == 0 && endedAt - startedAt < 300 -> onControl(ControlGesture.PointerClick("right", "click"))
                    }
                }
            }
        InputMode.VIEW -> Modifier
            .semantics { contentDescription = "Your Mac’s screen, live. Pinch to zoom, double-tap to reset." }
            .pointerInput(Unit) {
                detectTransformGestures { _, pan, zoom, _ ->
                    scale = (scale * zoom).coerceIn(1f, 5f)
                    val maxX = (scale - 1f) * size.width / 2f
                    val maxY = (scale - 1f) * size.height / 2f
                    offset = Offset((offset.x + pan.x).coerceIn(-maxX, maxX), (offset.y + pan.y).coerceIn(-maxY, maxY))
                }
            }
            .pointerInput(Unit) {
                detectTapGestures(onDoubleTap = {
                    scale = 1f
                    offset = Offset.Zero
                })
            }
    }
    BoxWithConstraints(modifier.then(gestures), contentAlignment = Alignment.Center) {
        val sized = if (fill) Modifier.fillMaxSize() else Modifier.aspectRatio(videoAspect.coerceIn(0.2f, 5f), matchHeightConstraintsFirst = maxWidth / maxHeight > videoAspect)
        Box(sized.graphicsLayer {
            scaleX = scale
            scaleY = scale
            translationX = offset.x
            translationY = offset.y
        }) {
            AndroidView(factory = { renderer }, modifier = Modifier.fillMaxSize())
        }
        if (mode != InputMode.VIEW && pointer != null) {
            val w = constraints.maxWidth.toFloat()
            val h = constraints.maxHeight.toFloat()
            // While zoomed, keep the pointer in view by panning towards it.
            LaunchedEffect(pointer, scale) {
                if (scale <= 1f) return@LaunchedEffect
                val at = VideoGeometry.viewCoordinates(pointer.first, pointer.second, w, h, videoAspect, fill, scale, offset.x, offset.y) ?: return@LaunchedEffect
                val margin = 0.12f * minOf(w, h)
                val shiftX = when { at.first < margin -> margin - at.first; at.first > w - margin -> (w - margin) - at.first; else -> 0f }
                val shiftY = when { at.second < margin -> margin - at.second; at.second > h - margin -> (h - margin) - at.second; else -> 0f }
                if (shiftX != 0f || shiftY != 0f) {
                    val maxX = (scale - 1f) * w / 2f
                    val maxY = (scale - 1f) * h / 2f
                    offset = Offset((offset.x + shiftX).coerceIn(-maxX, maxX), (offset.y + shiftY).coerceIn(-maxY, maxY))
                }
            }
            VideoGeometry.viewCoordinates(pointer.first, pointer.second, w, h, videoAspect, fill, scale, offset.x, offset.y)?.let { (px, py) ->
                if (px in 0f..w && py in 0f..h) {
                    val big = mode == InputMode.TRACKPAD
                    Canvas(Modifier.align(Alignment.TopStart).offset { IntOffset(px.roundToInt(), py.roundToInt()) }.size(if (big) 26.dp else 18.dp)) {
                        drawPointer(this.size.width)
                    }
                }
            }
        }
    }
}

/** Trackpad: how long a finger rests before movement drags (left button held) instead of just moving. */
private const val HOLD_TO_DRAG_MS = 450L

private fun centroid(points: List<Offset>): Offset = points.reduce { a, b -> a + b } / points.size.toFloat()

/** A classic arrow pointer, tip at the top-left corner, white with a dark outline (visible on any background). */
private fun DrawScope.drawPointer(boxSize: Float) {
    val u = boxSize / 20f
    val arrow = Path().apply {
        moveTo(0f, 0f)
        lineTo(0f, 17f * u)
        lineTo(4.5f * u, 13f * u)
        lineTo(7.5f * u, 19.5f * u)
        lineTo(10.2f * u, 18.3f * u)
        lineTo(7.3f * u, 12f * u)
        lineTo(13f * u, 12f * u)
        close()
    }
    drawPath(arrow, Color.White)
    drawPath(arrow, Color.Black, style = Stroke(width = 1.4f * u))
}
