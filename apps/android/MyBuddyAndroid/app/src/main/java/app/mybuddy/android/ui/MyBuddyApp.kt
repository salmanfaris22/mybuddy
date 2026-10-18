package app.mybuddy.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.Home
import androidx.compose.material.icons.rounded.Mouse
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.ScaffoldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import app.mybuddy.android.AppViewModel
import app.mybuddy.android.ui.components.BrandMark
import app.mybuddy.android.ui.components.PreviewBadge
import app.mybuddy.android.ui.screens.ActivityScreen
import app.mybuddy.android.ui.screens.AiScreen
import app.mybuddy.android.ui.screens.FilesScreen
import app.mybuddy.android.ui.screens.HealthScreen
import app.mybuddy.android.ui.screens.HomeScreen
import app.mybuddy.android.ui.screens.NoteEditorScreen
import app.mybuddy.android.ui.screens.NotesScreen
import app.mybuddy.android.ui.screens.PairingScreen
import app.mybuddy.android.ui.screens.RemoteScreen
import app.mybuddy.android.ui.screens.SettingsScreen
import app.mybuddy.android.ui.screens.VoiceSheet
import app.mybuddy.android.ui.theme.MB
import app.mybuddy.android.ui.theme.MBType
import app.mybuddy.android.ui.theme.Space

enum class Tab(val route: String, val label: String, val icon: ImageVector) {
    Home("home", "Home", Icons.Rounded.Home),
    Remote("remote", "Remote", Icons.Rounded.Mouse),
    Ai("ai", "AI", Icons.Rounded.AutoAwesome),
    Files("files", "Files", Icons.Rounded.Folder),
    Activity("activity", "Activity", Icons.Rounded.History),
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MyBuddyApp(vm: AppViewModel, startRoute: String = Tab.Home.route) {
    val nav = rememberNavController()
    val entry by nav.currentBackStackEntryAsState()
    val route = entry?.destination?.route
    var showVoice by remember { mutableStateOf(false) }
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val remoteFullscreen by vm.remoteFullscreen.collectAsState()

    Scaffold(
        containerColor = MB.base,
        // Page applies the status bar inset itself; the Scaffold only handles the sides and bottom.
        contentWindowInsets = ScaffoldDefaults.contentWindowInsets.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom),
        bottomBar = {
            // The full-screen remote view uses the whole display.
            if (Tab.entries.any { it.route == route } && !(remoteFullscreen && route == Tab.Remote.route)) {
                NavigationBar(containerColor = MB.surface, tonalElevation = 0.dp) {
                    Tab.entries.forEach { tab ->
                        NavigationBarItem(
                            selected = route == tab.route,
                            onClick = {
                                nav.navigate(tab.route) {
                                    popUpTo(Tab.Home.route) { saveState = true }
                                    launchSingleTop = true
                                    restoreState = true
                                }
                            },
                            icon = { Icon(tab.icon, contentDescription = null) },
                            label = { Text(tab.label, style = MBType.caption.copy(color = if (route == tab.route) MB.textPrimary else MB.textTertiary)) },
                            colors = NavigationBarItemDefaults.colors(
                                selectedIconColor = MB.onAccent, indicatorColor = MB.accent,
                                unselectedIconColor = MB.textTertiary, selectedTextColor = MB.textPrimary, unselectedTextColor = MB.textTertiary,
                            ),
                        )
                    }
                }
            }
        },
    ) { padding ->
        // Insets the Scaffold already applied are consumed, so a page's imePadding() adds only what the keyboard covers beyond them.
        NavHost(nav, startDestination = startRoute, modifier = Modifier.padding(padding).consumeWindowInsets(padding).background(MB.base)) {
            composable(Tab.Home.route) { HomeScreen(vm, nav, onVoice = { showVoice = true }) }
            composable(Tab.Remote.route) { RemoteScreen(vm, nav) }
            composable(Tab.Ai.route) { AiScreen(vm, nav, onVoice = { showVoice = true }) }
            composable(Tab.Files.route) { FilesScreen(vm, nav) }
            composable(Tab.Activity.route) { ActivityScreen(vm) }
            composable("pairing") { PairingScreen(vm, nav) }
            composable("health") { HealthScreen(vm, nav) }
            composable("settings") { SettingsScreen(vm, nav) }
            composable("notes") { NotesScreen(vm, nav) }
            composable("note/{id}") { entry -> NoteEditorScreen(vm, nav, entry.arguments?.getString("id") ?: return@composable) }
        }
    }
    if (showVoice) {
        ModalBottomSheet(onDismissRequest = { vm.voice.cancel(); showVoice = false }, sheetState = sheetState, containerColor = MB.surface) {
            VoiceSheet(vm)
        }
    }
}

/** Standard page: header + scrolling content with consistent gutters. */
@Composable
fun Page(
    title: String,
    vm: AppViewModel,
    nav: NavHostController? = null,
    back: Boolean = false,
    trailing: (@Composable () -> Unit)? = null,
    contentPadding: PaddingValues = PaddingValues(horizontal = Space.l, vertical = Space.s),
    content: LazyListScope.() -> Unit,
) {
    val demo by vm.demo.collectAsState()
    Column(Modifier.fillMaxSize().background(MB.base).statusBarsPadding()) {
        // Fixed minimum height so titles line up across tabs with and without a trailing action.
        Row(Modifier.fillMaxWidth().padding(horizontal = Space.s, vertical = Space.s).heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
            if (back && nav != null) {
                IconButton({ nav.popBackStack() }) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, "Back", tint = MB.textPrimary) }
            } else {
                Box(Modifier.padding(start = Space.s, end = Space.s)) { BrandMark(26.dp, live = vm.connection.collectAsState().value.isConnected) }
            }
            Text(title, style = MBType.title, modifier = Modifier.weight(1f))
            if (demo) PreviewBadge()
            Spacer(Modifier.width(Space.xs))
            trailing?.invoke()
        }
        // imePadding: a focused field (e.g. the Remote keyboard) stays above the phone's keyboard instead of behind it.
        LazyColumn(Modifier.fillMaxSize().imePadding(), contentPadding = contentPadding, verticalArrangement = Arrangement.spacedBy(Space.m), content = content)
    }
}

@Composable
fun SmallSpacer() = Spacer(Modifier.size(Space.xs))
