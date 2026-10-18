package app.mybuddy.android.core.stream

import kotlin.math.abs
import kotlin.math.hypot

/**
 * Trackpad-mode maths (pure, unit-tested): finger movement → relative pointer movement in the streamed frame's
 * normalized coordinates, and three-finger swipes → the macOS shortcuts a real trackpad gesture triggers.
 */
object Trackpad {
    enum class Swipe { LEFT, RIGHT, UP, DOWN }

    /**
     * Pointer acceleration like a laptop trackpad: slow movements stay precise (0.8×), fast flicks cross the screen
     * (up to 2.6×). [speedPxPerMs] is the finger speed in phone pixels per millisecond.
     */
    fun gain(speedPxPerMs: Float): Double {
        val t = ((speedPxPerMs - 0.15f) / 2.0f).coerceIn(0f, 1f).toDouble()
        return 0.8 + 1.8 * t
    }

    /**
     * Normalized (0…1) pointer delta for a finger move of [dxPx]/[dyPx] over [dtMs] on a view [viewWidthPx] wide, for a
     * Mac screen with aspect ratio [macAspect] (width / height). A full-width slow swipe moves the pointer across 80 %
     * of the Mac's width; vertical movement uses the same physical scale (hence × aspect, as y spans the shorter side).
     */
    fun delta(dxPx: Float, dyPx: Float, dtMs: Long, viewWidthPx: Float, macAspect: Float, sensitivity: Double = 1.0): Pair<Double, Double> {
        if (viewWidthPx <= 0f || macAspect <= 0f) return 0.0 to 0.0
        val speed = hypot(dxPx, dyPx) / dtMs.coerceAtLeast(1L).toFloat()
        val k = gain(speed) * sensitivity / viewWidthPx
        return dxPx * k to dyPx * k * macAspect
    }

    /** The dominant direction of a three-finger movement, or null while it is too short or too diagonal. */
    fun classifySwipe(dxPx: Float, dyPx: Float, minDistancePx: Float): Swipe? {
        val ax = abs(dxPx)
        val ay = abs(dyPx)
        if (maxOf(ax, ay) < minDistancePx) return null
        return when {
            ax >= ay * 1.5f -> if (dxPx < 0) Swipe.LEFT else Swipe.RIGHT
            ay >= ax * 1.5f -> if (dyPx < 0) Swipe.UP else Swipe.DOWN
            else -> null
        }
    }

    /**
     * macOS default shortcuts for three-finger swipes: swiping left moves to the Space on the right (Ctrl+→), right
     * to the one on the left (Ctrl+←), up opens Mission Control (Ctrl+↑), down shows the app's windows (Ctrl+↓).
     */
    fun shortcut(s: Swipe): Pair<String, List<String>> = when (s) {
        Swipe.LEFT -> "ArrowRight" to listOf("control")
        Swipe.RIGHT -> "ArrowLeft" to listOf("control")
        Swipe.UP -> "ArrowUp" to listOf("control")
        Swipe.DOWN -> "ArrowDown" to listOf("control")
    }

    /**
     * Live typing from a phone text field: what to send so the Mac matches the edit from [old] to [new] — the number of
     * Backspaces for removed characters after the common prefix, then the inserted text.
     */
    fun typingDiff(old: String, new: String): Pair<Int, String> {
        var prefix = 0
        val max = minOf(old.length, new.length)
        while (prefix < max && old[prefix] == new[prefix]) prefix++
        return (old.length - prefix) to new.substring(prefix)
    }
}

/**
 * Live typing through a phone text field (full-screen keyboard). The field always starts with an invisible
 * [SENTINEL], so Backspace on an "empty" field still has something to delete and reaches the Mac.
 */
object LiveTyping {
    const val SENTINEL = "​"
    private const val MAX_BUFFER = 200

    /** Send [backspaces] Backspaces then [text] to the Mac; the field should then hold [keep]. */
    data class Step(val backspaces: Int, val text: String, val keep: String)

    fun step(old: String, new: String): Step {
        val before = old.removePrefix(SENTINEL)
        if (!new.startsWith(SENTINEL)) {
            // The sentinel itself went: Backspace on an empty field (or everything was selected and replaced).
            val visible = new.replace(SENTINEL, "")
            val (backspaces, text) = Trackpad.typingDiff(before, visible)
            return Step(if (before.isEmpty() && visible.isEmpty()) 1 else backspaces, text, SENTINEL + visible)
        }
        val after = new.removePrefix(SENTINEL).replace(SENTINEL, "")
        val (backspaces, text) = Trackpad.typingDiff(before, after)
        // A long run without Enter: start a fresh buffer (nothing is sent for that).
        return Step(backspaces, text, if (after.length > MAX_BUFFER) SENTINEL else new)
    }
}
