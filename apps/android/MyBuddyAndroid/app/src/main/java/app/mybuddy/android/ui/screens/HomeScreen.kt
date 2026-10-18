package app.mybuddy.android.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.Bolt
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.EditNote
import androidx.compose.material.icons.rounded.Laptop
import androidx.compose.material.icons.rounded.Mouse
import androidx.compose.material.icons.rounded.Public
import androidx.compose.material.icons.rounded.QrCodeScanner
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import app.mybuddy.android.AppViewModel
import app.mybuddy.android.core.session.ConnectionState
import app.mybuddy.android.data.Formats
import app.mybuddy.android.data.Load
import app.mybuddy.android.ui.Page
import app.mybuddy.android.ui.components.Eyebrow
import app.mybuddy.android.ui.components.OrbPhase
import app.mybuddy.android.ui.components.Panel
import app.mybuddy.android.ui.components.PrimaryButton
import app.mybuddy.android.ui.components.RingGauge
import app.mybuddy.android.ui.components.SecondaryButton
import app.mybuddy.android.ui.components.SectionHeader
import app.mybuddy.android.ui.components.StatusPill
import app.mybuddy.android.ui.components.UsageBar
import app.mybuddy.android.ui.components.VoiceOrb
import app.mybuddy.android.ui.theme.MB
import app.mybuddy.android.ui.theme.MBType
import app.mybuddy.android.ui.theme.Space
import app.mybuddy.android.ui.theme.Tone

fun toneOf(s: ConnectionState): Tone = when (s) {
    is ConnectionState.DirectConnected -> Tone.Live
    is ConnectionState.RelayedConnected -> Tone.Info
    is ConnectionState.Failed -> Tone.Danger
    is ConnectionState.Connecting, is ConnectionState.Reconnecting, is ConnectionState.Pairing, is ConnectionState.AwaitingApproval -> Tone.Warning
    else -> Tone.Neutral
}

@Composable
fun HomeScreen(vm: AppViewModel, nav: NavHostController, onVoice: () -> Unit) {
    val host by vm.pairedHost.collectAsState()
    val state by vm.connection.collectAsState()
    val session by vm.session.collectAsState()
    val rtt by vm.rttMs.collectAsState()
    val health by vm.health.collectAsState()
    val provider by vm.providerLine.collectAsState()
    val activity by vm.activity.collectAsState()
    val internetOffer by vm.internetOffer.collectAsState()
    val internetBusy by vm.internetBusy.collectAsState()
    val internetMessage by vm.internetMessage.collectAsState()

    Page("MyBuddy", vm, trailing = {
        IconButton({ nav.navigate("settings") }) { Icon(Icons.Rounded.Settings, "Settings", tint = MB.textSecondary) }
    }) {
        item {
            if (host == null) {
                Panel {
                    Eyebrow("Get started")
                    Spacer(Modifier.size(Space.s))
                    Text("Pair with your Mac", style = MBType.hero)
                    Spacer(Modifier.size(Space.xs))
                    Text("On your Mac, open MyBuddy → Pair a phone. Scan the code, then approve on the Mac after checking that both screens show the same 6-digit number.",
                        style = MBType.callout)
                    Spacer(Modifier.size(Space.l))
                    PrimaryButton("Scan pairing code", Modifier.fillMaxWidth(), icon = Icons.Rounded.QrCodeScanner) { nav.navigate("pairing") }
                }
            } else {
                Panel {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Rounded.Laptop, null, tint = MB.info, modifier = Modifier.size(22.dp))
                        Spacer(Modifier.width(Space.s))
                        Text(session?.hostName ?: host!!.name, style = MBType.hero, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    Spacer(Modifier.size(Space.s))
                    Row(horizontalArrangement = Arrangement.spacedBy(Space.s), verticalAlignment = Alignment.CenterVertically) {
                        StatusPill(vm.statusTitle(state), toneOf(state), pulsing = state.isConnected)
                        if (rtt != null) Text("${rtt} ms", style = MBType.mono)
                    }
                    if (state is ConnectionState.Failed) {
                        Spacer(Modifier.size(Space.s))
                        Text((state as ConnectionState.Failed).reason, style = MBType.callout.copy(color = MB.danger))
                    }
                    Spacer(Modifier.size(Space.l))
                    if (state.isConnected) {
                        PrimaryButton("Open remote", Modifier.fillMaxWidth(), icon = Icons.Rounded.Mouse) { nav.navigate("remote") }
                        Spacer(Modifier.size(Space.xs))
                        val granted = session?.granted ?: emptySet()
                        val canView = "screen.view" in granted && "screen" in (session?.features ?: emptySet())
                        val canControl = "input.control" in granted
                        Text(
                            when {
                                canView && canControl -> "See your Mac’s screen and control it with touch, touchpad and keyboard."
                                canView -> "See your Mac’s screen. Mouse & keyboard control is off for this phone — turn it on in MyBuddy on your Mac."
                                canControl -> "Touchpad & keyboard work. Screen viewing is off for this phone — turn it on in MyBuddy on your Mac."
                                else -> "Screen viewing and control are off for this phone — turn them on in MyBuddy on your Mac."
                            },
                            style = MBType.caption,
                        )
                    } else {
                        SecondaryButton("Connect", Modifier.fillMaxWidth(), icon = Icons.Rounded.Bolt) { vm.reconnect() }
                    }
                }
            }
        }
        internetOffer?.let { offer ->
            item {
                Panel {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Rounded.Public, null, tint = MB.warning, modifier = Modifier.size(20.dp))
                        Spacer(Modifier.width(Space.s))
                        Text("Internet access offered", style = MBType.headline)
                    }
                    Spacer(Modifier.size(Space.xs))
                    Text("Your Mac can also be reached away from home through ${offer.serverUrl.substringAfter("://")}, a server its owner runs. " +
                        "Only used when Wi-Fi and Tailscale don’t answer; it never sees your content.", style = MBType.callout)
                    internetMessage?.let { Text(it, style = MBType.caption.copy(color = MB.warning), modifier = Modifier.padding(top = Space.xs)) }
                    Spacer(Modifier.size(Space.m))
                    Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                        PrimaryButton(if (internetBusy) "Allowing…" else "Allow", enabled = !internetBusy) { vm.allowInternetAccess() }
                        SecondaryButton("Not now", enabled = !internetBusy) { vm.declineInternetOffer() }
                    }
                }
            }
        }
        if (host != null) {
            item {
                Panel(Modifier.clickable(role = Role.Button) { nav.navigate("health") }) {
                    SectionHeader("Mac health", (health as? Load.Ready)?.value?.let { "Measured ${it.collectedAt}" } ?: "Tap for details") {
                        Icon(Icons.Rounded.ChevronRight, null, tint = MB.textTertiary)
                    }
                    Spacer(Modifier.size(Space.m))
                    when (val h = health) {
                        is Load.Ready -> Row(verticalAlignment = Alignment.CenterVertically) {
                            val pct = h.value.batteryPercent
                            RingGauge(pct?.let { it / 100f }, if ((pct ?: 100) <= 20) Tone.Warning else Tone.Live, size = 84.dp, stroke = 8.dp) {
                                Text(pct?.let { "$it%" } ?: "—", style = MBType.headline)
                            }
                            Spacer(Modifier.width(Space.l))
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                                h.value.batteryRows.firstOrNull { it.label == "Condition" }?.let { Text("Battery ${it.value}", style = MBType.bodyEmphasis) }
                                h.value.volumes.firstOrNull()?.let { v ->
                                    Text("${v.free} free of ${v.total}", style = MBType.callout)
                                    UsageBar(v.usedFraction, if (v.usedFraction > 0.85f) Tone.Warning else Tone.Info)
                                }
                            }
                        }
                        is Load.Loading -> Text("Measuring…", style = MBType.callout)
                        is Load.Failed -> Text(h.message, style = MBType.callout.copy(color = MB.danger))
                        is Load.Unavailable -> Text(h.reason, style = MBType.callout)
                        is Load.NotAuthorized -> Text(h.reason, style = MBType.callout.copy(color = MB.warning))
                        Load.Idle -> Text("Connect to your Mac to see its health.", style = MBType.callout)
                    }
                }
            }
            item {
                Panel(Modifier.clickable(role = Role.Button, onClick = onVoice)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        VoiceOrb(OrbPhase.Idle, 0f, size = 64.dp)
                        Spacer(Modifier.width(Space.l))
                        Column(Modifier.weight(1f)) {
                            Text("MyBuddy Voice", style = MBType.headline)
                            Text("Hold to talk. “Show my Mac battery health”", style = MBType.callout)
                        }
                    }
                }
            }
            item {
                Panel(Modifier.clickable(role = Role.Button) { nav.navigate("ai") }) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Rounded.AutoAwesome, null, tint = MB.info)
                        Spacer(Modifier.width(Space.m))
                        Column(Modifier.weight(1f)) {
                            Text("Assistant", style = MBType.headline)
                            Text(provider ?: "Runs on your Mac with the provider chosen there. This phone holds no API keys.", style = MBType.callout)
                        }
                        Icon(Icons.Rounded.ChevronRight, null, tint = MB.textTertiary)
                    }
                }
            }
            item {
                val notes by vm.notes.notes.collectAsState()
                Panel(Modifier.clickable(role = Role.Button) { nav.navigate("notes") }) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Rounded.EditNote, null, tint = MB.info)
                        Spacer(Modifier.width(Space.m))
                        Column(Modifier.weight(1f)) {
                            Text("Notes", style = MBType.headline)
                            Text(notes.firstOrNull()?.title?.let { "${notes.size} · latest: $it" } ?: "Shared with your Mac, kept on your two devices",
                                style = MBType.callout, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                        Icon(Icons.Rounded.ChevronRight, null, tint = MB.textTertiary)
                    }
                }
            }
            if ((session?.sharedFolders?.size ?: 0) > 0) {
                item {
                    Panel(Modifier.clickable(role = Role.Button) { nav.navigate("files") }) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Rounded.Folder, null, tint = MB.info)
                            Spacer(Modifier.width(Space.m))
                            Text("${session!!.sharedFolders.size} shared folder(s) on your Mac", style = MBType.bodyEmphasis, modifier = Modifier.weight(1f))
                            Icon(Icons.Rounded.ChevronRight, null, tint = MB.textTertiary)
                        }
                    }
                }
            }
        }
        if (activity.isNotEmpty()) {
            item {
                Panel {
                    SectionHeader("Recent activity")
                    Spacer(Modifier.size(Space.s))
                    activity.take(4).forEach { a ->
                        Row(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
                            Text(a.title, style = MBType.body, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(Formats.relative(a.at), style = MBType.caption)
                        }
                    }
                }
            }
        }
    }
}
