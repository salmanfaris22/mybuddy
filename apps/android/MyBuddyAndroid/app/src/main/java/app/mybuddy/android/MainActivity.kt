package app.mybuddy.android

import android.graphics.Color
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import app.mybuddy.android.ui.MyBuddyApp
import app.mybuddy.android.ui.theme.MyBuddyTheme

class MainActivity : ComponentActivity() {
    // Process-scoped (see MyBuddyApplication): the link to the Mac outlives this screen.
    private val vm: AppViewModel get() = (application as MyBuddyApplication).vm

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // MyBuddy is always dark, so system bar icons stay light regardless of the system theme.
        enableEdgeToEdge(SystemBarStyle.dark(Color.TRANSPARENT), SystemBarStyle.dark(Color.TRANSPARENT))
        // Debug builds accept `--ez demo true` (screenshots/demos); production state never comes from fixtures.
        if (BuildConfig.DEBUG && intent.getBooleanExtra("demo", false)) vm.setDemo(true)
        // Debug builds can compare against libwebrtc's default smoothing buffer: `--ez lowLatency false`.
        if (BuildConfig.DEBUG && intent.hasExtra("lowLatency")) app.mybuddy.android.data.WebRtcRuntime.lowLatencyPlayout = intent.getBooleanExtra("lowLatency", true)
        val start = if (BuildConfig.DEBUG) intent.getStringExtra("route") ?: "home" else "home"
        setContent {
            MyBuddyTheme { MyBuddyApp(vm, start) }
        }
    }

    override fun onStart() {
        super.onStart()
        // Android blocks network access for backgrounded apps, so reconnect attempts made there fail at once.
        vm.onForeground()
    }

    override fun onStop() {
        // The Mac's screen is never received while MyBuddy isn't visible.
        vm.onBackground()
        super.onStop()
    }
}
