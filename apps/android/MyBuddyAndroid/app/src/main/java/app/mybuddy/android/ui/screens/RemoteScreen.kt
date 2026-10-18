package app.mybuddy.android.ui.screens

import android.content.pm.ActivityInfo
import androidx.activity.compose.BackHandler
import androidx.activity.compose.LocalActivity
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ScreenShare
import androidx.compose.material.icons.automirrored.rounded.Send
import androidx.compose.material.icons.automirrored.rounded.StopScreenShare
import androidx.compose.material.icons.rounded.CropFree
import androidx.compose.material.icons.rounded.ExpandLess
import androidx.compose.material.icons.rounded.FitScreen
import androidx.compose.material.icons.rounded.Fullscreen
import androidx.compose.material.icons.rounded.FullscreenExit
import androidx.compose.material.icons.rounded.Keyboard
import androidx.compose.material.icons.rounded.KeyboardHide
import androidx.compose.material.icons.rounded.Mouse
import androidx.compose.material.icons.rounded.PowerSettingsNew
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.ScreenRotation
import androidx.compose.material.icons.rounded.SpaceDashboard
import androidx.compose.material.icons.rounded.TouchApp
import androidx.compose.material.icons.rounded.Visibility
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.navigation.NavHostController
import app.mybuddy.android.AppViewModel
import app.mybuddy.android.core.stream.LiveTyping
import app.mybuddy.android.core.stream.StreamPhase
import app.mybuddy.android.core.stream.StreamText
import app.mybuddy.android.core.stream.StreamUi
import app.mybuddy.android.core.stream.Trackpad
import app.mybuddy.android.ui.Page
import app.mybuddy.android.ui.components.BrandMark
import app.mybuddy.android.ui.components.ControlGesture
import app.mybuddy.android.ui.components.Eyebrow
import app.mybuddy.android.ui.components.InputMode
import app.mybuddy.android.ui.components.MetricRow
import app.mybuddy.android.ui.components.Panel
import app.mybuddy.android.ui.components.PrimaryButton
import app.mybuddy.android.ui.components.RemoteVideo
import app.mybuddy.android.ui.components.SecondaryButton
import app.mybuddy.android.ui.components.StateKind
import app.mybuddy.android.ui.components.StateMessage
import app.mybuddy.android.ui.components.StatusPill
import app.mybuddy.android.ui.theme.MB
import app.mybuddy.android.ui.theme.MBType
import app.mybuddy.android.ui.theme.Radius
import app.mybuddy.android.ui.theme.Space
import app.mybuddy.android.ui.theme.Tone
import kotlinx.coroutines.delay
import org.webrtc.VideoTrack
import kotlin.math.roundToLong

@Composable
fun RemoteScreen(vm: AppViewModel, nav: NavHostController) {
    val state by vm.connection.collectAsState()
    val session by vm.session.collectAsState()
    val rtt by vm.rttMs.collectAsState()
    val notice by vm.remoteNotice.collectAsState()
    val stream by vm.screen.state.collectAsState()
    val track by vm.screen.track.collectAsState()
    val fullscreen by vm.remoteFullscreen.collectAsState()
    val demo by vm.demo.collectAsState()
    val pointer by vm.pointer.collectAsState()
    var fill by rememberSaveable { mutableStateOf(false) }
    // The normal view starts in View mode so a stray touch can't click on the Mac before the user picks a control
    // mode; full screen (a deliberate step) starts as a trackpad. Both exist only while the Mac grants input.control.
    var mode by rememberSaveable { mutableStateOf(InputMode.VIEW) }
    var fullMode by rememberSaveable { mutableStateOf(InputMode.TRACKPAD) }
    val allowed = session?.granted?.contains("input.control") == true
    // Recomputed whenever the connection, grants or preview mode change (all observed above).
    val blocker = remember(state, session, demo) { vm.screenBlocker() }
    val showing = stream.phase == StreamPhase.Live || stream.phase == StreamPhase.Reconnecting
    LaunchedEffect(stream.isActive) {
        if (!stream.isActive) {
            mode = InputMode.VIEW
            fullMode = InputMode.TRACKPAD
            vm.remoteFullscreen.value = false
        }
    }
    val onControl = remember(vm) { controlHandler(vm) }
    // The phone shouldn't dim and lock while you watch or control the Mac.
    KeepScreenOn(stream.isActive)

    // Viewing only happens on this screen: leaving it stops the stream (backgrounding is handled app-wide).
    DisposableEffect(Unit) {
        vm.remoteVisible = true
        onDispose {
            vm.remoteVisible = false
            vm.stopScreen()
            vm.remoteFullscreen.value = false
        }
    }

    if (fullscreen && showing) {
        BackHandler { vm.remoteFullscreen.value = false }
        FullscreenStream(vm, stream, track, fill, if (allowed) fullMode else InputMode.VIEW, allowed, pointer, rtt, onControl,
            onMode = { fullMode = it }, onFill = { fill = it })
        return
    }

    Page("Remote", vm, nav, trailing = {
        if (state.isConnected) {
            SecondaryButton("Stop", icon = Icons.Rounded.PowerSettingsNew, tone = Tone.Danger) { vm.emergencyStop() }
        }
    }) {
        item { ScreenStage(vm, stream, track, fill, blocker, if (allowed) mode else InputMode.VIEW, pointer, onControl) }
        if (showing) {
            // Everything that used to sit on top of the picture lives below it, so nothing covers the Mac's menu bar.
            item { StageBar(stream, rtt, allowed, if (allowed) mode else InputMode.VIEW, onMode = { mode = it }) { vm.remoteFullscreen.value = true } }
            item { StreamControls(vm, stream, fill) { fill = it } }
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s), verticalAlignment = Alignment.CenterVertically) {
                StatusPill(vm.statusTitle(state), toneOf(state), pulsing = state.isConnected)
                Text(rtt?.let { "Ping $it ms" } ?: "Ping —", style = MBType.mono)
            }
        }
        if (notice != null) {
            item {
                Panel { Text(notice!!, style = MBType.callout.copy(color = MB.warning)) }
            }
        }
        if (!state.isConnected) {
            item { StateMessage(StateKind.Offline, "Connect to your Mac", "Remote control needs an active, encrypted session.") { PrimaryButton("Connect") { vm.reconnect() } } }
        } else if (!allowed) {
            item {
                StateMessage(StateKind.NotAuthorized, "Control is off for this phone",
                    "On your Mac: MyBuddy → Settings → Devices → turn on “Control mouse & keyboard”. The Mac also needs Accessibility permission.")
            }
        } else {
            item { Touchpad(vm, aspectOf(stream)) }
            item {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    SecondaryButton("Click", modifier = Modifier.weight(1f)) { vm.click() }
                    SecondaryButton("Right", modifier = Modifier.weight(1f)) { vm.click("right") }
                    SecondaryButton("Double", modifier = Modifier.weight(1f)) { vm.click("left", "doubleClick") }
                }
            }
            item { RemoteKeyboard(vm) }
        }
    }
}

private fun controlHandler(vm: AppViewModel): (ControlGesture) -> Unit = { g ->
    when (g) {
        is ControlGesture.Tap -> vm.clickAt(g.x, g.y)
        is ControlGesture.DoubleTap -> vm.clickAt(g.x, g.y, action = "doubleClick")
        is ControlGesture.LongPress -> vm.clickAt(g.x, g.y, button = "right")
        is ControlGesture.Move -> vm.pointAt(g.x, g.y)
        is ControlGesture.Scroll -> vm.scroll(g.dx, g.dy)
        is ControlGesture.MoveBy -> vm.movePointer(g.dx, g.dy)
        is ControlGesture.PointerClick -> vm.click(g.button, g.action)
        is ControlGesture.PointerButton -> vm.pointerButton(g.down)
        is ControlGesture.Swipe -> vm.swipe(g.direction)
    }
}

@Composable
private fun KeepScreenOn(on: Boolean) {
    val view = LocalView.current
    DisposableEffect(view, on) {
        view.keepScreenOn = on
        onDispose { view.keepScreenOn = false }
    }
}

private fun aspectOf(stream: StreamUi): Float {
    val w = stream.host?.width
    val h = stream.host?.height
    return if (w != null && h != null && h > 0) w.toFloat() / h else 16f / 10f
}

/** e.g. "30 fps · ping 12 ms" — the stream's frame rate and the round trip to the Mac. */
private fun liveLine(stream: StreamUi, rtt: Long?): String = listOfNotNull(
    stream.stats?.fps?.let { "%.0f fps".format(it) },
    (stream.stats?.rttMs?.roundToLong() ?: rtt)?.let { "ping $it ms" },
).joinToString(" · ")

private fun modeHint(mode: InputMode): String = when (mode) {
    InputMode.TRACKPAD -> "Trackpad: drag to move · tap to click · double-tap to double-click · rest, then drag to drag · two-finger tap = right-click · two fingers scroll · three fingers switch spaces"
    InputMode.TOUCH -> "Touch: tap clicks where you touch · long-press = right-click · drag moves the pointer · two fingers scroll · three fingers switch spaces"
    InputMode.VIEW -> "View only: pinch to zoom, drag to pan — nothing reaches your Mac"
}

/** The picture area: the decoded stream, or an honest state. Never a stand-in image. */
@Composable
private fun ScreenStage(
    vm: AppViewModel, stream: StreamUi, track: VideoTrack?, fill: Boolean, blocker: String?,
    mode: InputMode, pointer: Pair<Double, Double>, onControl: (ControlGesture) -> Unit,
) {
    val aspect = aspectOf(stream)
    val reconnecting = stream.phase == StreamPhase.Reconnecting
    val live = (stream.phase == StreamPhase.Live || reconnecting) && track != null
    var pictured by remember(track) { mutableStateOf(false) }
    Box(
        Modifier.fillMaxWidth().aspectRatio(aspect).clip(RoundedCornerShape(Radius.lg)).background(if (live) Color.Black else MB.surface)
            .border(1.dp, if (live && pictured) MB.accent.copy(alpha = 0.5f) else MB.border, RoundedCornerShape(Radius.lg)),
        contentAlignment = Alignment.Center,
    ) {
        if (live) {
            RemoteVideo(track, vm.screen.eglBase.eglBaseContext, aspect, fill, Modifier.fillMaxSize(), mode = mode,
                pointer = pointer.takeIf { mode != InputMode.VIEW }, onControl = onControl, onFirstFrame = { pictured = true })
            if (!pictured || reconnecting) {
                Column(
                    Modifier.background(Color.Black.copy(alpha = 0.55f), RoundedCornerShape(Radius.md)).padding(Space.m),
                    horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Space.s),
                ) {
                    CircularProgressIndicator(Modifier.size(28.dp), color = MB.accent, strokeWidth = 2.dp)
                    Text(if (reconnecting) stream.message ?: "Reconnecting…" else "Waiting for the first picture…", style = MBType.callout)
                }
            }
        } else {
            StageMessage(vm, stream, blocker)
        }
    }
}

@Composable
private fun StageMessage(vm: AppViewModel, stream: StreamUi, blocker: String?) {
    Column(Modifier.padding(Space.l), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Space.s)) {
        when (stream.phase) {
            StreamPhase.Requesting, StreamPhase.Starting, StreamPhase.Connecting, StreamPhase.AwaitingSelection, StreamPhase.Reconnecting -> {
                CircularProgressIndicator(Modifier.size(28.dp), color = MB.accent, strokeWidth = 2.dp)
                Text(
                    when (stream.phase) {
                        StreamPhase.Requesting -> "Asking your Mac…"
                        StreamPhase.Starting -> "Your Mac is starting the stream…"
                        StreamPhase.AwaitingSelection -> "Choose what to share on your Mac."
                        StreamPhase.Reconnecting -> stream.message ?: "Reconnecting…"
                        else -> "Connecting video…"
                    },
                    style = MBType.headline, textAlign = TextAlign.Center,
                )
                val detail = listOfNotNull(
                    stream.message.takeIf { stream.phase != StreamPhase.Reconnecting },
                    stream.ice?.takeIf { stream.phase == StreamPhase.Connecting }?.let { "Network check: $it" },
                ).joinToString(" · ")
                if (detail.isNotEmpty()) Text(detail, style = MBType.caption, textAlign = TextAlign.Center)
                SecondaryButton("Cancel", icon = Icons.AutoMirrored.Rounded.StopScreenShare) { vm.stopScreen() }
            }
            StreamPhase.Failed, StreamPhase.NotAuthorized -> {
                Text(if (stream.phase == StreamPhase.NotAuthorized) "Your Mac didn’t allow it" else "Couldn’t show your Mac’s screen", style = MBType.headline, textAlign = TextAlign.Center)
                Text(stream.message ?: "", style = MBType.callout, textAlign = TextAlign.Center)
                if (blocker == null) SecondaryButton("Try again", icon = Icons.Rounded.Refresh) { vm.startScreen() }
            }
            else -> {
                BrandMark(40.dp, live = blocker == null)
                Text(if (blocker == null) "See your Mac’s screen" else "Screen viewing unavailable", style = MBType.headline, textAlign = TextAlign.Center)
                Text(
                    blocker ?: (stream.message?.let { "$it " } ?: "") + "Encrypted video straight from your Mac. It stops when you leave this tab.",
                    style = MBType.callout, textAlign = TextAlign.Center,
                )
                if (blocker == null) {
                    PrimaryButton("View screen", icon = Icons.AutoMirrored.Rounded.ScreenShare) { vm.startScreen() }
                }
            }
        }
    }
}

/** Below the picture: live state, how touches behave, and full screen. */
@Composable
private fun StageBar(stream: StreamUi, rtt: Long?, canControl: Boolean, mode: InputMode, onMode: (InputMode) -> Unit, onFullscreen: () -> Unit) {
    val reconnecting = stream.phase == StreamPhase.Reconnecting
    Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            StatusPill(if (reconnecting) "Reconnecting" else "Live", if (reconnecting) Tone.Warning else Tone.Live, pulsing = true)
            Text(liveLine(stream, rtt), style = MBType.caption, maxLines = 1, modifier = Modifier.weight(1f).padding(horizontal = Space.s))
            SecondaryButton("Full screen", icon = Icons.Rounded.Fullscreen) { onFullscreen() }
        }
        if (canControl) {
            ModeChips(mode, onMode)
            Text(modeHint(mode), style = MBType.caption.copy(color = if (mode == InputMode.VIEW) MB.textTertiary else MB.accent))
        } else {
            Text("View only — control is off for this phone.", style = MBType.caption)
        }
    }
}

/** View · Trackpad · Touch. Not scrollable when it sits inside an already scrolling row. */
@Composable
private fun ModeChips(mode: InputMode, onMode: (InputMode) -> Unit, scrollable: Boolean = true) {
    val modes = listOf(
        Triple(InputMode.VIEW, "View", Icons.Rounded.Visibility),
        Triple(InputMode.TRACKPAD, "Trackpad", Icons.Rounded.Mouse),
        Triple(InputMode.TOUCH, "Touch", Icons.Rounded.TouchApp),
    )
    Row(if (scrollable) Modifier.horizontalScroll(rememberScrollState()) else Modifier, horizontalArrangement = Arrangement.spacedBy(Space.xs),
        verticalAlignment = Alignment.CenterVertically) {
        modes.forEach { (m, label, icon) ->
            FilterChip(mode == m, { onMode(m) }, label = { Text(label) }, leadingIcon = { Icon(icon, null, Modifier.size(18.dp)) }, colors = chipColors(),
                modifier = Modifier.semantics { contentDescription = modeHint(m) })
        }
    }
}

@Composable
private fun StreamControls(vm: AppViewModel, stream: StreamUi, fill: Boolean, onFill: (Boolean) -> Unit) {
    val host = stream.host
    val stats = stream.stats
    val fastInput by vm.screen.inputOverWebRtc.collectAsState()
    Panel {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Eyebrow("Quality", Modifier.weight(1f))
            Text(
                when (stream.quality) {
                    "auto" -> "Auto · ${host?.tier ?: "…"} tier"
                    "smooth" -> "60 fps for controlling"
                    else -> "Fixed"
                },
                style = MBType.caption,
            )
        }
        Spacer(Modifier.size(Space.xs))
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
            listOf("auto" to "Auto", "smooth" to "Smooth 60", "high" to "High", "balanced" to "Balanced", "low" to "Low").forEach { (q, label) ->
                FilterChip(stream.quality == q, { vm.screen.setQuality(q) }, label = { Text(label) }, colors = chipColors())
            }
        }
        if ((host?.displays?.size ?: 0) > 1) {
            Spacer(Modifier.size(Space.s))
            Eyebrow("Display")
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
                host!!.displays.forEach { d ->
                    FilterChip(host.displayId == d.id, { vm.screen.selectDisplay(d.id) }, label = { Text(d.name + if (d.main) " (main)" else "") }, colors = chipColors())
                }
            }
        }
        Spacer(Modifier.size(Space.s))
        Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
            SecondaryButton(if (fill) "Fill" else "Fit", modifier = Modifier.weight(1f), icon = if (fill) Icons.Rounded.CropFree else Icons.Rounded.FitScreen) { onFill(!fill) }
            SecondaryButton("Stop viewing", modifier = Modifier.weight(1f), icon = Icons.AutoMirrored.Rounded.StopScreenShare, tone = Tone.Danger) { vm.stopScreen() }
        }
        Spacer(Modifier.size(Space.s))
        MetricRow("Video", stats?.let(StreamText::summary) ?: "measuring…", source = "WebRTC stats")
        MetricRow("Latency", stats?.let(StreamText::latency) ?: "measuring…", note = "Time on this phone after the network")
        MetricRow("Path", StreamText.path(stats) + (stats?.localCandidateType?.let { " · $it ↔ ${stats.remoteCandidateType ?: "?"}" } ?: ""))
        MetricRow("Round trip", stats?.rttMs?.let { "%.0f ms".format(it) } ?: "—")
        MetricRow("Input route", if (fastInput) "WebRTC data channel" else "Encrypted control channel")
        MetricRow("Decoder", stats?.implementation?.let { it + if (stats.hardwareAccelerated == true) " · hardware" else "" } ?: "—",
            note = stats?.packetsLost?.takeIf { it > 0 }?.let { "$it packets lost" })
        if (host?.source == "test_pattern") {
            MetricRow("Source", "Test pattern from a test host — not a real screen", tone = Tone.Warning)
        }
    }
}

private data class MacKey(val label: String, val code: String, val modifiers: List<String> = emptyList())

/** Keys a phone keyboard doesn't have (the Mac maps each W3C code; see InputMapping.swift). */
private val MAC_KEYS = listOf(
    MacKey("Esc", "Escape"), MacKey("Tab", "Tab"), MacKey("⏎", "Enter"), MacKey("⌫", "Backspace"), MacKey("Del", "Delete"),
    MacKey("←", "ArrowLeft"), MacKey("→", "ArrowRight"), MacKey("↑", "ArrowUp"), MacKey("↓", "ArrowDown"),
    MacKey("Home", "Home"), MacKey("End", "End"), MacKey("PgUp", "PageUp"), MacKey("PgDn", "PageDown"),
    MacKey("⌘A", "KeyA", listOf("command")), MacKey("⌘C", "KeyC", listOf("command")), MacKey("⌘V", "KeyV", listOf("command")),
    MacKey("⌘Z", "KeyZ", listOf("command")), MacKey("⌘Tab", "Tab", listOf("command")), MacKey("⌘Space", "Space", listOf("command")),
)

@Composable
private fun SpecialKeys(vm: AppViewModel) {
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
        MAC_KEYS.forEach { k -> KeyCap(k.label) { vm.key(k.code, k.modifiers) } }
    }
}

/** Type-then-send keyboard. It stays above the phone's keyboard while you type (the page pads for the IME). */
@OptIn(ExperimentalFoundationApi::class, ExperimentalLayoutApi::class)
@Composable
private fun RemoteKeyboard(vm: AppViewModel) {
    var typed by rememberSaveable { mutableStateOf("") }
    var focused by remember { mutableStateOf(false) }
    val requester = remember { BringIntoViewRequester() }
    val imeVisible = WindowInsets.isImeVisible
    LaunchedEffect(focused, imeVisible) {
        if (focused && imeVisible) {
            delay(150) // after the list has shrunk for the keyboard
            requester.bringIntoView()
        }
    }
    fun send() {
        if (typed.isNotEmpty()) {
            vm.typeText(typed)
            typed = ""
        }
    }
    Panel(Modifier.bringIntoViewRequester(requester)) {
        Eyebrow("Keyboard")
        Spacer(Modifier.size(Space.s))
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(typed, { typed = it }, Modifier.weight(1f).onFocusChanged { focused = it.isFocused },
                placeholder = { Text("Type on your Mac", style = MBType.callout) }, singleLine = true, colors = fieldColors(),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send), keyboardActions = KeyboardActions(onSend = { send() }))
            IconButton({ send() }) { Icon(Icons.AutoMirrored.Rounded.Send, "Send text", tint = MB.accent) }
        }
        Spacer(Modifier.size(Space.s))
        SpecialKeys(vm)
    }
}

/** Landscape and immersive (system bars hidden, swipe from an edge to peek) while the full-screen view is open. */
@Composable
private fun ImmersiveFullscreen(landscape: Boolean) {
    val activity = LocalActivity.current ?: return
    val view = LocalView.current
    DisposableEffect(activity, view) {
        val controller = WindowCompat.getInsetsController(activity.window, view)
        controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        controller.hide(WindowInsetsCompat.Type.systemBars())
        onDispose {
            controller.show(WindowInsetsCompat.Type.systemBars())
            activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }
    }
    LaunchedEffect(activity, landscape) {
        activity.requestedOrientation = if (landscape) ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE else ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
    }
}

/**
 * Edge-to-edge picture. Trackpad by default (the whole screen is the touchpad, with a big pointer drawn where
 * MyBuddy put the Mac's), controls in a bottom bar that hides itself, a live keyboard, Back or the button returns.
 */
@Composable
private fun FullscreenStream(
    vm: AppViewModel, stream: StreamUi, track: VideoTrack?, fill: Boolean, mode: InputMode, canControl: Boolean,
    pointer: Pair<Double, Double>, rtt: Long?, onControl: (ControlGesture) -> Unit, onMode: (InputMode) -> Unit, onFill: (Boolean) -> Unit,
) {
    var landscape by rememberSaveable { mutableStateOf(true) }
    ImmersiveFullscreen(landscape)
    var barVisible by remember { mutableStateOf(true) }
    var barTouched by remember { mutableLongStateOf(0L) }
    var keyboard by remember { mutableStateOf(false) }
    var hint by remember(mode) { mutableStateOf(true) }
    LaunchedEffect(barVisible, barTouched, keyboard) {
        if (barVisible && !keyboard) {
            delay(5_000)
            barVisible = false
        }
    }
    LaunchedEffect(mode) {
        delay(4_000)
        hint = false
    }
    val poke = { barTouched = System.nanoTime() }

    Box(Modifier.fillMaxSize().background(Color.Black).semantics { contentDescription = "Full-screen view of your Mac" }) {
        if (track != null) {
            RemoteVideo(track, vm.screen.eglBase.eglBaseContext, aspectOf(stream), fill, Modifier.fillMaxSize(), mode = mode,
                pointer = pointer.takeIf { mode != InputMode.VIEW }, onControl = onControl)
        }
        if (hint) {
            Text(modeHint(mode), style = MBType.caption.copy(color = Color.White), textAlign = TextAlign.Center,
                modifier = Modifier.align(Alignment.TopCenter).padding(top = Space.m, start = Space.xl, end = Space.xl)
                    .background(Color.Black.copy(alpha = 0.6f), RoundedCornerShape(Radius.md)).padding(horizontal = Space.m, vertical = Space.s))
        }
        if (stream.phase == StreamPhase.Reconnecting) {
            Row(Modifier.align(Alignment.Center).background(Color.Black.copy(alpha = 0.6f), RoundedCornerShape(Radius.md)).padding(Space.m),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                CircularProgressIndicator(Modifier.size(20.dp), color = MB.accent, strokeWidth = 2.dp)
                Text(stream.message ?: "Reconnecting…", style = MBType.callout.copy(color = Color.White))
            }
        }
        Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().imePadding()) {
            if (keyboard && canControl) LiveKeyboard(vm) { keyboard = false }
            AnimatedVisibility(barVisible || keyboard, enter = fadeIn() + slideInVertically { it }, exit = fadeOut() + slideOutVertically { it }) {
                FullscreenBar(vm, stream, rtt, mode, canControl, fill, landscape,
                    onMode = { poke(); onMode(it) },
                    onKeyboard = { poke(); keyboard = !keyboard },
                    onFill = { poke(); onFill(it) },
                    onRotate = { poke(); landscape = !landscape },
                    onExit = { vm.remoteFullscreen.value = false },
                    poke = poke)
            }
        }
        if (!barVisible && !keyboard) {
            // Taps on the picture go to the Mac in Trackpad/Touch, so the controls come back from this handle.
            IconButton({ barVisible = true; poke() },
                Modifier.align(Alignment.BottomEnd).navigationBarsPadding().padding(Space.s).size(44.dp).background(Color.Black.copy(alpha = 0.55f), CircleShape)) {
                Icon(Icons.Rounded.ExpandLess, "Show controls", tint = Color.White)
            }
        }
    }
}

@Composable
private fun FullscreenBar(
    vm: AppViewModel, stream: StreamUi, rtt: Long?, mode: InputMode, canControl: Boolean, fill: Boolean, landscape: Boolean,
    onMode: (InputMode) -> Unit, onKeyboard: () -> Unit, onFill: (Boolean) -> Unit, onRotate: () -> Unit, onExit: () -> Unit, poke: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().background(Color.Black.copy(alpha = 0.72f)).navigationBarsPadding()
            .horizontalScroll(rememberScrollState()).padding(horizontal = Space.s, vertical = Space.xs),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.xs),
    ) {
        StatusPill(if (stream.phase == StreamPhase.Reconnecting) "Reconnecting" else "Live",
            if (stream.phase == StreamPhase.Reconnecting) Tone.Warning else Tone.Live, pulsing = true)
        Text(liveLine(stream, rtt), style = MBType.caption.copy(color = Color.White), maxLines = 1)
        if (canControl) {
            ModeChips(mode, onMode, scrollable = false)
            BarIcon(Icons.Rounded.Keyboard, "Keyboard", onKeyboard)
            KeyCap("Esc") { poke(); vm.key("Escape") }
            BarIcon(Icons.Rounded.SpaceDashboard, "Mission Control") { poke(); vm.swipe(Trackpad.Swipe.UP) }
        } else {
            Text("View only", style = MBType.caption.copy(color = Color.White))
        }
        BarIcon(if (fill) Icons.Rounded.FitScreen else Icons.Rounded.CropFree, if (fill) "Fit to screen" else "Fill screen") { onFill(!fill) }
        BarIcon(Icons.Rounded.ScreenRotation, if (landscape) "Allow portrait" else "Keep landscape", onRotate)
        BarIcon(Icons.Rounded.FullscreenExit, "Exit full screen", onExit)
    }
}

@Composable
private fun BarIcon(icon: ImageVector, label: String, onClick: () -> Unit) {
    IconButton(onClick) { Icon(icon, label, tint = Color.White) }
}

/** Full-screen keyboard: what you type reaches the Mac as you type (Enter sends Return), with the special keys. */
@Composable
private fun LiveKeyboard(vm: AppViewModel, onClose: () -> Unit) {
    val focus = remember { FocusRequester() }
    val ime = LocalSoftwareKeyboardController.current
    val empty = TextFieldValue(LiveTyping.SENTINEL, TextRange(LiveTyping.SENTINEL.length))
    var field by remember { mutableStateOf(empty) }
    LaunchedEffect(Unit) {
        focus.requestFocus()
        ime?.show()
    }
    Column(
        Modifier.fillMaxWidth().background(Color.Black.copy(alpha = 0.85f)).padding(horizontal = Space.s, vertical = Space.xs),
        verticalArrangement = Arrangement.spacedBy(Space.xs),
    ) {
        SpecialKeys(vm)
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                field,
                onValueChange = { next ->
                    val step = LiveTyping.step(field.text, next.text)
                    vm.liveType(step.backspaces, step.text)
                    field = if (step.keep == next.text) next else TextFieldValue(step.keep, TextRange(step.keep.length))
                },
                modifier = Modifier.weight(1f).focusRequester(focus),
                label = { Text("Typing on your Mac") },
                singleLine = true,
                colors = fieldColors(),
                keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Send),
                keyboardActions = KeyboardActions(onSend = {
                    vm.key("Enter")
                    field = empty
                }),
            )
            IconButton(onClose) { Icon(Icons.Rounded.KeyboardHide, "Hide keyboard", tint = Color.White) }
        }
    }
}

@Composable
private fun chipColors() = FilterChipDefaults.filterChipColors(
    selectedContainerColor = MB.accent, selectedLabelColor = MB.onAccent, selectedLeadingIconColor = MB.onAccent,
    containerColor = MB.elevated, labelColor = MB.textSecondary, iconColor = MB.textSecondary,
)
