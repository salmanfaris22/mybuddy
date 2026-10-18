package app.mybuddy.android

import app.mybuddy.android.core.Base64Url
import app.mybuddy.android.core.Hex
import app.mybuddy.android.core.connect.ConnectIds
import app.mybuddy.android.core.connect.ConnectServerUrl
import app.mybuddy.android.core.connect.ConnectStatements
import app.mybuddy.android.core.connect.ConnectTime
import app.mybuddy.android.core.connect.IceRoute
import app.mybuddy.android.core.connect.RendezvousMessage
import app.mybuddy.android.core.connect.SessionRoute
import app.mybuddy.android.core.connect.StatsLite
import app.mybuddy.android.core.crypto.IdentityMath
import app.mybuddy.android.core.crypto.SoftwareIdentity
import app.mybuddy.android.core.crypto.deviceId
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** MyBuddy Connect statements and the signed rendezvous against the shared vectors (same bytes as Swift and Go). */
class ConnectTest {
    private val v = Json.parseToJsonElement(Repo.text("protocol/vectors/mbh1-v1.json")).jsonObject
    private fun section(name: String, k: String) = v.getValue(name).jsonObject.getValue(k).jsonPrimitive.content
    private fun connect(k: String) = section("connect", k)
    private val clientSpki = Base64Url.decode(section("inputs", "clientIdentityKeySpkiB64u"))!!
    private val hostSpki = Base64Url.decode(section("inputs", "hostIdentityKeySpkiB64u"))!!
    private val clientId = section("expected", "clientDeviceId")
    private val hostId = section("expected", "hostDeviceId")

    @Test
    fun statementsMatchTheServerBytes() {
        assertEquals(connect("registerMessageHex"), Hex.encode(ConnectStatements.register(clientSpki, "android")))
        val nonce = Base64Url.decode(connect("challengeNonceB64u"))!!
        assertEquals(connect("authMessageHex"), Hex.encode(ConnectStatements.auth(connect("challengeId"), nonce, clientId)))
        assertEquals(connect("pairingMessageHex"), Hex.encode(ConnectStatements.pairing(hostId, clientId, connect("pairingCreatedAt"))))
        assertEquals(connect("rtcMessageHex"), Hex.encode(ConnectStatements.rtc(connect("rtcKind"), connect("rtcId"), clientId, hostId, connect("rtcAt"), connect("rtcSdp"))))
        assertTrue(IdentityMath.verify(clientSpki, Hex.decode(connect("rtcMessageHex"))!!, Base64Url.decode(connect("rtcClientSignatureDerB64u"))!!))
    }

    @Test
    fun vectorOfferDecodesAndVerifiesOnlyWhenIntact() {
        val m = RendezvousMessage.decode(connect("rtcEnvelopeJson").toByteArray())!!
        val at = ConnectTime.parse(connect("rtcAt"))!!
        assertTrue(m.verify(clientSpki, hostId, at.plusSeconds(30)))
        assertFalse("stale", m.verify(clientSpki, hostId, at.plusSeconds(121)))
        assertFalse("wrong recipient", m.verify(clientSpki, clientId, at))
        assertFalse("wrong signer", m.verify(hostSpki, hostId, at))
        assertFalse("tampered fingerprint", m.copy(sdp = m.sdp!!.replace("1F:2E", "AA:BB")).verify(clientSpki, hostId, at))
    }

    @Test
    fun signedMessagesRoundTripWithTheMacFormat() {
        val phone = SoftwareIdentity()
        val mac = SoftwareIdentity()
        val rid = ConnectIds.newRendezvousId()
        assertTrue(ConnectIds.isRendezvousId(rid))
        val offer = RendezvousMessage.signed(RendezvousMessage.OFFER, rid, phone, mac.deviceId, "v=0\r\n")
        val decoded = RendezvousMessage.decode(offer.encode())!!
        assertEquals(offer, decoded)
        assertTrue(decoded.verify(phone.publicKeySpki, mac.deviceId))
        // A Swift-encoded answer (sorted keys, nils omitted) parses too.
        val swiftStyle = """{"at":"2026-10-16T08:40:01.000Z","from":"$hostId","kind":"answer","rid":"$rid","sdp":"v=0\r\n","sig":"MEUCIQ","to":"$clientId","v":1}"""
        assertNotNull(RendezvousMessage.decode(swiftStyle.toByteArray()))
    }

    @Test
    fun malformedMessagesAreRejected() {
        val ids = """"from":"$clientId","to":"$hostId""""
        assertNull("offer without signature", RendezvousMessage.decode("""{"v":1,"kind":"offer","rid":"r_abcdefgh12",$ids,"sdp":"x"}""".toByteArray()))
        assertNull("unknown kind", RendezvousMessage.decode("""{"v":1,"kind":"shell","rid":"r_abcdefgh12",$ids}""".toByteArray()))
        assertNull("bad rid", RendezvousMessage.decode("""{"v":1,"kind":"bye","rid":"nope",$ids}""".toByteArray()))
        assertNull("unknown field", RendezvousMessage.decode("""{"v":1,"kind":"bye","rid":"r_abcdefgh12",$ids,"cmd":"x"}""".toByteArray()))
        assertNotNull(RendezvousMessage.decode("""{"v":1,"kind":"ice","rid":"r_abcdefgh12",$ids,"candidate":"candidate:1 1 udp 1 10.0.0.2 5000 typ host","sdpMid":"0","sdpMLineIndex":0}""".toByteArray()))
    }

    @Test
    fun serverAddressRules() {
        assertEquals("https://connect.example.com", ConnectServerUrl.normalize("https://connect.example.com", false))
        assertEquals("https://connect.example.com:8443", ConnectServerUrl.normalize(" https://Connect.Example.com:8443/ ", false))
        assertNull("cleartext needs a debug build", ConnectServerUrl.normalize("http://10.0.2.2:8787", false))
        assertEquals("http://10.0.2.2:8787", ConnectServerUrl.normalize("http://10.0.2.2:8787", true))
        assertNull("cleartext only for dev hosts", ConnectServerUrl.normalize("http://connect.example.com", true))
        assertNull(ConnectServerUrl.normalize("https://u:p@connect.example.com", false))
        assertNull(ConnectServerUrl.normalize("https://connect.example.com/v1?x=1", false))
        assertEquals("wss://c.example.com:8443/v1/signal", ConnectServerUrl.signalUrl("https://c.example.com:8443"))
    }

    @Test
    fun iceRouteReadsTheSelectedPair() {
        val direct = listOf(
            StatsLite("T", "transport", mapOf("selectedCandidatePairId" to "P")),
            StatsLite("P", "candidate-pair", mapOf("localCandidateId" to "L", "remoteCandidateId" to "R")),
            StatsLite("L", "local-candidate", mapOf("candidateType" to "srflx")),
            StatsLite("R", "remote-candidate", mapOf("candidateType" to "host")),
        )
        assertEquals(false, IceRoute.isRelayed(direct))
        assertEquals(true, IceRoute.isRelayed(direct.dropLast(1) + StatsLite("R", "remote-candidate", mapOf("candidateType" to "relay"))))
        assertNull(IceRoute.isRelayed(listOf(StatsLite("T", "transport", emptyMap()))))
        assertFalse(SessionRoute.INTERNET_RELAYED.allowsFileTransfer)
        assertTrue(SessionRoute.INTERNET_DIRECT.allowsFileTransfer && SessionRoute.WIFI.allowsFileTransfer)
    }
}
