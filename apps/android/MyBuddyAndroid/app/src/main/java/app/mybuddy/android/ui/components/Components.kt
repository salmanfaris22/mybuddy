package app.mybuddy.android.ui.components

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Visibility
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.mybuddy.android.ui.theme.LocalReduceMotion
import app.mybuddy.android.ui.theme.MB
import app.mybuddy.android.ui.theme.MBType
import app.mybuddy.android.ui.theme.Radius
import app.mybuddy.android.ui.theme.Space
import app.mybuddy.android.ui.theme.Tone
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/** The MyBuddy "companion orbit" mark. The satellite orbits while a session is live. */
@Composable
fun BrandMark(size: Dp = 28.dp, live: Boolean = false) {
    val reduce = LocalReduceMotion.current
    val angle = if (live && !reduce) {
        val t = rememberInfiniteTransition(label = "orbit")
        val a by t.animateFloat(0f, (2 * PI).toFloat(), infiniteRepeatable(tween(8000, easing = LinearEasing)), label = "angle")
        a
    } else {
        (-PI / 4).toFloat()
    }
    Canvas(Modifier.size(size).semantics { contentDescription = "" }) {
        val c = center
        val r = this.size.width * 0.38f
        drawCircle(MB.textSecondary.copy(alpha = 0.45f), radius = r, center = c, style = Stroke(width = this.size.width * 0.045f))
        drawCircle(MB.accent, radius = this.size.width * 0.17f, center = c)
        drawCircle(MB.info, radius = this.size.width * 0.095f, center = Offset(c.x + r * cos(angle), c.y + r * sin(angle)))
    }
}

/** Elevated panel: hairline border + faint top highlight, no drop shadow. */
@Composable
fun Panel(modifier: Modifier = Modifier, padding: PaddingValues = PaddingValues(Space.l), content: @Composable ColumnScope.() -> Unit) {
    val shape = RoundedCornerShape(Radius.lg)
    Column(
        modifier
            .fillMaxWidth()
            .clip(shape)
            .background(MB.elevated)
            .background(Brush.verticalGradient(0f to MB.highlight, 0.5f to Color.Transparent))
            .border(1.dp, MB.border, shape)
            .padding(padding),
        content = content,
    )
}

@Composable
fun Eyebrow(text: String, modifier: Modifier = Modifier) {
    Text(text.uppercase(), style = MBType.label, modifier = modifier)
}

@Composable
fun SectionHeader(title: String, subtitle: String? = null, trailing: (@Composable RowScope.() -> Unit)? = null) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MBType.headline)
            if (subtitle != null) Text(subtitle, style = MBType.callout)
        }
        trailing?.invoke(this)
    }
}

@Composable
fun StatusPill(text: String, tone: Tone, modifier: Modifier = Modifier, icon: ImageVector? = null, pulsing: Boolean = false) {
    val reduce = LocalReduceMotion.current
    val pulse = if (pulsing && !reduce) {
        val t = rememberInfiniteTransition(label = "pulse")
        val p by t.animateFloat(0.35f, 1f, infiniteRepeatable(tween(1600), RepeatMode.Reverse), label = "p")
        p
    } else {
        1f
    }
    Row(
        modifier
            .clip(CircleShape)
            .background(tone.color.copy(alpha = 0.10f))
            .border(1.dp, tone.color.copy(alpha = 0.28f), CircleShape)
            .padding(horizontal = 10.dp, vertical = 5.dp)
            .semantics(mergeDescendants = true) {},
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (icon != null) {
            Icon(icon, null, tint = tone.color, modifier = Modifier.size(13.dp))
        } else {
            Box(Modifier.size(7.dp).clip(CircleShape).background(tone.color.copy(alpha = pulse)))
        }
        Text(text, style = MBType.callout.copy(color = MB.textPrimary), maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
fun PreviewBadge() {
    Row(
        Modifier.clip(CircleShape).background(MB.warning.copy(alpha = 0.12f)).padding(horizontal = 8.dp, vertical = 4.dp)
            .semantics(mergeDescendants = true) { contentDescription = "Preview data, not measured" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Icon(Icons.Rounded.Visibility, null, tint = MB.warning, modifier = Modifier.size(12.dp))
        Text("PREVIEW DATA", style = MBType.label.copy(color = MB.warning))
    }
}

@Composable
fun SourceCaption(text: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Icon(Icons.Rounded.Info, null, tint = MB.textTertiary, modifier = Modifier.size(11.dp))
        Text(text, style = MBType.caption, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** One measured value with its provenance — or an explicit "Unavailable" with the reason. */
@Composable
fun MetricRow(label: String, value: String, source: String? = null, note: String? = null, tone: Tone = Tone.Neutral) {
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(vertical = 6.dp).semantics(mergeDescendants = true) {}, verticalAlignment = Alignment.CenterVertically) {
        // Notes (formulas, reasons) sit under the label and the value is capped, so a long note can
        // never squeeze the label into a one-letter column.
        Column(Modifier.weight(1f)) {
            Text(label, style = MBType.body.copy(color = MB.textSecondary))
            if (source != null) SourceCaption(source)
            if (note != null) Text(note, style = MBType.caption)
        }
        Spacer(Modifier.width(Space.m))
        Text(value, style = MBType.bodyEmphasis.copy(color = if (tone == Tone.Neutral) MB.textPrimary else tone.color),
            textAlign = TextAlign.End, modifier = Modifier.widthIn(max = 168.dp))
    }
}

@Composable
fun RingGauge(value: Float?, tone: Tone, size: Dp = 120.dp, stroke: Dp = 10.dp, content: @Composable () -> Unit) {
    val reduce = LocalReduceMotion.current
    val animated by animateFloatAsState(value ?: 0f, if (reduce) tween(0) else spring(dampingRatio = 0.8f, stiffness = 120f), label = "ring")
    Box(Modifier.size(size), contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(size)) {
            val sw = stroke.toPx()
            drawArc(MB.border, 0f, 360f, false, style = Stroke(sw), topLeft = Offset(sw / 2, sw / 2),
                size = androidx.compose.ui.geometry.Size(this.size.width - sw, this.size.height - sw))
            if (value != null) {
                drawArc(tone.color, -90f, 360f * animated.coerceIn(0f, 1f), false, style = Stroke(sw, cap = StrokeCap.Round),
                    topLeft = Offset(sw / 2, sw / 2), size = androidx.compose.ui.geometry.Size(this.size.width - sw, this.size.height - sw))
            }
        }
        content()
    }
}

@Composable
fun UsageBar(fraction: Float, tone: Tone = Tone.Info) {
    Box(Modifier.fillMaxWidth().padding(vertical = 4.dp).clip(CircleShape).background(MB.border)) {
        Box(Modifier.fillMaxWidth(fraction.coerceIn(0.02f, 1f)).height(6.dp).clip(CircleShape).background(tone.color))
    }
}

enum class StateKind { Loading, Empty, Error, NotAuthorized, Unavailable, Offline }

/** Designed empty/loading/error/permission states (never raw exception text). */
@Composable
fun StateMessage(kind: StateKind, title: String, message: String, action: (@Composable () -> Unit)? = null) {
    val tone = when (kind) {
        StateKind.Error -> Tone.Danger
        StateKind.NotAuthorized, StateKind.Offline -> Tone.Warning
        StateKind.Unavailable -> Tone.Neutral
        else -> Tone.Info
    }
    Column(Modifier.fillMaxWidth().padding(Space.xl), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Space.m)) {
        if (kind == StateKind.Loading) {
            CircularProgressIndicator(color = MB.accent, strokeWidth = 2.dp, modifier = Modifier.size(24.dp))
        } else {
            Box(Modifier.size(48.dp).clip(CircleShape).background(tone.color.copy(alpha = 0.1f)), contentAlignment = Alignment.Center) {
                BrandMark(28.dp)
            }
        }
        Text(title, style = MBType.headline, textAlign = TextAlign.Center)
        Text(message, style = MBType.callout, textAlign = TextAlign.Center)
        action?.invoke()
    }
}

@Composable
fun PrimaryButton(text: String, modifier: Modifier = Modifier, icon: ImageVector? = null, enabled: Boolean = true, onClick: () -> Unit) {
    Button(
        onClick, modifier.heightIn(min = 48.dp), enabled = enabled, shape = RoundedCornerShape(Radius.md),
        colors = ButtonDefaults.buttonColors(containerColor = MB.accent, contentColor = MB.onAccent, disabledContainerColor = MB.border),
    ) {
        if (icon != null) {
            Icon(icon, null, Modifier.size(18.dp))
            Spacer(Modifier.width(Space.s))
        }
        Text(text, style = MBType.bodyEmphasis.copy(color = if (enabled) MB.onAccent else MB.textTertiary))
    }
}

@Composable
fun SecondaryButton(text: String, modifier: Modifier = Modifier, icon: ImageVector? = null, enabled: Boolean = true, tone: Tone = Tone.Neutral, onClick: () -> Unit) {
    val fg = if (tone == Tone.Neutral) MB.textPrimary else tone.color
    OutlinedButton(
        onClick, modifier.heightIn(min = 48.dp), enabled = enabled, shape = RoundedCornerShape(Radius.md),
        border = BorderStroke(1.dp, if (tone == Tone.Neutral) MB.borderStrong else tone.color.copy(alpha = 0.4f)),
        colors = ButtonDefaults.outlinedButtonColors(containerColor = if (tone == Tone.Danger) MB.danger.copy(alpha = 0.10f) else MB.elevated, contentColor = fg),
    ) {
        if (icon != null) {
            Icon(icon, null, Modifier.size(18.dp))
            Spacer(Modifier.width(Space.s))
        }
        Text(text, style = MBType.bodyEmphasis.copy(color = fg))
    }
}

@Composable
fun GhostButton(text: String, onClick: () -> Unit) {
    TextButton(onClick, Modifier.heightIn(min = 48.dp)) { Text(text, style = MBType.bodyEmphasis.copy(color = MB.textSecondary)) }
}

@Composable
fun TimelineRow(icon: ImageVector, tone: Tone, title: String, detail: String?, time: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp).semantics(mergeDescendants = true) {}, verticalAlignment = Alignment.Top) {
        Box(Modifier.size(30.dp).clip(RoundedCornerShape(Radius.sm + 1.dp)).background(tone.color.copy(alpha = 0.1f)), contentAlignment = Alignment.Center) {
            Icon(icon, null, tint = tone.color, modifier = Modifier.size(15.dp))
        }
        Spacer(Modifier.width(Space.m))
        Column(Modifier.weight(1f)) {
            Text(title, style = MBType.body, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (detail != null) Text(detail, style = MBType.caption, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Text(time, style = MBType.caption)
    }
}
