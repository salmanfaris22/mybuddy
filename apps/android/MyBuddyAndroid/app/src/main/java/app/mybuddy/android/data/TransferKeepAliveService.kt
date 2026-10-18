package app.mybuddy.android.data

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import app.mybuddy.android.MainActivity
import app.mybuddy.android.R
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/**
 * Keeps MyBuddy's process — and so its encrypted connection to the Mac — running while a file transfer is
 * active and the app is not on screen. Android freezes background apps within seconds and cuts their network,
 * which would break the transfer. Runs only while a transfer is moving, shows its progress in an ongoing
 * notification, and stops itself when nothing is left (or when Android's data-sync time limit is reached).
 * It is only ever started from a user action in the foreground (Send / Save / Download), as Android requires.
 */
class TransferKeepAliveService : Service() {
    /** What the notification shows; null when no transfer is moving. */
    data class Summary(val count: Int, val name: String, val toMac: Boolean, val fraction: Float)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var started = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Always enter the foreground first (Android requires it after every startForegroundService), even if the
        // transfer finished in the meantime — the collector below then removes the notification at once.
        val first = current.value ?: Summary(1, "file", toMac = true, fraction = 1f)
        ServiceCompat.startForeground(this, NOTIFICATION_ID, notification(first), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        if (!started) {
            started = true
            scope.launch {
                current.collect { s ->
                    if (s == null) {
                        ServiceCompat.stopForeground(this@TransferKeepAliveService, ServiceCompat.STOP_FOREGROUND_REMOVE)
                        stopSelf()
                    } else {
                        getSystemService(NotificationManager::class.java)?.notify(NOTIFICATION_ID, notification(s))
                    }
                }
            }
        }
        // Never restarted by the system: a transfer can't continue in a new process anyway.
        return START_NOT_STICKY
    }

    /** Android 15+ limits data-sync services to 6 hours a day; the transfer then continues only while visible. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private fun notification(s: Summary): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val title = when {
            s.count > 1 -> "${s.count} transfers with your Mac"
            s.toMac -> "Sending “${s.name}” to your Mac"
            else -> "Receiving “${s.name}” from your Mac"
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_transfer)
            .setContentTitle(title)
            .setContentText("${(s.fraction * 100).toInt()}% · encrypted end to end, checked with SHA-256")
            .setProgress(100, (s.fraction * 100).toInt(), false)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setContentIntent(open)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "transfers"
        private const val NOTIFICATION_ID = 41
        private val current = MutableStateFlow<Summary?>(null)
        val summary: StateFlow<Summary?> = current

        /**
         * Publishes the moving transfers. Starting is attempted only while MyBuddy is visible ([foreground]);
         * if Android refuses anyway, the transfer simply continues for as long as the app stays on screen.
         */
        fun update(context: Context, items: List<TransferUi>, foreground: Boolean) {
            val moving = items.filter { it.state in MOVING }
            val next = if (moving.isEmpty()) null else Summary(
                count = moving.size,
                name = moving.first().name,
                toMac = moving.first().toMac,
                fraction = moving.sumOf { it.transferred }.toFloat() / maxOf(1L, moving.sumOf { it.size }),
            )
            val wasRunning = current.value != null
            current.value = next
            if (next != null && !wasRunning && foreground) {
                ensureChannel(context)
                runCatching { ContextCompat.startForegroundService(context, Intent(context, TransferKeepAliveService::class.java)) }
            }
        }

        private fun ensureChannel(context: Context) {
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            if (manager.getNotificationChannel(CHANNEL_ID) != null) return
            manager.createNotificationChannel(NotificationChannel(CHANNEL_ID, "File transfers", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Progress of files moving between this phone and your Mac"
                setShowBadge(false)
            })
        }

        private val MOVING = setOf(TransferUi.State.Preparing, TransferUi.State.WaitingForMac, TransferUi.State.InProgress, TransferUi.State.Verifying)
    }
}
