package app.mybuddy.android.ui.screens

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Chat
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.FolderOpen
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material.icons.rounded.Mouse
import androidx.compose.material.icons.rounded.QrCode2
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Shield
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.navigation.NavHostController
import app.mybuddy.android.AppViewModel
import app.mybuddy.android.BuildConfig
import app.mybuddy.android.core.session.ConnectionState
import app.mybuddy.android.data.ActivityKind
import app.mybuddy.android.data.Formats
import app.mybuddy.android.data.HealthRow
import app.mybuddy.android.data.Load
import app.mybuddy.android.data.VoicePhase
import app.mybuddy.android.ui.Page
import app.mybuddy.android.ui.components.BrandMark
import app.mybuddy.android.ui.components.Eyebrow
import app.mybuddy.android.ui.components.MetricRow
import app.mybuddy.android.ui.components.OrbPhase
import app.mybuddy.android.ui.components.Panel
import app.mybuddy.android.ui.components.PreviewBadge
import app.mybuddy.android.ui.components.PrimaryButton
import app.mybuddy.android.ui.components.RingGauge
import app.mybuddy.android.ui.components.SecondaryButton
import app.mybuddy.android.ui.components.SectionHeader
import app.mybuddy.android.ui.components.StateKind
import app.mybuddy.android.ui.components.StateMessage
import app.mybuddy.android.ui.components.StatusPill
import app.mybuddy.android.ui.components.TimelineRow
import app.mybuddy.android.ui.components.UsageBar
import app.mybuddy.android.ui.components.VoiceOrb
import app.mybuddy.android.ui.theme.MB
import app.mybuddy.android.ui.theme.MBType
import app.mybuddy.android.ui.theme.Radius
import app.mybuddy.android.ui.theme.Space
import app.mybuddy.android.ui.theme.Tone
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader
import java.util.concurrent.Executors

// region Activity

@Composable
fun ActivityScreen(vm: AppViewModel) {
    val items by vm.activity.collectAsState()
    var filter by remember { mutableStateOf<ActivityKind?>(null) }
    val shown = items.filter { filter == null || it.kind == filter }
    Page("Activity", vm, trailing = { if (items.isNotEmpty()) SecondaryButton("Clear", tone = Tone.Danger) { vm.clearActivity() } }) {
        item {
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                (listOf<ActivityKind?>(null) + ActivityKind.entries).forEach { k ->
                    FilterChip(filter == k, { filter = k }, { Text(k?.let(::kindLabel) ?: "All") },
                        colors = FilterChipDefaults.filterChipColors(selectedContainerColor = MB.accent, selectedLabelColor = MB.onAccent, containerColor = MB.elevated, labelColor = MB.textSecondary))
                }
            }
        }
        if (shown.isEmpty()) {
            item { StateMessage(StateKind.Empty, "No activity", "Connections, pairing, AI and voice actions appear here — never their content. History stays on this phone.") }
        } else {
            item {
                Panel {
                    shown.forEach { a ->
                        TimelineRow(iconFor(a.kind), toneFor(a.kind), a.title, a.detail, Formats.relative(a.at))
                    }
                }
            }
        }
    }
}

private fun kindLabel(k: ActivityKind) = if (k == ActivityKind.Ai) "AI" else k.name

private fun iconFor(k: ActivityKind) = when (k) {
    ActivityKind.Session -> Icons.Rounded.Sync
    ActivityKind.Pairing -> Icons.Rounded.QrCode2
    ActivityKind.Ai -> Icons.Rounded.AutoAwesome
    ActivityKind.Voice -> Icons.Rounded.Mic
    ActivityKind.Files -> Icons.Rounded.FolderOpen
    ActivityKind.Security -> Icons.Rounded.Shield
    ActivityKind.Input -> Icons.Rounded.Mouse
}

private fun toneFor(k: ActivityKind) = when (k) {
    ActivityKind.Security -> Tone.Warning
    ActivityKind.Session, ActivityKind.Pairing -> Tone.Live
    else -> Tone.Info
}

// endregion

// region Pairing

@Composable
fun PairingScreen(vm: AppViewModel, nav: NavHostController) {
    val context = LocalContext.current
    val state by vm.connection.collectAsState()
    val error by vm.pairingError.collectAsState()
    var link by remember { mutableStateOf("") }
    var cameraGranted by remember { mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) }
    var scanned by remember { mutableStateOf(false) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { cameraGranted = it }

    // Land on Home with a clean back stack, whichever screen opened pairing.
    LaunchedEffect(state) { if (state.isConnected && scanned) nav.navigate("home") { popUpTo(nav.graph.id) { inclusive = true } } }

    Page("Pair with your Mac", vm, nav, back = true) {
        when (val s = state) {
            is ConnectionState.AwaitingApproval -> item {
                Panel(padding = androidx.compose.foundation.layout.PaddingValues(Space.xl)) {
                    Eyebrow("Check that your Mac shows")
                    Spacer(Modifier.size(Space.m))
                    Text("${s.code.take(3)} ${s.code.takeLast(3)}", style = MBType.display.copy(fontSize = 48.sp),
                        modifier = Modifier.semantics { contentDescription = "Verification code ${s.code.toCharArray().joinToString(" ")}" })
                    Spacer(Modifier.size(Space.m))
                    Text("Approve on your Mac only if the numbers match.", style = MBType.callout)
                    Spacer(Modifier.size(Space.l))
                    StatusPill("Waiting for approval on your Mac", Tone.Warning, pulsing = true)
                }
            }
            is ConnectionState.Pairing -> item { StateMessage(StateKind.Loading, "Connecting to your Mac…", "Checking that this is the Mac that showed the code.") }
            else -> {
                item {
                    Text("On your Mac open MyBuddy → Pair a phone, then point the camera at the code.", style = MBType.callout)
                }
                item {
                    Box(Modifier.fillMaxWidth().aspectRatio(1f).clip(RoundedCornerShape(Radius.xl)).background(MB.surface).border(1.dp, MB.border, RoundedCornerShape(Radius.xl)),
                        contentAlignment = Alignment.Center) {
                        if (cameraGranted && !scanned) {
                            QrScanner { text ->
                                if (!scanned && text.startsWith("mybuddy://pair")) {
                                    scanned = true
                                    vm.pair(text)
                                }
                            }
                            Box(Modifier.fillMaxWidth(0.62f).aspectRatio(1f).border(2.dp, MB.accent, RoundedCornerShape(Radius.lg)))
                        } else if (!cameraGranted) {
                            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Space.m), modifier = Modifier.padding(Space.xl)) {
                                Icon(Icons.Rounded.QrCode2, null, tint = MB.info, modifier = Modifier.size(48.dp))
                                Text("MyBuddy uses the camera only to read the pairing code.", style = MBType.callout, textAlign = TextAlign.Center)
                                PrimaryButton("Allow camera") { permission.launch(Manifest.permission.CAMERA) }
                            }
                        } else {
                            BrandMark(48.dp, live = true)
                        }
                    }
                }
                if (error != null) {
                    item {
                        Panel {
                            Text(error!!, style = MBType.callout.copy(color = MB.danger))
                            Spacer(Modifier.size(Space.s))
                            SecondaryButton("Scan again") { scanned = false }
                        }
                    }
                }
                item {
                    Panel {
                        Eyebrow("No camera? Paste the pairing link")
                        Spacer(Modifier.size(Space.s))
                        OutlinedTextField(link, { link = it }, Modifier.fillMaxWidth(), placeholder = { Text("mybuddy://pair?…", style = MBType.mono) },
                            leadingIcon = { Icon(Icons.Rounded.Link, null, tint = MB.textTertiary) }, singleLine = true, colors = fieldColors())
                        Spacer(Modifier.size(Space.s))
                        SecondaryButton("Pair", enabled = link.isNotBlank()) {
                            scanned = true
                            vm.pair(link)
                        }
                    }
                }
            }
        }
    }
}

/** CameraX preview + ZXing QR decoding of the luminance plane (no Play Services needed). */
@Composable
private fun QrScanner(onResult: (String) -> Unit) {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    val executor = remember { Executors.newSingleThreadExecutor() }
    DisposableEffect(Unit) { onDispose { executor.shutdown() } }
    AndroidView(factory = { ctx ->
        val view = PreviewView(ctx)
        val future = ProcessCameraProvider.getInstance(ctx)
        future.addListener({
            val provider = future.get()
            val preview = Preview.Builder().build().also { it.setSurfaceProvider(view.surfaceProvider) }
            val analysis = ImageAnalysis.Builder().setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST).build()
            val reader = QRCodeReader()
            val hints = mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE), DecodeHintType.TRY_HARDER to true)
            analysis.setAnalyzer(executor) { image ->
                try {
                    val plane = image.planes[0]
                    val buffer = plane.buffer
                    val data = ByteArray(buffer.remaining()).also { buffer.get(it) }
                    val source = PlanarYUVLuminanceSource(data, plane.rowStride, image.height, 0, 0, image.width, image.height, false)
                    val text = reader.decode(BinaryBitmap(HybridBinarizer(source)), hints).text
                    ContextCompat.getMainExecutor(ctx).execute { onResult(text) }
                } catch (e: Exception) {
                    // No QR code in this frame.
                } finally {
                    reader.reset()
                    image.close()
                }
            }
            provider.unbindAll()
            provider.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
        }, ContextCompat.getMainExecutor(context))
        view
    }, modifier = Modifier.fillMaxWidth().aspectRatio(1f))
}

// endregion

// region Health

@Composable
fun HealthScreen(vm: AppViewModel, nav: NavHostController) {
    val health by vm.health.collectAsState()
    Page("Mac health", vm, nav, back = true, trailing = {
        IconButton({ vm.refreshHealth() }) { Icon(Icons.Rounded.Refresh, "Refresh", tint = MB.textSecondary) }
    }) {
        when (val h = health) {
            is Load.Ready -> {
                val v = h.value
                item {
                    Panel {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            RingGauge(v.batteryPercent?.let { it / 100f }, if ((v.batteryPercent ?: 100) <= 20) Tone.Warning else Tone.Live, size = 110.dp) {
                                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                    Text(v.batteryPercent?.let { "$it%" } ?: "—", style = MBType.title)
                                    Text(if (v.charging) "Charging" else "Battery", style = MBType.caption)
                                }
                            }
                            Spacer(Modifier.width(Space.l))
                            Column(Modifier.weight(1f)) {
                                Text("Measured ${v.collectedAt}", style = MBType.bodyEmphasis)
                                Text("Values come straight from macOS unless marked derived or estimated.", style = MBType.caption)
                            }
                        }
                    }
                }
                item { Panel { SectionHeader("Battery"); v.batteryRows.forEach { HealthLine(it) } } }
                if (v.volumes.isNotEmpty()) {
                    item {
                        Panel {
                            SectionHeader("Storage")
                            v.volumes.forEach { vol ->
                                Spacer(Modifier.size(Space.s))
                                Row { Text(vol.name, style = MBType.bodyEmphasis, modifier = Modifier.weight(1f)); Text("${vol.free} free of ${vol.total}", style = MBType.callout) }
                                UsageBar(vol.usedFraction, if (vol.usedFraction > 0.85f) Tone.Warning else Tone.Info)
                            }
                        }
                    }
                }
                item { Panel { SectionHeader("System"); v.systemRows.forEach { HealthLine(it) } } }
            }
            is Load.Loading -> item { StateMessage(StateKind.Loading, "Measuring your Mac…", "This takes about a second.") }
            is Load.Failed -> item { StateMessage(StateKind.Error, "Couldn’t get health data", h.message) { SecondaryButton("Try again") { vm.refreshHealth() } } }
            is Load.NotAuthorized -> item { StateMessage(StateKind.NotAuthorized, "Health is off for this phone", h.reason) }
            is Load.Unavailable -> item { StateMessage(StateKind.Offline, "Not connected", h.reason) }
            Load.Idle -> item { StateMessage(StateKind.Offline, "Not connected", "Connect to your Mac to see its health.") { SecondaryButton("Load") { vm.refreshHealth() } } }
        }
    }
}

@Composable
private fun HealthLine(r: HealthRow) {
    MetricRow(r.label, r.value, r.source?.takeIf { it.isNotBlank() && it != "—" }, r.note)
}

// endregion

// region Settings

@Composable
fun SettingsScreen(vm: AppViewModel, nav: NavHostController) {
    val host by vm.pairedHost.collectAsState()
    val state by vm.connection.collectAsState()
    val demo by vm.demo.collectAsState()
    var confirmForget by remember { mutableStateOf(false) }
    Page("Settings", vm, nav, back = true) {
        item {
            Panel {
                SectionHeader("Your Mac")
                if (host == null) {
                    Text("Not paired.", style = MBType.callout)
                    Spacer(Modifier.size(Space.s))
                    PrimaryButton("Pair with your Mac") { nav.navigate("pairing") }
                } else {
                    MetricRow("Name", host!!.name)
                    MetricRow("Device ID", host!!.deviceId.take(12) + "…")
                    MetricRow("Status", vm.statusTitle(state), tone = toneOf(state))
                    Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                        if (state.isConnected) SecondaryButton("Disconnect") { vm.disconnect() } else SecondaryButton("Connect") { vm.reconnect() }
                        if (!confirmForget) SecondaryButton("Forget", tone = Tone.Danger) { confirmForget = true }
                        else PrimaryButton("Confirm forget") { vm.forgetMac(); confirmForget = false }
                    }
                }
            }
        }
        host?.let { h -> item { ConnectionsPanel(vm, h, state) } }
        if (host != null) item { NotificationsPanel(vm) }
        item {
            Panel {
                SectionHeader("This phone")
                MetricRow("Device ID", vm.deviceId.take(12) + "…")
                MetricRow("Private key", vm.identityBackend, tone = if (vm.identityBackend.contains("StrongBox") || vm.identityBackend.contains("Trusted")) Tone.Live else Tone.Warning)
                MetricRow("App version", BuildConfig.VERSION_NAME)
            }
        }
        item {
            Panel {
                SectionHeader("Privacy")
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = Space.xs)) {
                    Icon(Icons.Rounded.Lock, null, tint = MB.accent)
                    Spacer(Modifier.width(Space.m))
                    Text("Everything between this phone and your Mac is end-to-end encrypted. AI keys stay on the Mac. No analytics.", style = MBType.callout)
                }
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = Space.xs)) {
                    Icon(Icons.AutoMirrored.Rounded.Chat, null, tint = MB.info)
                    Spacer(Modifier.width(Space.m))
                    Text("Voice listens only while you hold the talk button. No wake word.", style = MBType.callout)
                }
            }
        }
        item {
            Panel {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Preview data", style = MBType.bodyEmphasis)
                        Text("Shows sample data with a badge, for demos. Turn off for real use.", style = MBType.caption)
                    }
                    Switch(demo, { vm.setDemo(it) }, colors = SwitchDefaults.colors(checkedTrackColor = MB.accent, checkedThumbColor = MB.onAccent))
                }
            }
        }
    }
}

// endregion

// region Voice

@Composable
fun VoiceSheet(vm: AppViewModel) {
    val context = LocalContext.current
    val ui by vm.voice.ui.collectAsState()
    val last by vm.lastVoice.collectAsState()
    val state by vm.connection.collectAsState()
    val session by vm.session.collectAsState()
    val demo by vm.demo.collectAsState()
    // Say why voice can't run instead of letting someone talk into a dead end.
    val blocked: String? = when {
        demo -> null
        !state.isConnected -> "Connect to your Mac to use voice commands."
        session?.granted?.contains("voice.commands") != true -> "Voice commands are off for this phone. Turn on “Voice commands” for it in MyBuddy on your Mac."
        else -> null
    }
    var micGranted by remember { mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { micGranted = it }
    val phase = when (ui.phase) {
        VoicePhase.Idle -> OrbPhase.Idle
        VoicePhase.Listening -> OrbPhase.Listening
        VoicePhase.Thinking -> OrbPhase.Thinking
        VoicePhase.Speaking -> OrbPhase.Speaking
        VoicePhase.Error -> OrbPhase.Error
    }
    Column(Modifier.fillMaxWidth().padding(Space.xl).navigationBarsPadding(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Space.l)) {
        Text("MyBuddy Voice", style = MBType.title)
        VoiceOrb(phase, ui.level, size = 200.dp)
        Text(
            when {
                blocked != null -> blocked
                ui.phase == VoicePhase.Listening -> ui.caption.ifEmpty { "Listening…" }
                ui.phase == VoicePhase.Thinking -> "“${ui.caption}” — asking your Mac…"
                else -> ui.message ?: "Hold the button and speak. It only listens while you hold it."
            },
            style = MBType.body.copy(color = if (blocked != null) MB.warning else MB.textPrimary), textAlign = TextAlign.Center,
            modifier = Modifier.heightIn(min = 48.dp),
        )
        if (blocked == null) Box(
            Modifier.clip(CircleShape).background(if (ui.phase == VoicePhase.Listening) MB.accent else MB.elevatedHigh)
                .border(1.dp, if (ui.phase == VoicePhase.Listening) MB.accent else MB.borderStrong, CircleShape)
                .semantics { role = Role.Button; contentDescription = "Hold to talk" }
                .pointerInput(micGranted) {
                    awaitEachGesture {
                        awaitFirstDown()
                        if (!micGranted) {
                            permission.launch(Manifest.permission.RECORD_AUDIO)
                        } else {
                            vm.voice.start()
                            waitForUpOrCancellation()
                            vm.voice.release()
                        }
                    }
                }
                .padding(horizontal = Space.xxl, vertical = Space.l),
        ) {
            Text(if (ui.phase == VoicePhase.Listening) "Release to send" else "Hold to talk",
                style = MBType.bodyEmphasis.copy(color = if (ui.phase == VoicePhase.Listening) MB.onAccent else MB.textPrimary))
        }
        if (ui.onDevice) Text("Recognized on this phone", style = MBType.caption)
        last?.let {
            Panel {
                Text("“${it.transcript}”", style = MBType.bodyEmphasis)
                Spacer(Modifier.size(Space.xs))
                Text(it.summary, style = MBType.callout)
                Spacer(Modifier.size(Space.xs))
                StatusPill(it.status, if (it.status == "succeeded") Tone.Live else Tone.Warning)
            }
        }
        Text("Risky actions always ask for approval on your Mac. Destructive commands are refused.", style = MBType.caption, textAlign = TextAlign.Center)
    }
}

// endregion
