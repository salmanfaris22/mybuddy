package app.mybuddy.android

import app.mybuddy.android.core.session.Discovery
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DiscoveryTest {
    private val fp = "o0afD6sjzRwi0lxs5fGbVgAvi9K1cRTaibmcCpcmWh0"

    @Test
    fun matchingFingerprintPrefixGivesLanAddressesIpv4First() {
        val found = Discovery.addresses("o0afD6sj", fp, listOf("fd12:3456::7", "192.168.1.231", "fe80::1c2a:3bff"), 47811)
        assertEquals(listOf("192.168.1.231:47811", "[fd12:3456::7]:47811"), found)
    }

    @Test
    fun otherMacsAndMalformedRecordsAreIgnored() {
        assertTrue(Discovery.addresses("ZZZZZZZZ", fp, listOf("192.168.1.9"), 47811).isEmpty())
        assertTrue(Discovery.addresses(null, fp, listOf("192.168.1.9"), 47811).isEmpty())
        assertTrue("a short prefix would match too much", Discovery.addresses("o0", fp, listOf("192.168.1.9"), 47811).isEmpty())
        assertTrue(Discovery.addresses("o0afD6sj", fp, listOf("192.168.1.9"), 0).isEmpty())
    }

    @Test
    fun publicAddressesAreNeverDialedEvenIfAdvertised() {
        assertTrue(Discovery.addresses("o0afD6sj", fp, listOf("8.8.8.8", "203.0.113.5"), 47811).isEmpty())
    }

    @Test
    fun workingAddressMovesToTheFront() {
        assertEquals(listOf("192.168.1.40:47811", "192.168.1.231:47811"), Discovery.remember("192.168.1.40:47811", listOf("192.168.1.231:47811", "192.168.1.40:47811")))
        assertEquals(4, Discovery.remember("a:1", listOf("b:1", "c:1", "d:1", "e:1", "f:1")).size)
    }
}
