package app.mybuddy.android.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import app.mybuddy.android.AppViewModel
import app.mybuddy.android.core.notes.Note
import app.mybuddy.android.data.Formats
import app.mybuddy.android.ui.Page
import app.mybuddy.android.ui.components.Panel
import app.mybuddy.android.ui.components.PrimaryButton
import app.mybuddy.android.ui.components.StateKind
import app.mybuddy.android.ui.components.StateMessage
import app.mybuddy.android.ui.theme.MB
import app.mybuddy.android.ui.theme.MBType
import app.mybuddy.android.ui.theme.Space
import java.time.Instant

/** Shared notes: what you write here appears on your Mac, and the other way round. */
@Composable
fun NotesScreen(vm: AppViewModel, nav: NavHostController) {
    val notes by vm.notes.notes.collectAsState()
    val session by vm.session.collectAsState()
    val state by vm.connection.collectAsState()
    val synced by vm.notes.lastSyncedAt.collectAsState()
    val allowed = session?.granted?.contains("notes.sync") == true
    val newNote = { nav.navigate("note/${vm.notes.newId()}") }
    Page("Notes", vm, nav, back = true, trailing = {
        IconButton(newNote) { Icon(Icons.Rounded.Add, "New note", tint = MB.accent) }
    }) {
        item {
            Text(
                when {
                    !state.isConnected -> "Saved on this phone · syncs with your Mac when connected"
                    !allowed -> "Saved on this phone. To sync, turn on “Shared notes” for this phone on your Mac (Settings → Devices)."
                    synced != null -> "In step with your Mac · synced ${Formats.relative(synced!!)}"
                    else -> "In step with your Mac"
                },
                style = MBType.caption,
            )
        }
        if (notes.isEmpty()) {
            item {
                StateMessage(StateKind.Empty, "No notes yet", "Notes you write here appear on your Mac, and notes from your Mac appear here. They stay on your two devices — never on a server.") {
                    PrimaryButton("New note", icon = Icons.Rounded.Add) { newNote() }
                }
            }
        }
        items(notes, key = { it.id }) { n -> NoteCard(n) { nav.navigate("note/${n.id}") } }
    }
}

@Composable
private fun NoteCard(note: Note, onOpen: () -> Unit) {
    Panel(Modifier.clickable(role = Role.Button, onClick = onOpen)) {
        Text(note.title, style = MBType.bodyEmphasis, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(
            listOf(Formats.relative(Instant.ofEpochMilli(note.updatedAt)), note.preview).filter { it.isNotEmpty() }.joinToString(" · "),
            style = MBType.caption, maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
    }
}

/** One note, full screen. Typing saves as you go; the Mac gets it a moment later. */
@Composable
fun NoteEditorScreen(vm: AppViewModel, nav: NavHostController, id: String) {
    val notes by vm.notes.notes.collectAsState()
    val stored = notes.firstOrNull { it.id == id }
    var text by rememberSaveable(id) { mutableStateOf(vm.notes.note(id)?.text ?: "") }
    // What this screen last wrote: a different stored text means the Mac changed the note meanwhile.
    var lastLocal by rememberSaveable(id) { mutableStateOf(text) }
    var confirmDelete by remember { mutableStateOf(false) }
    val focus = remember { FocusRequester() }
    LaunchedEffect(stored?.text) {
        val t = stored?.text ?: return@LaunchedEffect
        if (t != text && t != lastLocal) {
            text = t
            lastLocal = t
        }
    }
    // Deleted on the Mac while open: nothing left to edit.
    LaunchedEffect(notes) { if (vm.notes.isDeleted(id)) nav.popBackStack() }
    LaunchedEffect(Unit) { if (text.isEmpty()) focus.requestFocus() }
    BackHandler { nav.popBackStack() }

    Column(Modifier.fillMaxSize().background(MB.base).statusBarsPadding().imePadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = Space.s, vertical = Space.s).heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton({ nav.popBackStack() }) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, "Back", tint = MB.textPrimary) }
            Column(Modifier.weight(1f)) {
                Text(if (text.isBlank()) "New note" else stored?.title ?: "New note", style = MBType.title, maxLines = 1, overflow = TextOverflow.Ellipsis)
                stored?.let { Text("Edited ${Formats.relative(Instant.ofEpochMilli(it.updatedAt))}", style = MBType.caption) }
            }
            if (stored != null) {
                IconButton({ confirmDelete = true }) { Icon(Icons.Rounded.Delete, "Delete note", tint = MB.textSecondary) }
            }
        }
        TextField(
            text,
            onValueChange = {
                text = it
                lastLocal = it
                vm.notes.update(id, it)
            },
            modifier = Modifier.fillMaxSize().padding(horizontal = Space.s).focusRequester(focus),
            placeholder = { Text("Start typing…", style = MBType.body) },
            textStyle = MBType.body.copy(color = MB.textPrimary),
            colors = TextFieldDefaults.colors(
                focusedContainerColor = Color.Transparent, unfocusedContainerColor = Color.Transparent,
                focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent, cursorColor = MB.accent,
            ),
        )
        Spacer(Modifier.size(Space.s))
    }
    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete this note?") },
            text = { Text("It’s removed from this phone and from your Mac.") },
            confirmButton = {
                TextButton({
                    confirmDelete = false
                    vm.notes.delete(id)
                    nav.popBackStack()
                }) { Text("Delete", color = MB.danger) }
            },
            dismissButton = { TextButton({ confirmDelete = false }) { Text("Cancel") } },
            containerColor = MB.surface,
        )
    }
}
