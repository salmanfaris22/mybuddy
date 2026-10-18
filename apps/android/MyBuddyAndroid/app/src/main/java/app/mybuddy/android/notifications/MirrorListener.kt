package app.mybuddy.android.notifications

import android.app.Notification
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import app.mybuddy.android.MyBuddyApplication
import app.mybuddy.android.core.notifications.SeenNotification

/**
 * Android's notification listener for mirroring to the Mac. Android binds it only after the user enables
 * MyBuddy under notification access in system settings; MyBuddy never turns that on itself. Everything it sees
 * goes through [app.mybuddy.android.data.NotificationMirror], which applies the switch, filters and redaction.
 */
class MirrorListener : NotificationListenerService() {
    private val mirror get() = (application as MyBuddyApplication).vm.notifications

    override fun onListenerConnected() {
        mirror.listenerConnected.value = true
    }

    override fun onListenerDisconnected() {
        mirror.listenerConnected.value = false
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val n = sbn.notification ?: return
        val extras = n.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()
        val text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString()
        val label = appLabel(sbn)
        mirror.onPosted(
            SeenNotification(
                key = sbn.key, packageName = sbn.packageName, appLabel = label, title = title, text = text, category = n.category,
                ongoing = sbn.isOngoing, groupSummary = (n.flags and Notification.FLAG_GROUP_SUMMARY) != 0, clearable = sbn.isClearable,
            ),
            currentInterruptionFilter,
        )
    }

    /**
     * The posting app's name. Notifications carry the poster's ApplicationInfo ("android.appInfo"), which needs no
     * package-visibility permission; otherwise the package manager (visible packages only) or the package name.
     */
    private fun appLabel(sbn: StatusBarNotification): String {
        val carried = if (Build.VERSION.SDK_INT >= 33) sbn.notification.extras.getParcelable("android.appInfo", ApplicationInfo::class.java)
        else @Suppress("DEPRECATION") sbn.notification.extras.getParcelable("android.appInfo")
        carried?.loadLabel(packageManager)?.toString()?.takeIf { it.isNotBlank() }?.let { return it }
        return runCatching {
            val info = if (Build.VERSION.SDK_INT >= 33) packageManager.getApplicationInfo(sbn.packageName, PackageManager.ApplicationInfoFlags.of(0))
            else @Suppress("DEPRECATION") packageManager.getApplicationInfo(sbn.packageName, 0)
            packageManager.getApplicationLabel(info).toString()
        }.getOrDefault(sbn.packageName)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        mirror.onRemoved(sbn.key)
    }
}
