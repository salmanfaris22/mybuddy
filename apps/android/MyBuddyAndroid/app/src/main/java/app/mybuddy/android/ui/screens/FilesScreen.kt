package app.mybuddy.android.ui.screens

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Send
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.Description
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Upload
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.navigation.NavHostController
import app.mybuddy.android.AppViewModel
import app.mybuddy.android.data.ClipboardBridge
import app.mybuddy.android.data.Formats
import app.mybuddy.android.data.Load
import app.mybuddy.android.data.TransferUi
import app.mybuddy.android.ui.Page
import app.mybuddy.android.ui.components.Eyebrow
import app.mybuddy.android.ui.components.Panel
import app.mybuddy.android.ui.components.PrimaryButton
import app.mybuddy.android.ui.components.SecondaryButton
import app.mybuddy.android.ui.components.SectionHeader
import app.mybuddy.android.ui.components.StateKind
import app.mybuddy.android.ui.components.StateMessage
import app.mybuddy.android.ui.theme.MB
import app.mybuddy.android.ui.theme.MBType
import app.mybuddy.android.ui.theme.Radius
import app.mybuddy.android.ui.theme.Space

@Composable
fun FilesScreen(vm: AppViewModel, nav: NavHostController) {
    val session by vm.session.collectAsState()
    val files by vm.files.collectAsState()
    val path by vm.filePath.collectAsState()
    val notice by vm.remoteNotice.collectAsState()
    val transfers by vm.transfers.items.collectAsState()
    val route by vm.route.collectAsState()
    var chosen by remember { mutableStateOf<String?>(null) }
    val folders = session?.sharedFolders ?: emptyList()
    val canBrowse = session?.granted?.contains("files.browse") == true && folders.isNotEmpty()
    val canTransfer = session?.granted?.contains("files.transfer") == true
    val canClipboard = session?.granted?.contains("clipboard.sync") == true
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> uri?.let(vm::sendFileToMac) }

    Page("Files", vm, nav) {
        if (session == null) {
            item { StateMessage(StateKind.Offline, "Connect to your Mac", "Shared folders, transfers and the clipboard appear here once you’re connected.") }
            return@Page
        }
        if (notice != null) item { Text(notice!!, style = MBType.callout.copy(color = MB.accent)) }

        item { SectionHeader("Shared folders", if (canBrowse) "Only folders you shared on the Mac are visible" else null) }
        if (!canBrowse) {
            item {
                StateMessage(StateKind.NotAuthorized, "No shared folders",
                    "On your Mac: Files & Clipboard → Grant Folder Access, then allow “Browse shared folders” for this phone. Only those folders are visible here.")
            }
        } else {
            item {
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    folders.forEach { (id, name) ->
                        FilterChip(path?.first == id, { vm.openFolder(id, "") }, { Text(name) }, leadingIcon = { Icon(Icons.Rounded.Folder, null, Modifier.size(16.dp)) },
                            colors = FilterChipDefaults.filterChipColors(selectedContainerColor = MB.accent, selectedLabelColor = MB.onAccent, selectedLeadingIconColor = MB.onAccent,
                                containerColor = MB.elevated, labelColor = MB.textSecondary, iconColor = MB.textSecondary))
                    }
                }
            }
            val current = path
            if (current == null) {
                item { Text("Choose a shared folder.", style = MBType.callout) }
            } else {
                item {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("${folders.firstOrNull { it.first == current.first }?.second ?: "Folder"}${if (current.second.isEmpty()) "" else " / ${current.second}"}",
                            style = MBType.bodyEmphasis, modifier = Modifier.weight(1f))
                        if (current.second.isNotEmpty()) SecondaryButton("Up") { vm.openFolder(current.first, current.second.substringBeforeLast('/', "")) }
                    }
                }
                when (val f = files) {
                    is Load.Ready -> {
                        if (f.value.isEmpty()) item { Text("This folder is empty.", style = MBType.callout) }
                        items(f.value, key = { it.name }) { e ->
                            Row(
                                Modifier.fillMaxWidth().clip(RoundedCornerShape(Radius.md)).background(MB.elevated)
                                    .clickable {
                                        val child = if (current.second.isEmpty()) e.name else "${current.second}/${e.name}"
                                        if (e.isFolder) vm.openFolder(current.first, child) else chosen = child
                                    }
                                    .padding(Space.m).heightIn(min = 32.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Icon(if (e.isFolder) Icons.Rounded.Folder else Icons.Rounded.Description, null, tint = if (e.isFolder) MB.info else MB.textSecondary)
                                Spacer(Modifier.width(Space.m))
                                Text(e.name, style = MBType.body, modifier = Modifier.weight(1f))
                                e.size?.let { Text(Formats.bytes(it), style = MBType.caption) }
                            }
                        }
                    }
                    is Load.Loading -> item { Text("Loading…", style = MBType.callout) }
                    is Load.Failed -> item { Text(f.message, style = MBType.callout.copy(color = MB.danger)) }
                    is Load.NotAuthorized -> item { Text(f.reason, style = MBType.callout.copy(color = MB.warning)) }
                    else -> item { Text("Choose a shared folder.", style = MBType.callout) }
                }
            }
        }

        item { TransfersPanel(vm, transfers, canTransfer, relayed = route?.allowsFileTransfer == false) { pick.launch(arrayOf("*/*")) } }
        item { ClipboardPanel(vm, canClipboard) }
    }

    chosen?.let { file ->
        val name = file.substringAfterLast('/')
        AlertDialog(
            onDismissRequest = { chosen = null },
            confirmButton = { PrimaryButton("Open on Mac") { vm.openFileOnMac(path!!.first, file); chosen = null } },
            dismissButton = {
                if (canTransfer) SecondaryButton("Download", icon = Icons.Rounded.Download) { vm.downloadFromMac(path!!.first, file); chosen = null }
                else SecondaryButton("Cancel") { chosen = null }
            },
            title = { Text("“$name”", style = MBType.headline) },
            text = {
                Text(if (canTransfer) "Open it with its default app on the Mac, or download a checksum-verified copy to this phone (Downloads/MyBuddy)."
                     else "It opens with its default app on the Mac. Allow “Send & receive files” on the Mac to download it.", style = MBType.callout)
            },
            containerColor = MB.elevated,
        )
    }
}

@Composable
private fun TransfersPanel(vm: AppViewModel, items: List<TransferUi>, canTransfer: Boolean, relayed: Boolean, onPick: () -> Unit) {
    Panel {
        SectionHeader("Transfers", "Encrypted end to end · SHA-256 verified")
        Spacer(Modifier.size(Space.s))
        if (!canTransfer) {
            Text("Sending and receiving files is off for this phone. On your Mac: Settings → Devices → allow “Send & receive files”.", style = MBType.caption)
            return@Panel
        }
        if (relayed) {
            Text(AppViewModel.RELAYED_TRANSFERS + " Connect over Wi-Fi or Tailscale to send files.", style = MBType.caption.copy(color = MB.warning))
            Spacer(Modifier.size(Space.s))
        }
        PrimaryButton("Send a file to your Mac", icon = Icons.Rounded.Upload, enabled = !relayed, onClick = onPick)
        val autoSave by vm.settings.autoSaveFromMac.collectAsState()
        Row(Modifier.fillMaxWidth().padding(top = Space.s).heightIn(min = 48.dp)
            .toggleable(value = autoSave, role = Role.Switch, onValueChange = { vm.settings.setAutoSaveFromMac(it) }),
            verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("Save files from your Mac automatically", style = MBType.body)
                Text(if (autoSave) "They go straight to Downloads/MyBuddy." else "Off: you choose Save or Decline for each file.", style = MBType.caption)
            }
            Switch(autoSave, onCheckedChange = null, colors = SwitchDefaults.colors(checkedTrackColor = MB.accent))
        }
        if (items.isNotEmpty()) NotificationHint()
        if (items.isEmpty()) {
            Spacer(Modifier.size(Space.s))
            Text("No transfers yet. To download, tap a file in a shared folder.", style = MBType.caption)
        }
        items.forEach { TransferRow(vm, it) }
        if (items.any { !it.active }) {
            Spacer(Modifier.size(Space.xs))
            SecondaryButton("Clear finished") { vm.transfers.clearFinished() }
        }
    }
}

@Composable
private fun TransferRow(vm: AppViewModel, t: TransferUi) {
    val context = LocalContext.current
    Column(Modifier.fillMaxWidth().padding(top = Space.m).semantics(mergeDescendants = true) { contentDescription = "${t.name}: ${stateText(t)}" }) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(if (t.toMac) Icons.Rounded.Upload else Icons.Rounded.Download, null, tint = MB.info)
            Spacer(Modifier.width(Space.s))
            Column(Modifier.weight(1f)) {
                Text(t.name, style = MBType.bodyEmphasis, maxLines = 1)
                Text("${if (t.toMac) "To your Mac" else "From your Mac"} · ${Formats.bytes(t.size)} · ${stateText(t)}", style = MBType.caption)
            }
            when (t.state) {
                TransferUi.State.InProgress -> {
                    IconButton({ vm.transfers.pause(t.id) }) { Icon(Icons.Rounded.Pause, "Pause", tint = MB.textSecondary) }
                    IconButton({ vm.transfers.cancel(t.id) }) { Icon(Icons.Rounded.Close, "Cancel", tint = MB.textSecondary) }
                }
                TransferUi.State.Paused -> {
                    IconButton({ vm.transfers.resume(t.id) }) { Icon(Icons.Rounded.PlayArrow, "Resume", tint = MB.textSecondary) }
                    IconButton({ vm.transfers.cancel(t.id) }) { Icon(Icons.Rounded.Close, "Cancel", tint = MB.textSecondary) }
                }
                TransferUi.State.WaitingForMac -> IconButton({ vm.transfers.cancel(t.id) }) { Icon(Icons.Rounded.Close, "Cancel", tint = MB.textSecondary) }
                else -> {}
            }
        }
        if (t.state in setOf(TransferUi.State.InProgress, TransferUi.State.Paused, TransferUi.State.Verifying)) {
            Spacer(Modifier.size(Space.xs))
            LinearProgressIndicator(progress = { t.fraction }, modifier = Modifier.fillMaxWidth(), color = MB.accent, trackColor = MB.elevatedHigh)
        }
        t.message?.let { Text(it, style = MBType.caption.copy(color = if (t.state == TransferUi.State.Failed) MB.danger else MB.textTertiary), modifier = Modifier.padding(top = 2.dp)) }
        if (t.state == TransferUi.State.Offered && !t.toMac) {
            Row(Modifier.padding(top = Space.s), horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                PrimaryButton("Save to phone") { vm.transfers.accept(t.id) }
                SecondaryButton("Decline") { vm.transfers.decline(t.id) }
            }
        }
        if (t.state == TransferUi.State.Done && t.uri != null) {
            SecondaryButton("Open", modifier = Modifier.padding(top = Space.s)) {
                val intent = Intent(Intent.ACTION_VIEW).setDataAndType(t.uri, context.contentResolver.getType(t.uri))
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                try {
                    context.startActivity(intent)
                } catch (e: ActivityNotFoundException) {
                    vm.remoteNotice.value = "No app on this phone can open “${t.name}”."
                }
            }
        }
    }
}

/**
 * Android 13+ shows a transfer's progress notification (which keeps it running while MyBuddy is in the
 * background) only with permission. Asked here, in context, never at launch; hidden once answered.
 */
@Composable
private fun NotificationHint() {
    if (Build.VERSION.SDK_INT < 33) return
    val context = LocalContext.current
    var granted by remember { mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) }
    var answered by remember { mutableStateOf(false) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok -> granted = ok; answered = true }
    if (granted || answered) return
    Spacer(Modifier.size(Space.s))
    Text("Allow notifications to see transfer progress while you use other apps.", style = MBType.caption)
    SecondaryButton("Allow notifications", modifier = Modifier.padding(top = Space.xs)) { ask.launch(Manifest.permission.POST_NOTIFICATIONS) }
}

private fun stateText(t: TransferUi): String = when (t.state) {
    TransferUi.State.Preparing -> "Preparing…"
    TransferUi.State.Offered -> if (t.toMac) "Offered" else "Waiting for you"
    TransferUi.State.WaitingForMac -> if (t.message != null) "Waiting for the connection" else "Waiting for your Mac to accept"
    TransferUi.State.InProgress -> "${(t.fraction * 100).toInt()}%"
    TransferUi.State.Paused -> "Paused at ${(t.fraction * 100).toInt()}%"
    TransferUi.State.Verifying -> "Verifying…"
    TransferUi.State.Done -> "Done"
    TransferUi.State.Failed -> "Failed"
    TransferUi.State.Cancelled -> "Cancelled"
}

@Composable
private fun ClipboardPanel(vm: AppViewModel, canClipboard: Boolean) {
    val mode by vm.clipboard.mode.collectAsState()
    val pending by vm.clipboard.pending.collectAsState()
    val log by vm.clipboard.log.collectAsState()
    var typed by remember { mutableStateOf("") }
    var problem by remember { mutableStateOf<String?>(null) }
    Panel {
        SectionHeader("Clipboard", "Plain text between this phone and your Mac")
        Spacer(Modifier.size(Space.s))
        if (!canClipboard) {
            Text("Clipboard sync is off for this phone. On your Mac: Settings → Devices → allow “Clipboard sync”.", style = MBType.caption)
            return@Panel
        }
        Eyebrow("From your Mac")
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
            listOf(ClipboardBridge.Mode.Off to "Off", ClipboardBridge.Mode.Ask to "Ask", ClipboardBridge.Mode.Auto to "Automatic").forEach { (m, label) ->
                FilterChip(mode == m, { vm.clipboard.mode.value = m }, label = { Text(label) },
                    colors = FilterChipDefaults.filterChipColors(selectedContainerColor = MB.accent, selectedLabelColor = MB.onAccent, containerColor = MB.elevated, labelColor = MB.textSecondary))
            }
        }
        Text("Automatic never applies text that looks like a password, key or card number — it asks instead.", style = MBType.caption)
        pending?.let { p ->
            Spacer(Modifier.size(Space.s))
            Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(Radius.md)).background(MB.elevated).padding(Space.m)) {
                Text("Your Mac copied ${p.text.length} characters", style = MBType.bodyEmphasis)
                Text(if (p.sensitive != null) "Preview hidden — it looks like ${if (p.sensitive.first() in "aeiouAEIOU") "an" else "a"} ${p.sensitive}." else p.text.take(160), style = MBType.caption, maxLines = 3)
                Row(Modifier.padding(top = Space.s), horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    PrimaryButton("Copy here", icon = Icons.Rounded.ContentCopy) { vm.clipboard.acceptPending() }
                    SecondaryButton("Dismiss") { vm.clipboard.dismissPending() }
                }
            }
        }
        Spacer(Modifier.size(Space.m))
        Eyebrow("To your Mac")
        SecondaryButton("Send this phone’s clipboard", icon = Icons.Rounded.ContentCopy) { problem = vm.clipboard.sendClipboard() }
        Spacer(Modifier.size(Space.s))
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(typed, { typed = it; problem = null }, Modifier.weight(1f), placeholder = { Text("Or type text for the Mac’s clipboard", style = MBType.callout) },
                maxLines = 3, colors = fieldColors())
            IconButton({ problem = vm.clipboard.sendText(typed); if (problem == null) typed = "" }) {
                Icon(Icons.AutoMirrored.Rounded.Send, "Send to the Mac’s clipboard", tint = MB.accent)
            }
        }
        problem?.let { Text(it, style = MBType.caption.copy(color = MB.warning)) }
        if (log.isNotEmpty()) {
            Spacer(Modifier.size(Space.s))
            log.take(4).forEach { Text("· $it", style = MBType.caption) }
        }
    }
}
