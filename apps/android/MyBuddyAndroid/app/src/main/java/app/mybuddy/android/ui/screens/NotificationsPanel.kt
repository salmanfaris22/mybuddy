package app.mybuddy.android.ui.screens

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import app.mybuddy.android.AppViewModel
import app.mybuddy.android.core.notifications.PreviewPolicy
import app.mybuddy.android.ui.components.Eyebrow
import app.mybuddy.android.ui.components.Panel
import app.mybuddy.android.ui.components.SecondaryButton
import app.mybuddy.android.ui.components.SectionHeader
import app.mybuddy.android.ui.components.StatusPill
import app.mybuddy.android.ui.theme.MB
import app.mybuddy.android.ui.theme.MBType
import app.mybuddy.android.ui.theme.Space
import app.mybuddy.android.ui.theme.Tone

/** Phone → Mac notification mirroring: Android access, master switch, preview policy, Do Not Disturb, app filters. */
@Composable
fun NotificationsPanel(vm: AppViewModel) {
    val mirror = vm.notifications
    val config by mirror.config.collectAsState()
    val connected by mirror.listenerConnected.collectAsState()
    val apps by mirror.recentApps.collectAsState()
    val sent by mirror.sentThisSession.collectAsState()
    val reason by mirror.blockedReason.collectAsState()
    val session by vm.session.collectAsState()
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    var access by remember { mutableStateOf(mirror.accessGranted()) }
    // Re-check after returning from Android's settings screen.
    LaunchedEffect(owner) { owner.lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) { access = mirror.accessGranted() } }
    val macAllows = session?.granted?.contains("notifications.mirror") == true

    Panel {
        SectionHeader("Notifications on your Mac", "Your phone’s notifications appear in MyBuddy on the Mac — only while connected, never stored there.")
        Row(Modifier.fillMaxWidth().padding(top = Space.s), verticalAlignment = Alignment.CenterVertically) {
            Text("Notification access", style = MBType.bodyEmphasis, modifier = Modifier.weight(1f))
            StatusPill(if (access) (if (connected) "Allowed" else "Allowed · starting") else "Not allowed", if (access) Tone.Live else Tone.Neutral)
        }
        Text(
            if (access) "Android lets MyBuddy read notifications. You can withdraw this any time in Android’s settings."
            else "Android must allow MyBuddy to read notifications. You decide on the next screen; MyBuddy never turns it on by itself.",
            style = MBType.caption, modifier = Modifier.padding(top = 2.dp),
        )
        SecondaryButton(if (access) "Change in Android settings" else "Open Android settings", modifier = Modifier.padding(top = Space.s)) {
            runCatching { context.startActivity(mirror.accessSettingsIntent()) }
        }
        if (!access) {
            Text("If Android says the setting is restricted: App info → ⋮ → Allow restricted settings, then try again.",
                style = MBType.caption, modifier = Modifier.padding(top = Space.xs))
        }

        Spacer(Modifier.size(Space.m))
        SwitchRow("Mirror notifications to your Mac", config.enabled) { mirror.setEnabled(it) }
        Text("Master switch. Off stops everything at once, whatever the other settings are.", style = MBType.caption)

        Spacer(Modifier.size(Space.m))
        Eyebrow("What your Mac sees")
        Row(Modifier.horizontalScroll(rememberScrollState()).padding(top = Space.xs), horizontalArrangement = Arrangement.spacedBy(Space.s)) {
            PreviewPolicy.entries.forEach { p ->
                FilterChip(config.preview == p, { mirror.setPreview(p) }, { Text(p.title) },
                    colors = FilterChipDefaults.filterChipColors(selectedContainerColor = MB.accent, selectedLabelColor = MB.onAccent, containerColor = MB.elevated, labelColor = MB.textSecondary))
            }
        }
        Text("Codes, keys and card numbers are masked even with full previews. Ongoing and silent notifications are never sent.",
            style = MBType.caption, modifier = Modifier.padding(top = Space.xs))

        Spacer(Modifier.size(Space.s))
        SwitchRow("Pause while Do Not Disturb is on", config.pauseInDnd) { mirror.setPauseInDnd(it) }

        if (config.enabled) {
            Spacer(Modifier.size(Space.s))
            val status = when {
                !access -> "Waiting for notification access."
                !macAllows && session != null -> "Allow “Mirror notifications” for this phone in MyBuddy on your Mac."
                reason != null -> reason!!
                else -> "Mirroring · $sent sent in this session"
            }
            Text(status, style = MBType.caption.copy(color = if (status.startsWith("Mirroring")) MB.accent else MB.warning))
            Text("Keeps the connection to your Mac open in the background, which uses some battery.", style = MBType.caption, modifier = Modifier.padding(top = 2.dp))
        }

        MacAlertsPermission()

        if (apps.isNotEmpty()) {
            Spacer(Modifier.size(Space.m))
            Eyebrow("Apps")
            apps.entries.sortedBy { it.value.lowercase() }.forEach { (pkg, label) ->
                SwitchRow(label, pkg !in config.blocked) { allowed -> mirror.setBlocked(pkg, !allowed) }
            }
            Text("Apps appear here once they post a notification.", style = MBType.caption)
        }
    }
}

/** Alerts from the Mac (battery low, going to sleep) show as phone notifications only with Android's permission. */
@Composable
private fun MacAlertsPermission() {
    if (Build.VERSION.SDK_INT < 33) return
    val context = LocalContext.current
    var granted by remember { mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted = it }
    Spacer(Modifier.size(Space.m))
    Eyebrow("Alerts from your Mac")
    if (granted) {
        Text("Your Mac’s MyBuddy alerts (battery low, going to sleep) appear as notifications here.", style = MBType.caption, modifier = Modifier.padding(top = Space.xs))
    } else {
        Text("To see your Mac’s alerts (battery low, going to sleep) as phone notifications, allow MyBuddy to notify you.",
            style = MBType.caption, modifier = Modifier.padding(top = Space.xs))
        SecondaryButton("Allow notifications", modifier = Modifier.padding(top = Space.xs)) { ask.launch(Manifest.permission.POST_NOTIFICATIONS) }
    }
}

/** The whole row toggles (one large touch target, one accessibility node with the switch role). */
@Composable
private fun SwitchRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(value = checked, role = Role.Switch, onValueChange = onChange),
        verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = MBType.body, modifier = Modifier.weight(1f))
        Switch(checked, onCheckedChange = null, colors = SwitchDefaults.colors(checkedTrackColor = MB.accent))
    }
}
