package app.mybuddy.android.core.session

/**
 * Finding the paired Mac on the local network. The Mac advertises `_mybuddy._tcp` (Bonjour/mDNS) with a TXT
 * record `fp` = the first 8 characters of its key fingerprint. A match only *selects candidates*: the MBH1
 * handshake still pins the full host key, so a spoofed advertisement cannot impersonate the Mac.
 */
object Discovery {
    const val SERVICE_TYPE = "_mybuddy._tcp"
    private const val FINGERPRINT_PREFIX = 8

    /** Dialable `host:port` strings for a resolved service, or empty when it isn't the paired Mac. */
    fun addresses(txtFingerprint: String?, pairedFingerprint: String, hosts: List<String>, port: Int): List<String> {
        if (txtFingerprint == null || txtFingerprint.length != FINGERPRINT_PREFIX) return emptyList()
        if (!pairedFingerprint.startsWith(txtFingerprint) || port !in 1..65535) return emptyList()
        return hosts
            .map { it.trim() }
            // IPv6 link-local needs an interface scope to dial; IPv4 (and ULA IPv6) is enough on a LAN.
            .filterNot { it.lowercase().startsWith("fe80") || '%' in it }
            .sortedBy { if (':' in it) 1 else 0 }
            .map { if (':' in it) "[$it]:$port" else "$it:$port" }
            .filter { PairingInvitation.isValidHostPort(it) }
            .distinct()
    }

    /** Puts the address that just worked first, keeping a few known ones as fallbacks. */
    fun remember(working: String, known: List<String>, limit: Int = 4): List<String> = (listOf(working) + known).distinct().take(limit)
}
