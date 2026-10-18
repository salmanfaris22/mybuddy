package app.mybuddy.android

import app.mybuddy.android.core.session.PairingInvitation
import app.mybuddy.android.core.session.Tailnet
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors the Mac's TailnetTests so both platforms apply the same rules. */
class TailnetTest {
    @Test
    fun ipv4RangeIs100_64Slash10() {
        listOf("100.64.0.1", "100.101.102.103", "100.127.255.254").forEach { assertTrue(it, Tailnet.isTailnetIPv4(it)) }
        listOf("100.63.255.255", "100.128.0.1", "10.0.0.1", "192.168.1.2", "1.2.3", "garbage", "").forEach { assertFalse(it, Tailnet.isTailnetIPv4(it)) }
    }

    @Test
    fun ipv6RangeIsFd7a115cA1e0Slash48() {
        listOf("fd7a:115c:a1e0::1", "fd7a:115c:a1e0:ab12:4843:cd96:627e:9975", "[fd7a:115c:a1e0::5]", "FD7A:115C:A1E0::9").forEach { assertTrue(it, Tailnet.isTailnetIPv6(it)) }
        listOf("fd7a:115c:a1e1::1", "fd12:3456::1", "fe80::1%utun4", "::1", "100.101.102.103", "fd7a:zz::1").forEach { assertFalse(it, Tailnet.isTailnetIPv6(it)) }
    }

    @Test
    fun magicDnsNamesNeedMachineAndTailnetLabels() {
        assertTrue(Tailnet.isMagicDnsName("macbook-air.tail1234.ts.net"))
        assertTrue(Tailnet.isMagicDnsName("MacBook-Air.Tail1234.TS.NET"))
        listOf("ts.net", "x.ts.net", "evil.ts.net.attacker.com", "-bad.tail.ts.net", "a..b.ts.net", "mac.local", "under_score.tail.ts.net")
            .forEach { assertFalse(it, Tailnet.isMagicDnsName(it)) }
    }

    @Test
    fun normalizesWhatPeopleType() {
        assertEquals("100.95.205.31:47811", Tailnet.normalizeUserAddress(" 100.95.205.31 "))
        assertEquals("100.95.205.31:50000", Tailnet.normalizeUserAddress("100.95.205.31:50000"))
        assertEquals("[fd7a:115c:a1e0::202d:cd20]:47811", Tailnet.normalizeUserAddress("fd7a:115c:a1e0::202d:cd20"))
        assertEquals("macbook-air.tail1234.ts.net:47811", Tailnet.normalizeUserAddress("MacBook-Air.tail1234.ts.net"))
        listOf("192.168.1.231", "8.8.8.8", "example.com", "100.95.205.31:0", "100.95.205.31:99999", "", "ws://").forEach {
            assertNull(it, Tailnet.normalizeUserAddress(it))
        }
    }

    @Test
    fun routesAndStoredAddressValidity() {
        assertEquals(Tailnet.Route.Tailscale, Tailnet.route("100.95.205.31:47811"))
        assertEquals(Tailnet.Route.Tailscale, Tailnet.route("[fd7a:115c:a1e0::5]:47811"))
        assertEquals(Tailnet.Route.Tailscale, Tailnet.route("mac.tail1234.ts.net:47811"))
        assertEquals(Tailnet.Route.Wifi, Tailnet.route("192.168.1.231:47811"))
        assertTrue(Tailnet.isUserHostPort("mac.tail1234.ts.net:47811"))
        assertFalse("public names are never dialled", Tailnet.isUserHostPort("example.com:47811"))
        // Invitations keep their stricter rules: names other than .local are not accepted there.
        assertFalse(PairingInvitation.isValidHostPort("mac.tail1234.ts.net:47811"))
        assertTrue(PairingInvitation.isValidHostPort("100.95.205.31:47811"))
    }
}
