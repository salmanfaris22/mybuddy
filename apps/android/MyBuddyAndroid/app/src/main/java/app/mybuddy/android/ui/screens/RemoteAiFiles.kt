package app.mybuddy.android.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Send
import androidx.compose.material.icons.rounded.Description
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material.icons.rounded.PowerSettingsNew
import androidx.compose.material.icons.rounded.Stop
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import app.mybuddy.android.AppViewModel
import app.mybuddy.android.core.stream.Trackpad
import app.mybuddy.android.data.ChatTurn
import app.mybuddy.android.data.Formats
import app.mybuddy.android.data.Load
import app.mybuddy.android.ui.Page
import app.mybuddy.android.ui.components.BrandMark
import app.mybuddy.android.ui.components.Eyebrow
import app.mybuddy.android.ui.components.Panel
import app.mybuddy.android.ui.components.PreviewBadge
import app.mybuddy.android.ui.components.PrimaryButton
import app.mybuddy.android.ui.components.SecondaryButton
import app.mybuddy.android.ui.components.SectionHeader
import app.mybuddy.android.ui.components.StateKind
import app.mybuddy.android.ui.components.StateMessage
import app.mybuddy.android.ui.components.StatusPill
import app.mybuddy.android.ui.theme.MB
import app.mybuddy.android.ui.theme.MBType
import app.mybuddy.android.ui.theme.Radius
import app.mybuddy.android.ui.theme.Space
import app.mybuddy.android.ui.theme.Tone
import kotlin.math.abs
import kotlin.math.max

@Composable
internal fun KeyCap(label: String, onClick: () -> Unit) {
    Box(
        Modifier.heightIn(min = 44.dp).clip(RoundedCornerShape(Radius.md)).background(MB.elevatedHigh).border(1.dp, MB.borderStrong, RoundedCornerShape(Radius.md))
            .clickable(onClick = onClick).padding(horizontal = 14.dp, vertical = 10.dp),
        contentAlignment = Alignment.Center,
    ) { Text(label, style = MBType.bodyEmphasis) }
}

/**
 * Dedicated touchpad: one finger moves the pointer (with trackpad-style acceleration), tap = click, two-finger tap =
 * right click, two-finger drag = scroll, three-finger swipe = switch spaces / Mission Control. Gestures never double
 * as other commands.
 */
@Composable
internal fun Touchpad(vm: AppViewModel, macAspect: Float = 1.6f) {
    Box(
        Modifier.fillMaxWidth().height(240.dp).clip(RoundedCornerShape(Radius.lg)).background(MB.elevated).border(1.dp, MB.border, RoundedCornerShape(Radius.lg))
            .semantics { contentDescription = "Touchpad. Drag to move the Mac pointer, tap to click, two-finger tap to right-click, two-finger drag to scroll, three fingers to switch spaces." }
            .pointerInput(macAspect) {
                val slop = viewConfiguration.touchSlop
                val swipeDistance = 60.dp.toPx()
                awaitEachGesture {
                    val down = awaitFirstDown()
                    val started = System.currentTimeMillis()
                    var last = down.position
                    var lastTime = down.uptimeMillis
                    var travelled = 0f
                    var maxPointers = 1
                    var lastCentroid: Offset? = null
                    var threeStart: Offset? = null
                    var swiped = false
                    do {
                        val event = awaitPointerEvent()
                        val pressed = event.changes.filter { it.pressed }
                        maxPointers = max(maxPointers, pressed.size)
                        if (pressed.size >= 3) {
                            val c = pressed.map { it.position }.reduce { a, b -> a + b } / pressed.size.toFloat()
                            val start = threeStart ?: c.also { threeStart = it }
                            if (!swiped) Trackpad.classifySwipe(c.x - start.x, c.y - start.y, swipeDistance)?.let { swiped = true; vm.swipe(it) }
                        } else if (pressed.size == 2 && maxPointers == 2) {
                            val centroid = pressed.map { it.position }.reduce { a, b -> a + b } / pressed.size.toFloat()
                            lastCentroid?.let { lc ->
                                val d = centroid - lc
                                travelled += d.getDistance()
                                if (abs(d.y) > 0.5f || abs(d.x) > 0.5f) vm.scroll(-d.x * 2.0, -d.y * 2.0)
                            }
                            lastCentroid = centroid
                        } else if (pressed.size == 1 && maxPointers == 1) {
                            val ch = pressed[0]
                            val d = ch.position - last
                            travelled += d.getDistance()
                            if (travelled > slop) {
                                val (dx, dy) = Trackpad.delta(d.x, d.y, ch.uptimeMillis - lastTime, size.width.toFloat(), macAspect)
                                vm.movePointer(dx, dy)
                            }
                            last = ch.position
                            lastTime = ch.uptimeMillis
                        }
                        event.changes.forEach { it.consume() }
                    } while (event.changes.any { it.pressed })
                    if (maxPointers < 3 && travelled <= slop && System.currentTimeMillis() - started < 300) {
                        if (maxPointers >= 2) vm.click("right") else vm.click()
                    }
                }
            },
        contentAlignment = Alignment.BottomCenter,
    ) {
        Text("Drag · tap · two-finger tap = right click · two-finger drag = scroll · three fingers = spaces", style = MBType.caption, modifier = Modifier.padding(Space.m))
    }
}

@Composable
fun fieldColors() = OutlinedTextFieldDefaults.colors(
    focusedBorderColor = MB.accent, unfocusedBorderColor = MB.border, focusedContainerColor = MB.base, unfocusedContainerColor = MB.base,
    cursorColor = MB.accent, focusedTextColor = MB.textPrimary, unfocusedTextColor = MB.textPrimary,
)

// region AI

@Composable
fun AiScreen(vm: AppViewModel, nav: NavHostController, onVoice: () -> Unit) {
    val turns by vm.transcript.collectAsState()
    val provider by vm.providerLine.collectAsState()
    val busy by vm.chatBusy.collectAsState()
    val state by vm.connection.collectAsState()
    val session by vm.session.collectAsState()
    val demo by vm.demo.collectAsState()
    var draft by remember { mutableStateOf("") }
    val list = rememberLazyListState()
    val canChat = demo || (state.isConnected && session?.granted?.contains("ai.chat") == true)
    // Chat with the Mac's AI provider, or hand a task to a coding agent (Claude Code / Codex) on the Mac.
    var agentMode by rememberSaveable { mutableStateOf(false) }
    val agentsAllowed = session?.granted?.contains("ai.agent") == true
    val workspaces = session?.agentWorkspaces ?: emptyList()
    val agents = session?.agents ?: emptyMap()
    var agentKind by rememberSaveable { mutableStateOf("claude_code") }
    var workspaceId by rememberSaveable { mutableStateOf<String?>(null) }
    var editLevel by rememberSaveable { mutableStateOf(false) }
    val chosenWorkspace = workspaceId?.takeIf { id -> workspaces.any { it.first == id } } ?: workspaces.firstOrNull()?.first
    val agentReady = agents[agentKind] == true
    val canSend = if (agentMode) canChat && agentsAllowed && chosenWorkspace != null && agentReady else canChat
    LaunchedEffect(turns.size, turns.lastOrNull()?.text?.length) { if (turns.isNotEmpty()) list.animateScrollToItem(turns.size - 1) }

    Column(Modifier.fillMaxSize().background(MB.base).statusBarsPadding().imePadding()) {
        Row(Modifier.fillMaxWidth().padding(Space.l), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("AI", style = MBType.title)
                Text(provider ?: "Runs on your Mac · provider chosen there", style = MBType.caption)
            }
            if (demo) PreviewBadge()
            IconButton(onVoice) { Icon(Icons.Rounded.Mic, "Voice", tint = MB.accent) }
        }
        if (canChat && !demo) {
            Row(Modifier.fillMaxWidth().padding(horizontal = Space.l), horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
                FilterChip(!agentMode, { agentMode = false }, label = { Text("Chat") }, colors = aiChipColors())
                FilterChip(agentMode, { agentMode = true }, label = { Text("Coding agent") }, colors = aiChipColors())
            }
            if (agentMode && agentsAllowed && workspaces.isNotEmpty()) {
                AgentControls(agents, agentKind, { agentKind = it }, workspaces, chosenWorkspace, { workspaceId = it }, editLevel, { editLevel = it })
            }
        }
        when {
            !state.isConnected && !demo -> Box(Modifier.weight(1f).fillMaxWidth()) {
                StateMessage(StateKind.Offline, "Connect to your Mac", "Chats run on your Mac with its AI provider. Nothing is sent from this phone directly to an AI company.")
            }
            !canChat -> Box(Modifier.weight(1f).fillMaxWidth()) {
                StateMessage(StateKind.NotAuthorized, "AI is off for this phone", "Turn on “AI chat on this Mac” for this phone in MyBuddy on your Mac.")
            }
            agentMode && !agentsAllowed -> Box(Modifier.weight(1f).fillMaxWidth()) {
                StateMessage(StateKind.NotAuthorized, "Coding agents are off for this phone",
                    "On your Mac: MyBuddy → Settings → Devices → turn on “Coding agents”, then reconnect. Claude Code and Codex run on the Mac with their own sign-in.")
            }
            agentMode && workspaces.isEmpty() -> Box(Modifier.weight(1f).fillMaxWidth()) {
                StateMessage(StateKind.Empty, "No folders shared for agents",
                    "On your Mac: AI Studio → Coding agents → From your phone → Add folder…, then reconnect. Agents can only work inside those folders.")
            }
            else -> LazyColumn(Modifier.weight(1f).fillMaxWidth(), state = list, contentPadding = androidx.compose.foundation.layout.PaddingValues(Space.l),
                verticalArrangement = Arrangement.spacedBy(Space.m)) {
                if (turns.isEmpty()) item { StateMessage(StateKind.Empty, "Ask anything", "Your message goes to your Mac, which sends it to the provider you picked there. Screen, files and health data are never included automatically.") }
                items(turns, key = { it.id }) { Bubble(it) }
            }
        }
        // The composer only appears when a message could actually be answered.
        if (canSend || (busy && canChat)) {
            Row(Modifier.fillMaxWidth().background(MB.surface).padding(Space.m), verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(draft, { draft = it }, Modifier.weight(1f),
                    placeholder = { Text(if (agentMode) "Describe the task for the agent…" else "Message", style = MBType.callout) }, maxLines = 5, colors = fieldColors())
                Spacer(Modifier.width(Space.s))
                if (busy) {
                    IconButton({ vm.stopChat() }) { Icon(Icons.Rounded.Stop, "Stop", tint = MB.danger) }
                } else {
                    IconButton({
                        if (agentMode) vm.startAgentTask(draft, agentKind, chosenWorkspace ?: return@IconButton, if (editLevel) "edit_workspace" else "read_only")
                        else vm.sendChat(draft)
                        draft = ""
                    }, enabled = draft.isNotBlank()) { Icon(Icons.AutoMirrored.Rounded.Send, if (agentMode) "Start task" else "Send", tint = if (draft.isNotBlank()) MB.accent else MB.textTertiary) }
                }
            }
        }
    }
}

@Composable
private fun Bubble(t: ChatTurn) {
    if (t.fromUser) {
        Row(Modifier.fillMaxWidth()) {
            Spacer(Modifier.weight(0.15f))
            Text(t.text, style = MBType.body, modifier = Modifier.weight(0.85f, fill = false).clip(RoundedCornerShape(Radius.lg)).background(MB.elevatedHigh).padding(Space.m))
        }
    } else {
        Column(verticalArrangement = Arrangement.spacedBy(Space.xs)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                BrandMark(16.dp, live = t.status == ChatTurn.Status.Streaming)
                Spacer(Modifier.width(Space.xs))
                Text(t.servedBy ?: "Your Mac", style = MBType.mono.copy(color = MB.textTertiary))
            }
            when (t.status) {
                ChatTurn.Status.Failed -> Text(t.text, style = MBType.body.copy(color = MB.danger))
                else -> Text(t.text.ifEmpty { "…" }, style = MBType.body)
            }
            t.note?.let { Text(it, style = MBType.caption.copy(color = MB.warning)) }
        }
    }
}

/** Which agent, which shared folder, and whether it may edit (the Mac asks its user before any edit run). */
@Composable
private fun AgentControls(
    agents: Map<String, Boolean>, kind: String, onKind: (String) -> Unit,
    workspaces: List<Pair<String, String>>, workspaceId: String?, onWorkspace: (String) -> Unit,
    edit: Boolean, onEdit: (Boolean) -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(horizontal = Space.l, vertical = Space.xs), verticalArrangement = Arrangement.spacedBy(Space.xs)) {
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
            listOf("claude_code" to "Claude Code", "codex" to "Codex").forEach { (k, label) ->
                val ready = agents[k] == true
                FilterChip(kind == k, { onKind(k) }, label = { Text(if (ready) label else "$label · not ready") }, colors = aiChipColors())
            }
        }
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
            workspaces.forEach { (id, name) -> FilterChip(workspaceId == id, { onWorkspace(id) }, label = { Text(name) }, colors = aiChipColors()) }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
            FilterChip(!edit, { onEdit(false) }, label = { Text("Read-only") }, colors = aiChipColors())
            FilterChip(edit, { onEdit(true) }, label = { Text("May edit files") }, colors = aiChipColors())
        }
        Text(
            when {
                agents[kind] != true -> "${if (kind == "codex") "Codex" else "Claude Code"} isn’t installed or signed in on your Mac yet."
                edit -> "Edits files in that folder only. Your Mac shows a prompt and nothing runs until you allow it there."
                else -> "Reads and plans — no edits, no shell commands."
            },
            style = MBType.caption,
        )
    }
}

@Composable
private fun aiChipColors() = FilterChipDefaults.filterChipColors(
    selectedContainerColor = MB.accent, selectedLabelColor = MB.onAccent, containerColor = MB.elevated, labelColor = MB.textSecondary,
)

// endregion

// region Files

// endregion
