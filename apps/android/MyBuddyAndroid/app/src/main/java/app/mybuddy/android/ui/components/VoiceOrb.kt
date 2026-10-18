package app.mybuddy.android.ui.components

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.mybuddy.android.ui.theme.LocalReduceMotion
import app.mybuddy.android.ui.theme.MB

enum class OrbPhase { Idle, Listening, Thinking, Speaking, Error }

/** MyBuddy Voice orb: soft core + level-reactive rings; static ring under Reduce Motion. */
@Composable
fun VoiceOrb(phase: OrbPhase, level: Float, modifier: Modifier = Modifier, size: Dp = 220.dp) {
    val reduce = LocalReduceMotion.current
    val tint = when (phase) {
        OrbPhase.Idle -> MB.textSecondary
        OrbPhase.Listening -> MB.accent
        OrbPhase.Thinking, OrbPhase.Speaking -> MB.info
        OrbPhase.Error -> MB.danger
    }
    val lvl by animateFloatAsState(level.coerceIn(0f, 1f), tween(if (reduce) 0 else 90), label = "level")
    val transition = rememberInfiniteTransition(label = "orb")
    val breathe by transition.animateFloat(0f, 1f, infiniteRepeatable(tween(if (phase == OrbPhase.Speaking) 600 else 2200), RepeatMode.Reverse), label = "breathe")
    val spin by transition.animateFloat(0f, 360f, infiniteRepeatable(tween(1200, easing = LinearEasing)), label = "spin")
    val b = if (reduce) 0f else breathe
    val description = when (phase) {
        OrbPhase.Idle -> "Voice assistant idle"
        OrbPhase.Listening -> "Listening"
        OrbPhase.Thinking -> "Working on it"
        OrbPhase.Speaking -> "Speaking"
        OrbPhase.Error -> "Voice error"
    }
    Canvas(modifier.size(size).semantics { contentDescription = description }) {
        val c = center
        val r = this.size.minDimension / 2
        if (reduce) {
            drawCircle(Brush.radialGradient(listOf(tint.copy(alpha = 0.35f), MB.elevated), c, r), r * 0.9f, c)
            drawCircle(tint, r * 0.9f, c, style = Stroke(width = 2.dp.toPx() + 10.dp.toPx() * lvl))
            return@Canvas
        }
        for (i in 0 until 3) {
            val base = 0.62f + i * 0.13f
            val wobble = when (phase) {
                OrbPhase.Listening -> lvl * 0.10f * (1 - i * 0.25f)
                OrbPhase.Speaking -> 0.04f * b
                else -> 0.015f * b
            }
            drawCircle(tint.copy(alpha = 0.22f - i * 0.06f), r * (base + wobble), c, style = Stroke(1.5.dp.toPx()))
        }
        val glow = 0.78f + if (phase == OrbPhase.Listening) lvl * 0.12f else 0.04f * b
        drawCircle(Brush.radialGradient(listOf(tint.copy(alpha = 0.55f), tint.copy(alpha = 0.12f), Color.Transparent), c, r * 0.84f * glow), r * 0.84f * glow, c)
        val coreR = r * 0.34f * (1 + if (phase == OrbPhase.Listening) lvl * 0.08f else 0.02f * b)
        val alpha = if (phase == OrbPhase.Idle) 0.55f else 0.95f
        drawCircle(Brush.linearGradient(listOf(MB.accent.copy(alpha = alpha), MB.info.copy(alpha = alpha * 0.95f)),
            Offset(c.x - coreR, c.y - coreR), Offset(c.x + coreR, c.y + coreR)), coreR, c)
        drawCircle(Color.White.copy(alpha = 0.12f), coreR * 0.5f, Offset(c.x - coreR * 0.18f, c.y - coreR * 0.18f))
        if (phase == OrbPhase.Thinking) {
            val ar = r * 0.5f
            drawArc(MB.info, spin, 80f, false, Offset(c.x - ar, c.y - ar), androidx.compose.ui.geometry.Size(ar * 2, ar * 2), style = Stroke(3.dp.toPx(), cap = StrokeCap.Round))
        }
    }
}
