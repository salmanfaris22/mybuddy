package app.mybuddy.android.data

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import app.mybuddy.android.core.session.Discovery
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.Executors

/**
 * Looks for the paired Mac's Bonjour service (`_mybuddy._tcp`) on the current network with Android's
 * Network Service Discovery, so the phone still finds the Mac after its IP address changes. Runs only
 * while connecting and stops as soon as the Mac is found or the time runs out.
 */
class MacDiscovery(context: Context) {
    private val nsd: NsdManager? = context.getSystemService(NsdManager::class.java)
    private val executor = Executors.newSingleThreadExecutor { r -> Thread(r, "mybuddy-nsd") }

    suspend fun find(host: PairedHost, timeoutMs: Long = 4_000): List<String> {
        val nsd = nsd ?: return emptyList()
        val result = CompletableDeferred<List<String>>()
        val callbacks = mutableListOf<Any>()

        fun onResolved(hosts: List<String>, port: Int, fp: String?) {
            val addresses = Discovery.addresses(fp, host.fingerprint, hosts, port)
            if (addresses.isNotEmpty()) result.complete(addresses)
        }

        val listener = object : NsdManager.DiscoveryListener {
            override fun onServiceFound(info: NsdServiceInfo) {
                if (!result.isCompleted) resolve(nsd, info, callbacks, ::onResolved)
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                result.complete(emptyList())
            }

            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onServiceLost(info: NsdServiceInfo) {}
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
        }
        return try {
            nsd.discoverServices(Discovery.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
            withTimeoutOrNull(timeoutMs) { result.await() } ?: emptyList()
        } catch (e: IllegalArgumentException) {
            emptyList()
        } finally {
            runCatching { nsd.stopServiceDiscovery(listener) }
            if (Build.VERSION.SDK_INT >= 34) {
                callbacks.forEach { cb -> runCatching { nsd.unregisterServiceInfoCallback(cb as NsdManager.ServiceInfoCallback) } }
            }
        }
    }

    private fun resolve(nsd: NsdManager, info: NsdServiceInfo, callbacks: MutableList<Any>, done: (List<String>, Int, String?) -> Unit) {
        if (Build.VERSION.SDK_INT >= 34) {
            val cb = object : NsdManager.ServiceInfoCallback {
                override fun onServiceUpdated(updated: NsdServiceInfo) {
                    done(updated.hostAddresses.mapNotNull { it.hostAddress }, updated.port, updated.attributes["fp"]?.decodeToString())
                }

                override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) {}
                override fun onServiceLost() {}
                override fun onServiceInfoCallbackUnregistered() {}
            }
            runCatching { nsd.registerServiceInfoCallback(info, executor, cb) }.onSuccess { callbacks += cb }
        } else {
            @Suppress("DEPRECATION")
            nsd.resolveService(info, object : NsdManager.ResolveListener {
                override fun onServiceResolved(resolved: NsdServiceInfo) {
                    @Suppress("DEPRECATION")
                    done(listOfNotNull(resolved.host?.hostAddress), resolved.port, resolved.attributes["fp"]?.decodeToString())
                }

                override fun onResolveFailed(failed: NsdServiceInfo, errorCode: Int) {}
            })
        }
    }
}
