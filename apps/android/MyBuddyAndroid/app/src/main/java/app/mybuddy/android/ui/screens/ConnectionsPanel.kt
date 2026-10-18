package app.mybuddy.android.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Public
import androidx.compose.material.icons.rounded.VpnLock
import androidx.compose.material.icons.rounded.Wifi
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import app.mybuddy.android.AppViewModel
import app.mybuddy.android.BuildConfig
import app.mybuddy.android.core.connect.SessionRoute
import app.mybuddy.android.core.session.ConnectionState
import app.mybuddy.android.core.session.Tailnet
import app.mybuddy.android.data.PairedHost
import app.mybuddy.android.data.TailscaleApp
import app.mybuddy.android.ui.components.Panel
import app.mybuddy.android.ui.components.PrimaryButton
import app.mybuddy.android.ui.components.SecondaryButton
import app.mybuddy.android.ui.components.SectionHeader
import app.mybuddy.android.ui.components.StatusPill
import app.mybuddy.android.ui.theme.MB
import app.mybuddy.android.ui.theme.MBType
import app.mybuddy.android.ui.theme.Space
import app.mybuddy.android.ui.theme.Tone

/** How this phone reaches the Mac: same Wi-Fi, Tailscale, or the internet through MyBuddy Connect (docs/CONNECTIVITY.md). */
@Composable
fun ConnectionsPanel(vm: AppViewModel, host: PairedHost, state: ConnectionState) {
    val route by vm.route.collectAsState()
    val tailscale by vm.tailscale.collectAsState()
    val context = LocalContext.current
    var adding by remember { mutableStateOf(false) }
    var entry by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) { vm.refreshTailscale() }
    val wifi = host.addresses.filter { Tailnet.route(it) == Tailnet.Route.Wifi }
    val tail = host.addresses.filter { Tailnet.route(it) == Tailnet.Route.Tailscale }

    Panel {
        SectionHeader("Connections", "How this phone reaches your Mac. Every route is end-to-end encrypted.")
        RouteRow(
            Icons.Rounded.Wifi, "Same network (Wi-Fi)",
            status = when {
                state.isConnected && route == SessionRoute.WIFI -> "Connected"
                wifi.isEmpty() -> "No address"
                else -> "Ready"
            },
            tone = if (state.isConnected && route == SessionRoute.WIFI) Tone.Live else Tone.Neutral,
            detail = "Phone and Mac on the same Wi-Fi. If the Mac’s address changes, this phone finds it again on the network.",
        )
        wifi.forEach { AddressLine(it, removable = false) {} }

        Spacer(Modifier.size(Space.m))
        RouteRow(
            Icons.Rounded.VpnLock, "Tailscale",
            status = when {
                state.isConnected && route == SessionRoute.TAILSCALE -> "Connected"
                tail.isEmpty() -> "Not set up"
                !tailscale.installed -> "App not installed"
                !tailscale.vpnActive -> "VPN off"
                else -> "Ready"
            },
            tone = when {
                state.isConnected && route == SessionRoute.TAILSCALE -> Tone.Live
                tail.isNotEmpty() && tailscale.installed && !tailscale.vpnActive -> Tone.Warning
                else -> Tone.Neutral
            },
            detail = "Reach your Mac from anywhere through your own tailnet: install Tailscale on the Mac and this phone and sign in to the same account. Wi-Fi is tried first.",
        )
        tail.forEach { AddressLine(it, removable = host.addresses.size > 1) { vm.removeAddress(it) } }
        if (adding) {
            OutlinedTextField(
                entry, { entry = it; error = null }, Modifier.fillMaxWidth(), singleLine = true, colors = fieldColors(),
                placeholder = { Text("100.x.y.z or mac.your-tailnet.ts.net", style = MBType.callout) },
            )
            error?.let { Text(it, style = MBType.caption.copy(color = MB.warning), modifier = Modifier.padding(top = Space.xs)) }
            Spacer(Modifier.size(Space.s))
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                PrimaryButton("Save") {
                    error = vm.addTailscaleAddress(entry)
                    if (error == null) {
                        adding = false
                        entry = ""
                    }
                }
                SecondaryButton("Cancel") {
                    adding = false
                    error = null
                }
            }
            Text("Find it on your Mac: MyBuddy → Settings → Connections → Tailscale.", style = MBType.caption, modifier = Modifier.padding(top = Space.xs))
        } else {
            Spacer(Modifier.size(Space.xs))
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                SecondaryButton("Add address", icon = Icons.Rounded.Add) { adding = true }
                SecondaryButton(if (tailscale.installed) "Open Tailscale" else "Get Tailscale") { TailscaleApp.open(context) }
            }
        }
        if (tailscale.vpnActive) {
            Text("A VPN is on" + if (tailscale.installed) " (Tailscale is installed)." else ".", style = MBType.caption, modifier = Modifier.padding(top = Space.xs))
        }

        Spacer(Modifier.size(Space.m))
        InternetRow(vm, host, state, route)
    }
}

/** Internet access through the Mac owner's MyBuddy Connect server: offered by the Mac, agreed to here. */
@Composable
private fun InternetRow(vm: AppViewModel, host: PairedHost, state: ConnectionState, route: SessionRoute?) {
    val offer by vm.internetOffer.collectAsState()
    val busy by vm.internetBusy.collectAsState()
    val message by vm.internetMessage.collectAsState()
    val forceRelay by vm.forceRelay.collectAsState()
    val server = host.connectUrl?.substringAfter("://")
    RouteRow(
        Icons.Rounded.Public, "Internet (MyBuddy Connect)",
        status = when {
            state.isConnected && route == SessionRoute.INTERNET_RELAYED -> "Connected · relayed"
            state.isConnected && route == SessionRoute.INTERNET_DIRECT -> "Connected"
            offer != null -> "Offered by your Mac"
            server != null -> "On · $server"
            else -> "Not set up"
        },
        tone = when {
            state.isConnected && route?.isInternet == true -> Tone.Live
            offer != null -> Tone.Warning
            server != null -> Tone.Info
            else -> Tone.Neutral
        },
        detail = "Away from home without Tailscale, through a server your Mac’s owner runs. It only introduces this phone to your Mac; if no direct path exists it relays encrypted packets, and file transfer then stays off. Used only when Wi-Fi and Tailscale don’t answer.",
    )
    offer?.let { o ->
        Text("Allow internet access through ${o.serverUrl.substringAfter("://")}? This phone registers its key with that server; nothing else is shared.",
            style = MBType.callout, modifier = Modifier.padding(start = 34.dp, top = Space.xs))
        Row(Modifier.padding(start = 34.dp, top = Space.s), horizontalArrangement = Arrangement.spacedBy(Space.s)) {
            PrimaryButton(if (busy) "Allowing…" else "Allow", enabled = !busy) { vm.allowInternetAccess() }
            SecondaryButton("Not now", enabled = !busy) { vm.declineInternetOffer() }
        }
    }
    if (offer == null && server != null) {
        Row(Modifier.padding(start = 34.dp, top = Space.xs)) {
            SecondaryButton("Remove internet access", enabled = !busy) { vm.removeInternetAccess() }
        }
    }
    if (offer == null && server == null) {
        Text("Turn it on in MyBuddy on your Mac (Settings → Connections → Internet), then connect once over Wi-Fi or Tailscale.",
            style = MBType.caption, modifier = Modifier.padding(start = 34.dp, top = Space.xs))
    }
    message?.let { Text(it, style = MBType.caption.copy(color = MB.warning), modifier = Modifier.padding(start = 34.dp, top = Space.xs)) }
    if (BuildConfig.DEBUG && server != null) {
        // Test switch (debug builds only): proves the TURN relay path by refusing direct candidates.
        Row(Modifier.fillMaxWidth().padding(start = 34.dp, top = Space.xs), verticalAlignment = Alignment.CenterVertically) {
            Text("Force TURN relay (testing)", style = MBType.caption, modifier = Modifier.weight(1f))
            Switch(forceRelay, { vm.setForceRelay(it) }, colors = SwitchDefaults.colors(checkedTrackColor = MB.accent))
        }
    }
}

@Composable
private fun RouteRow(icon: ImageVector, title: String, status: String, tone: Tone, detail: String) {
    Row(verticalAlignment = Alignment.Top, modifier = Modifier.semantics(mergeDescendants = true) { contentDescription = "$title: $status" }) {
        Icon(icon, null, tint = if (tone == Tone.Live) MB.accent else MB.textSecondary, modifier = Modifier.padding(top = 2.dp).size(22.dp))
        Spacer(Modifier.width(Space.m))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                Text(title, style = MBType.bodyEmphasis)
                StatusPill(status, tone)
            }
            Text(detail, style = MBType.caption, modifier = Modifier.padding(top = 2.dp))
        }
    }
}

@Composable
private fun AddressLine(address: String, removable: Boolean, onRemove: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(start = 34.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(address, style = MBType.mono, modifier = Modifier.weight(1f))
        if (removable) IconButton(onRemove) { Icon(Icons.Rounded.Close, "Remove $address", tint = MB.textTertiary) }
    }
}
