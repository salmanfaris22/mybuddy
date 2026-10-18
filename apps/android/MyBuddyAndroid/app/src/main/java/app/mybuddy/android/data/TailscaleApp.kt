package app.mybuddy.android.data

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import androidx.core.net.toUri

/**
 * What this phone can tell about Tailscale without touching it: whether the official app is installed and
 * whether a VPN is currently active (Android doesn't say *which* app's VPN, so the UI says "a VPN is on").
 */
data class TailscaleInfo(val installed: Boolean, val vpnActive: Boolean)

object TailscaleApp {
    const val PACKAGE = "com.tailscale.ipn"

    fun info(context: Context): TailscaleInfo {
        val installed = try {
            if (Build.VERSION.SDK_INT >= 33) {
                context.packageManager.getPackageInfo(PACKAGE, PackageManager.PackageInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                context.packageManager.getPackageInfo(PACKAGE, 0)
            }
            true
        } catch (e: PackageManager.NameNotFoundException) {
            false
        }
        val cm = context.getSystemService(ConnectivityManager::class.java)
        val vpn = cm?.getNetworkCapabilities(cm.activeNetwork)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        return TailscaleInfo(installed, vpn)
    }

    /** Opens Tailscale, or its Play Store page when it isn't installed. */
    fun open(context: Context) {
        val launch = context.packageManager.getLaunchIntentForPackage(PACKAGE)
        val intent = launch ?: Intent(Intent.ACTION_VIEW, "market://details?id=$PACKAGE".toUri())
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            context.startActivity(intent)
        } catch (e: ActivityNotFoundException) {
            context.startActivity(Intent(Intent.ACTION_VIEW, "https://play.google.com/store/apps/details?id=$PACKAGE".toUri()).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }
}
