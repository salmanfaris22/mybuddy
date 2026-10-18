package app.mybuddy.android.core.session

/**
 * Tailscale address rules, mirroring the Mac's `Tailnet` (docs/CONNECTIVITY.md §2, §5). Tailscale gives every
 * device an IPv4 from 100.64.0.0/10 and an IPv6 from fd7a:115c:a1e0::/48; MagicDNS names end in `.ts.net`.
 */
object Tailnet {
    const val DEFAULT_PORT = 47811

    enum class Route { Wifi, Tailscale }

    fun isTailnetIPv4(host: String): Boolean {
        val o = host.split(".")
        if (o.size != 4 || !o.all { it.length in 1..3 && it.all(Char::isDigit) && it.toInt() <= 255 }) return false
        return o[0].toInt() == 100 && o[1].toInt() in 64..127
    }

    /** fd7a:115c:a1e0::/48 — parsed without DNS (only hex digits and colons are accepted). */
    fun isTailnetIPv6(host: String): Boolean {
        val h = host.trim('[', ']').substringBefore('%').lowercase()
        if (h.isEmpty() || !h.all { it in "0123456789abcdef:" } || h.count { it == ':' } < 2) return false
        val groups = expand(h) ?: return false
        return groups[0] == 0xfd7a && groups[1] == 0x115c && groups[2] == 0xa1e0
    }

    fun isTailnetAddress(host: String) = isTailnetIPv4(host) || isTailnetIPv6(host)

    /** `machine.tailnet.ts.net` (syntax only; the phone resolves it and requires tailnet addresses). */
    fun isMagicDnsName(host: String): Boolean {
        val h = host.lowercase()
        if (!h.endsWith(".ts.net") || h.length > 253) return false
        val labels = h.split(".")
        return labels.size >= 4 && labels.all { l ->
            l.isNotEmpty() && l.length <= 63 && !l.startsWith("-") && !l.endsWith("-") && l.all { it in 'a'..'z' || it in '0'..'9' || it == '-' }
        }
    }

    /** The host part of `host:port` or `[v6]:port`. */
    fun hostOf(hostPort: String): String? = if (hostPort.startsWith("[")) {
        hostPort.substringAfter('[').substringBefore(']').takeIf { hostPort.contains("]:") }
    } else {
        hostPort.substringBeforeLast(':', "").takeIf { it.isNotEmpty() && ':' !in it }
    }

    private fun portOf(hostPort: String): Int? = hostPort.substringAfterLast(':').toIntOrNull()?.takeIf { it in 1..65535 }

    /** A stored Tailscale `host:port`: a tailnet IP literal or a MagicDNS name, with a valid port. */
    fun isUserHostPort(s: String): Boolean {
        val host = hostOf(s) ?: return false
        return portOf(s) != null && (isTailnetAddress(host) || isMagicDnsName(host))
    }

    /** Normalizes what someone typed ("100.101.102.103", "mac.tail1234.ts.net:47811", "fd7a:115c:a1e0::5") or null. */
    fun normalizeUserAddress(input: String, defaultPort: Int = DEFAULT_PORT): String? {
        val t = input.trim().removePrefix("ws://").trimEnd('/')
        if (t.isEmpty() || t.length > 260) return null
        val candidate = when {
            t.startsWith("[") -> t
            t.count { it == ':' } >= 2 -> "[$t]:$defaultPort" // bare IPv6
            ':' in t -> t
            else -> "$t:$defaultPort"
        }
        val host = hostOf(candidate) ?: return null
        val port = portOf(candidate) ?: return null
        val normalizedHost = host.lowercase()
        return when {
            isTailnetIPv4(normalizedHost) || isMagicDnsName(normalizedHost) -> "$normalizedHost:$port"
            isTailnetIPv6(normalizedHost) -> "[$normalizedHost]:$port"
            else -> null
        }
    }

    fun route(hostPort: String): Route {
        val host = hostOf(hostPort) ?: return Route.Wifi
        return if (isTailnetAddress(host) || isMagicDnsName(host)) Route.Tailscale else Route.Wifi
    }

    private fun expand(h: String): IntArray? {
        val parts = h.split("::")
        if (parts.size > 2) return null
        val head = if (parts[0].isEmpty()) emptyList() else parts[0].split(":")
        val tail = if (parts.size == 2 && parts[1].isNotEmpty()) parts[1].split(":") else emptyList()
        if (head.any { it.isEmpty() || it.length > 4 } || tail.any { it.isEmpty() || it.length > 4 }) return null
        val missing = 8 - head.size - tail.size
        if (parts.size == 1 && missing != 0 || missing < 0) return null
        return (head + List(missing) { "0" } + tail).map { it.toInt(16) }.toIntArray()
    }
}
