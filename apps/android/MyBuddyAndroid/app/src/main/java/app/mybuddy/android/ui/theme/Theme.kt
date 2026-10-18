package app.mybuddy.android.ui.theme

import android.provider.Settings
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Color tokens shared with the Mac app (docs/PRODUCT_DESIGN.md §2). Never use raw colors in screens. */
object MB {
    val base = Color(0xFF0A0C10)
    val surface = Color(0xFF11151B)
    val elevated = Color(0xFF171D25)
    val elevatedHigh = Color(0xFF1C232D)
    val border = Color(0xFF27303B)
    val borderStrong = Color(0xFF35404D)
    val textPrimary = Color(0xFFF4F7FB)
    val textSecondary = Color(0xFF9AA6B5)
    val textTertiary = Color(0xFF7A8595)
    val accent = Color(0xFFB8F36B)
    val info = Color(0xFF6CDCF5)
    val warning = Color(0xFFF4BE62)
    val danger = Color(0xFFFF6B76)
    val onAccent = Color(0xFF0A0C10)
    val highlight = Color.White.copy(alpha = 0.04f)
}

object Space {
    val xxs = 2.dp
    val xs = 4.dp
    val s = 8.dp
    val m = 12.dp
    val l = 16.dp
    val xl = 24.dp
    val xxl = 32.dp
    val xxxl = 48.dp
}

object Radius {
    val sm = 6.dp
    val md = 10.dp
    val lg = 16.dp
    val xl = 24.dp
}

enum class Tone(val color: Color) {
    Neutral(MB.textSecondary), Live(MB.accent), Info(MB.info), Warning(MB.warning), Danger(MB.danger)
}

object MBType {
    val display = TextStyle(fontSize = 34.sp, lineHeight = 40.sp, fontWeight = FontWeight.SemiBold, color = MB.textPrimary)
    val hero = TextStyle(fontSize = 24.sp, lineHeight = 30.sp, fontWeight = FontWeight.SemiBold, color = MB.textPrimary)
    val title = TextStyle(fontSize = 22.sp, lineHeight = 28.sp, fontWeight = FontWeight.SemiBold, color = MB.textPrimary)
    val headline = TextStyle(fontSize = 17.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold, color = MB.textPrimary)
    val body = TextStyle(fontSize = 15.sp, lineHeight = 21.sp, color = MB.textPrimary)
    val bodyEmphasis = TextStyle(fontSize = 15.sp, lineHeight = 21.sp, fontWeight = FontWeight.Medium, color = MB.textPrimary)
    val callout = TextStyle(fontSize = 13.sp, lineHeight = 18.sp, color = MB.textSecondary)
    val caption = TextStyle(fontSize = 11.5.sp, lineHeight = 15.sp, color = MB.textTertiary)
    val label = TextStyle(fontSize = 11.sp, lineHeight = 14.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 0.6.sp, color = MB.textTertiary)
    val mono = TextStyle(fontSize = 13.sp, lineHeight = 18.sp, fontFamily = FontFamily.Monospace, color = MB.textSecondary)
}

/** True when the user turned off animations (Developer options / Accessibility "Remove animations"). */
val LocalReduceMotion = staticCompositionLocalOf { false }

@Composable
fun MyBuddyTheme(content: @Composable () -> Unit) {
    val context = LocalContext.current
    val reduceMotion = remember {
        Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    }
    val scheme = darkColorScheme(
        primary = MB.accent, onPrimary = MB.onAccent, secondary = MB.info, onSecondary = MB.onAccent,
        background = MB.base, onBackground = MB.textPrimary, surface = MB.surface, onSurface = MB.textPrimary,
        surfaceVariant = MB.elevated, onSurfaceVariant = MB.textSecondary, surfaceContainer = MB.surface,
        surfaceContainerHigh = MB.elevated, surfaceContainerHighest = MB.elevatedHigh, outline = MB.border,
        outlineVariant = MB.border, error = MB.danger, onError = MB.onAccent,
    )
    val typography = Typography(
        titleLarge = MBType.title, titleMedium = MBType.headline, bodyLarge = MBType.body, bodyMedium = MBType.callout,
        labelLarge = MBType.bodyEmphasis, labelMedium = MBType.label, labelSmall = MBType.caption,
    )
    CompositionLocalProvider(LocalReduceMotion provides reduceMotion) {
        MaterialTheme(colorScheme = scheme, typography = typography, content = content)
    }
}
