package app.mybuddy.android.data

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Settings
import android.service.notification.NotificationListenerService
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.core.stringSetPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import app.mybuddy.android.MainActivity
import app.mybuddy.android.R
import app.mybuddy.android.core.Base64Url
import app.mybuddy.android.core.notifications.NotificationRules
import app.mybuddy.android.core.notifications.PreviewPolicy
import app.mybuddy.android.core.notifications.SeenNotification
import app.mybuddy.android.core.protocol.Envelope
import app.mybuddy.android.core.protocol.EventType
import app.mybuddy.android.notifications.MirrorListener
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.security.SecureRandom
import java.time.Instant

private val Context.notificationStore by preferencesDataStore("mybuddy_notifications")

/**
 * Phone → Mac notification mirroring (PROTOCOL §5.10) and MyBuddy's own alerts from the Mac. Off by default.
 * Needs three yeses: Android's notification access (the user enables it in system settings), this switch, and
 * "Mirror notifications" for this phone on the Mac. Nothing is queued or stored while not connected.
 */
class NotificationMirror(private val context: Context, private val scope: CoroutineScope, private val link: MacLink) {
    data class Config(val enabled: Boolean = false, val preview: PreviewPolicy = PreviewPolicy.HIDDEN, val pauseInDnd: Boolean = true, val blocked: Set<String> = emptySet())
    data class MacAlert(val title: String, val text: String?, val at: Instant)

    private object Keys {
        val enabled = booleanPreferencesKey("mirror_enabled")
        val preview = stringPreferencesKey("mirror_preview")
        val pauseInDnd = booleanPreferencesKey("mirror_pause_dnd")
        val blocked = stringSetPreferencesKey("mirror_blocked")
        val salt = stringPreferencesKey("mirror_salt")
    }

    val config: StateFlow<Config> = context.notificationStore.data.map { p ->
        Config(
            enabled = p[Keys.enabled] ?: false,
            preview = PreviewPolicy.entries.firstOrNull { it.name == p[Keys.preview] } ?: PreviewPolicy.HIDDEN,
            pauseInDnd = p[Keys.pauseInDnd] ?: true,
            blocked = p[Keys.blocked] ?: emptySet(),
        )
    }.stateIn(scope, SharingStarted.Eagerly, Config())

    /** True while Android has our listener bound (the user allowed notification access). */
    val listenerConnected = MutableStateFlow(false)
    /** Apps that posted notifications since the listener connected (package → label), for the filter list. */
    val recentApps = MutableStateFlow<Map<String, String>>(emptyMap())
    val sentThisSession = MutableStateFlow(0)
    val macAlerts = MutableStateFlow<List<MacAlert>>(emptyList())
    /** Why nothing is being sent right now (shown in Settings), or null when mirroring is live. */
    val blockedReason = MutableStateFlow<String?>(null)

    private var rules: NotificationRules? = null
    private val forwarded = LinkedHashSet<String>()

    init {
        scope.launch {
            val stored = context.notificationStore.data.first()[Keys.salt]
            val salt = stored?.let { Base64Url.decode(it) } ?: ByteArray(16).also(SecureRandom()::nextBytes).also { s ->
                context.notificationStore.edit { it[Keys.salt] = Base64Url.encode(s) }
            }
            rules = NotificationRules(context.packageName, salt)
        }
    }

    fun accessGranted(): Boolean = NotificationManagerCompat.getEnabledListenerPackages(context).contains(context.packageName)

    /** Android's own screen for this app's notification access (the user decides there). */
    fun accessSettingsIntent(): Intent {
        val component = ComponentName(context, MirrorListener::class.java)
        return Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS)
            .putExtra(Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME, component.flattenToString())
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }

    fun setEnabled(on: Boolean) = scope.launch { context.notificationStore.edit { it[Keys.enabled] = on } }
    fun setPreview(p: PreviewPolicy) = scope.launch { context.notificationStore.edit { it[Keys.preview] = p.name } }
    fun setPauseInDnd(on: Boolean) = scope.launch { context.notificationStore.edit { it[Keys.pauseInDnd] = on } }
    fun setBlocked(pkg: String, blocked: Boolean) = scope.launch {
        context.notificationStore.edit { prefs -> prefs[Keys.blocked] = (prefs[Keys.blocked] ?: emptySet()).let { if (blocked) it + pkg else it - pkg } }
    }

    /** Called by [MirrorListener] on the main thread. */
    fun onPosted(n: SeenNotification, interruptionFilter: Int) {
        if (n.packageName != context.packageName) recentApps.value = (recentApps.value + (n.packageName to n.appLabel)).entries.toList().takeLast(40).associate { it.key to it.value }
        val c = config.value
        val r = rules ?: return
        blockedReason.value = reasonNotSending(c, interruptionFilter)
        if (blockedReason.value != null || !r.shouldMirror(n, c.blocked)) return
        val m = r.mirror(n, c.preview)
        val sent = link.send(EventType.NOTIFICATION_POSTED, buildJsonObject {
            put("notificationId", m.notificationId)
            put("appPackage", m.appPackage)
            put("appLabel", m.appLabel)
            m.title?.let { put("title", it) }
            m.text?.let { put("text", it) }
            put("postedAt", Instant.now().toString())
            put("redaction", m.redaction)
            m.category?.let { put("category", it) }
        })
        if (sent != null) {
            forwarded += m.notificationId
            while (forwarded.size > 200) forwarded.remove(forwarded.first())
            sentThisSession.value += 1
        }
    }

    fun onRemoved(key: String) {
        val id = rules?.id(key) ?: return
        if (forwarded.remove(id)) link.send(EventType.NOTIFICATION_REMOVED, buildJsonObject { put("notificationId", id) })
    }

    private fun reasonNotSending(c: Config, interruptionFilter: Int): String? = when {
        !c.enabled -> "Mirroring is off on this phone."
        !link.state.value.isConnected -> "Not connected to your Mac — notifications aren’t queued."
        link.session.value?.granted?.contains("notifications.mirror") != true -> "Allow “Mirror notifications” for this phone in MyBuddy on your Mac."
        c.pauseInDnd && interruptionFilter != NotificationListenerService.INTERRUPTION_FILTER_ALL && interruptionFilter != 0 -> "Paused while Do Not Disturb is on."
        else -> null
    }

    /** True when mirroring needs the link while the app isn't visible (listener bound and switched on). */
    val activeInBackground: Boolean get() = config.value.enabled && listenerConnected.value

    fun sessionEnded() {
        forwarded.clear()
        sentThisSession.value = 0
    }

    /** `notification.*` from the Mac: only MyBuddy's own alerts (battery low, going to sleep). */
    fun handleFromMac(e: Envelope) {
        if (e.type != EventType.NOTIFICATION_POSTED) return
        val title = e.payload["title"]?.jsonPrimitive?.content ?: return
        val text = e.payload["text"]?.jsonPrimitive?.content
        macAlerts.value = (listOf(MacAlert(title, text, Instant.now())) + macAlerts.value).take(20)
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL) == null) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "From your Mac", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "MyBuddy’s alerts from your Mac (battery low, going to sleep)"
            })
        }
        val open = PendingIntent.getActivity(context, 1, Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE)
        manager.notify((e.payload["notificationId"]?.jsonPrimitive?.content ?: title).hashCode(), NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_mac)
            .setContentTitle(title)
            .setContentText(text)
            .setAutoCancel(true)
            .setContentIntent(open)
            .build())
    }

    companion object {
        private const val CHANNEL = "mac_alerts"
    }
}
