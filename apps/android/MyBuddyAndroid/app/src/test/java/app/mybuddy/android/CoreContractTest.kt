package app.mybuddy.android

import app.mybuddy.android.core.Base64Url
import app.mybuddy.android.core.Hex
import app.mybuddy.android.core.crypto.DIRECTION_C2H
import app.mybuddy.android.core.crypto.DIRECTION_H2C
import app.mybuddy.android.core.crypto.Ec
import app.mybuddy.android.core.crypto.FrameException
import app.mybuddy.android.core.crypto.FrameOpener
import app.mybuddy.android.core.crypto.FrameSealer
import app.mybuddy.android.core.crypto.HandshakeException
import app.mybuddy.android.core.crypto.IdentityMath
import app.mybuddy.android.core.crypto.Mbh1
import app.mybuddy.android.core.crypto.Mbh1Client
import app.mybuddy.android.core.crypto.Mbh1Mode
import app.mybuddy.android.core.crypto.SecureSession
import app.mybuddy.android.core.crypto.SoftwareIdentity
import app.mybuddy.android.core.crypto.fingerprint
import app.mybuddy.android.core.protocol.Envelope
import app.mybuddy.android.core.protocol.EnvelopeCodec
import app.mybuddy.android.core.protocol.EventCatalog
import app.mybuddy.android.core.protocol.EventType
import app.mybuddy.android.core.protocol.FileNameRules
import app.mybuddy.android.core.protocol.ProtocolException
import app.mybuddy.android.core.protocol.ProtocolRole
import app.mybuddy.android.core.session.Backoff
import app.mybuddy.android.core.session.PairingException
import app.mybuddy.android.core.session.PairingInvitation
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.time.Instant

/** Locates the repository root (contains protocol/) from the Gradle module directory. */
object Repo {
    val root: File by lazy {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            if (File(dir, "protocol/schema/events.v1.json").exists()) return@lazy dir
            dir = dir.parentFile
        }
        error("repository root not found")
    }

    fun text(path: String) = File(root, path).readText()
    fun bytes(path: String) = File(root, path).readBytes()
}

class ProtocolContractTest {
    @Test
    fun embeddedCatalogIsByteIdenticalToSharedFile() {
        assertEquals("run scripts/embed-catalog.sh", Repo.text("protocol/schema/events.v1.json"), EventCatalog.embeddedJson)
    }

    @Test
    fun eventTypesMatchCatalogExactly() {
        val catalog = EventCatalog.shared
        assertEquals(catalog.events.keys, EventType.entries.map { it.wire }.toSet())
        assertEquals(66, catalog.events.size)
    }

    private fun manifest(section: String) =
        Json.parseToJsonElement(Repo.text("protocol/fixtures/manifest.json")).jsonObject.getValue(section).jsonArray.map { it.jsonObject }

    @Test
    fun allValidFixturesDecode() {
        val cases = manifest("valid")
        assertTrue(cases.size >= 30)
        for (c in cases) {
            val file = c.getValue("file").jsonPrimitive.content
            val receiver = ProtocolRole.valueOf(c.getValue("receiver").jsonPrimitive.content.uppercase())
            try {
                val e = EnvelopeCodec.decode(Repo.bytes("protocol/fixtures/$file"), receiver)
                assertEquals(file, c.getValue("type").jsonPrimitive.content, e.type.wire)
            } catch (ex: ProtocolException) {
                fail("$file rejected: ${ex.error}")
            }
        }
    }

    @Test
    fun allInvalidFixturesAreRejectedWithExpectedCode() {
        val cases = manifest("invalid")
        assertTrue(cases.size >= 25)
        for (c in cases) {
            val file = c.getValue("file").jsonPrimitive.content
            val receiver = ProtocolRole.valueOf(c.getValue("receiver").jsonPrimitive.content.uppercase())
            try {
                val e = EnvelopeCodec.decode(Repo.bytes("protocol/fixtures/$file"), receiver)
                fail("$file accepted as ${e.type}")
            } catch (ex: ProtocolException) {
                assertEquals(file, c.getValue("error").jsonPrimitive.content, ex.error.code)
            }
        }
    }

    @Test
    fun encodeSelfValidatesAndRoundTrips() {
        val payload = buildJsonObject { put("x", 0.25); put("y", 0.75); put("displayId", "1"); put("action", "move") }
        val e = Envelope(EventType.INPUT_POINTER, "s_test00001", 7, Instant.ofEpochSecond(1_792_131_000), null, payload)
        val back = EnvelopeCodec.decode(EnvelopeCodec.encode(e, ProtocolRole.MAC), ProtocolRole.MAC)
        assertEquals(EventType.INPUT_POINTER, back.type)
        assertEquals(7L, back.sequence)
        val bad = e.copy(payload = buildJsonObject { put("x", 2); put("y", 0.5); put("displayId", "1"); put("action", "move") })
        try {
            EnvelopeCodec.encode(bad, ProtocolRole.MAC)
            fail("out-of-range pointer must not be sendable")
        } catch (ex: ProtocolException) {
            assertEquals("invalid_payload", ex.error.code)
        }
    }

    @Test
    fun fileNameRulesMatchTheMac() {
        listOf("report.pdf", "Photo 2026.HEIC", "résumé.txt", ".hidden").forEach { assertTrue(it, FileNameRules.isSafe(it)) }
        listOf("", ".", "..", "a/b", "a\\b", "a:b", "x\u0007", " lead", "trail ", "dot.").forEach { assertFalse(it, FileNameRules.isSafe(it)) }
    }

    @Test
    fun base64UrlIsStrict() {
        assertArrayEquals("Hello".toByteArray(), Base64Url.decode("SGVsbG8"))
        assertEquals(null, Base64Url.decode("SGVsbG8="))
        assertEquals(null, Base64Url.decode("SGV+bG8"))
        assertEquals("-_8", Base64Url.encode(byteArrayOf(0xfb.toByte(), 0xff.toByte())))
    }
}

class Mbh1VectorTest {
    private val v = Json.parseToJsonElement(Repo.text("protocol/vectors/mbh1-v1.json")).jsonObject
    private val inputs = v.getValue("inputs").jsonObject
    private val expected = v.getValue("expected").jsonObject

    private fun input(k: String) = inputs.getValue(k).jsonPrimitive.content
    private fun expect(k: String) = expected.getValue(k).jsonPrimitive.content
    private fun b64(k: String) = Base64Url.decode(input(k))!!
    private fun hex(k: String) = Hex.decode(input(k))!!

    private fun hostMessage(): String = buildJsonObject {
        put("type", "hs.host")
        put("hostEphemeral", input("hostEphemeralX963B64u"))
        put("hostNonce", input("hostNonceB64u"))
        put("hostIdentityKey", input("hostIdentityKeySpkiB64u"))
        put("signature", expect("hostSignatureDerB64u"))
    }.toString()

    private fun client(pin: String = expect("hostFingerprint"), secret: ByteArray? = b64("pairingSecretB64u")) = Mbh1Client(
        mode = Mbh1Mode.PAIR,
        identity = SoftwareIdentity(Ec.privateFromScalar(hex("clientIdentityPrivateScalarHex")), b64("clientIdentityKeySpkiB64u")),
        clientName = input("clientName"),
        platform = input("platform"),
        pinnedFingerprint = pin,
        pairingSecret = secret,
        ephemeralPrivate = Ec.privateFromScalar(hex("clientEphemeralPrivateScalarHex")),
        ephemeralPublicX963 = b64("clientEphemeralX963B64u"),
        nonce = b64("clientNonceB64u"),
    )

    @Test
    fun identityMathMatchesGo() {
        assertEquals(expect("hostDeviceId"), IdentityMath.deviceId(b64("hostIdentityKeySpkiB64u")))
        assertEquals(expect("clientDeviceId"), IdentityMath.deviceId(b64("clientIdentityKeySpkiB64u")))
        assertEquals(expect("hostFingerprint"), IdentityMath.fingerprint(b64("hostIdentityKeySpkiB64u")))
    }

    @Test
    fun transcriptsSignaturesAndKeysMatchVectors() {
        val th1 = Mbh1.th1(Mbh1Mode.PAIR, b64("clientEphemeralX963B64u"), b64("clientNonceB64u"), b64("hostEphemeralX963B64u"), b64("hostNonceB64u"), b64("hostIdentityKeySpkiB64u"))
        assertEquals(expect("th1Hex"), Hex.encode(th1))
        assertTrue(IdentityMath.verify(b64("hostIdentityKeySpkiB64u"), Mbh1.hostSignedMessage(th1), Base64Url.decode(expect("hostSignatureDerB64u"))!!))
        val th2 = Mbh1.th2(th1, b64("clientIdentityKeySpkiB64u"), input("clientName"), input("platform"))
        assertEquals(expect("th2Hex"), Hex.encode(th2))
        assertTrue(IdentityMath.verify(b64("clientIdentityKeySpkiB64u"), Mbh1.clientSignedMessage(th2), Base64Url.decode(expect("clientSignatureDerB64u"))!!))
        assertFalse(IdentityMath.verify(b64("hostIdentityKeySpkiB64u"), Mbh1.clientSignedMessage(th2), Base64Url.decode(expect("clientSignatureDerB64u"))!!))
        assertEquals(expect("pairingProofB64u"), Base64Url.encode(Mbh1.pairingProof(b64("pairingSecretB64u"), th2)))

        val shared = Ec.ecdh(Ec.privateFromScalar(hex("clientEphemeralPrivateScalarHex")), Ec.publicFromX963(b64("hostEphemeralX963B64u"))!!)
        assertEquals(expect("sharedSecretHex"), Hex.encode(shared))
        val keys = Mbh1.deriveSession(shared, th2)
        assertEquals(expect("keyC2HHex"), Hex.encode(keys.c2h))
        assertEquals(expect("keyH2CHex"), Hex.encode(keys.h2c))
        assertEquals(expect("sas"), keys.sas)
        assertEquals(expect("sessionId"), keys.sessionId)
    }

    @Test
    fun clientHandshakeAgainstGoHostMessageReproducesSession() {
        val c = client()
        val hello = Json.parseToJsonElement(c.makeHello()).jsonObject
        assertEquals("pair", hello.getValue("mode").jsonPrimitive.content)
        val (reply, result) = c.handleHost(hostMessage())
        assertEquals(expect("sessionId"), result.keys.sessionId)
        assertEquals(expect("sas"), result.keys.sas)
        assertEquals(expect("hostDeviceId"), result.hostDeviceId)
        val r = Json.parseToJsonElement(reply).jsonObject
        assertEquals(expect("pairingProofB64u"), r.getValue("pairingProof").jsonPrimitive.content)
        val th2 = Hex.decode(expect("th2Hex"))!!
        val sig = Base64Url.decode(r.getValue("signature").jsonPrimitive.content)!!
        assertTrue("our signature verifies under our key", IdentityMath.verify(b64("clientIdentityKeySpkiB64u"), Mbh1.clientSignedMessage(th2), sig))
    }

    @Test
    fun framesAreByteIdenticalAcrossLanguages() {
        val c2h = Hex.decode(expect("keyC2HHex"))!!
        val h2c = Hex.decode(expect("keyH2CHex"))!!
        val sealer = FrameSealer(c2h, DIRECTION_C2H)
        val frames = expected.getValue("frames").jsonArray.map { it.jsonObject }
        for (f in frames) {
            val plaintext = f.getValue("plaintext").jsonPrimitive.content.toByteArray()
            val frame = Base64Url.decode(f.getValue("frameB64u").jsonPrimitive.content)!!
            if (f.getValue("direction").jsonPrimitive.content == "c2h") {
                assertArrayEquals(frame, sealer.seal(plaintext))
            } else {
                assertArrayEquals(plaintext, FrameOpener(h2c, DIRECTION_H2C).open(frame))
            }
        }
        // The phone session decrypts and validates the Mac's pairing.approved frame.
        val (_, result) = client().run { makeHello(); handleHost(hostMessage()) }
        val session = SecureSession(result.keys)
        val h2cFrame = frames.first { it.getValue("direction").jsonPrimitive.content == "h2c" }
        val envelope = session.open(Base64Url.decode(h2cFrame.getValue("frameB64u").jsonPrimitive.content)!!)
        assertEquals(EventType.PAIRING_APPROVED, envelope.type)
        assertEquals(expect("hostDeviceId"), envelope.payload.getValue("hostDeviceId").jsonPrimitive.content)
    }

    @Test
    fun handshakeRejectsWrongPinAndTamperedHost() {
        try {
            client(pin = SoftwareIdentity().fingerprint).run { makeHello(); handleHost(hostMessage()) }
            fail("wrong pin accepted")
        } catch (e: HandshakeException) {
            assertEquals("host key mismatch", e.reason)
        }
        val tampered = Json.parseToJsonElement(hostMessage()).jsonObject.toMutableMap()
        tampered["hostNonce"] = JsonPrimitive(Base64Url.encode(ByteArray(32) { 1 }))
        try {
            client().run { makeHello(); handleHost(JsonObject(tampered).toString()) }
            fail("tampered host message accepted")
        } catch (e: HandshakeException) {
            assertEquals("bad host signature", e.reason)
        }
    }

    @Test
    fun framesRejectTamperingReplayAndWrongDirection() {
        val key = ByteArray(32) { it.toByte() }
        val sealer = FrameSealer(key, DIRECTION_C2H)
        val f0 = sealer.seal("zero".toByteArray())
        val f1 = sealer.seal("one".toByteArray())
        val tampered = f0.copyOf().also { it[it.size - 1] = (it[it.size - 1].toInt() xor 1).toByte() }
        assertThrows { FrameOpener(key, DIRECTION_C2H).open(tampered) }
        assertThrows { FrameOpener(key, DIRECTION_H2C).open(f0) }
        assertThrows { FrameOpener(key, DIRECTION_C2H).open(f1) }
        val ok = FrameOpener(key, DIRECTION_C2H)
        assertArrayEquals("zero".toByteArray(), ok.open(f0))
        assertArrayEquals("one".toByteArray(), ok.open(f1))
        assertThrows { ok.open(f1) }
    }

    @Test
    fun invalidCurvePointsAreRejected() {
        val bad = b64("hostEphemeralX963B64u").copyOf().also { it[64] = (it[64].toInt() xor 1).toByte() }
        assertEquals(null, Ec.publicFromX963(bad))
        assertNotNull(Ec.publicFromX963(b64("hostEphemeralX963B64u")))
    }

    private fun assertThrows(block: () -> Unit) {
        try {
            block()
            fail("expected FrameException")
        } catch (e: FrameException) {
            // expected
        }
    }
}

class PairingAndBackoffTest {
    @Test
    fun parsesTheVectorQrUrl() {
        val v = Json.parseToJsonElement(Repo.text("protocol/vectors/mbh1-v1.json")).jsonObject
        val expected = v.getValue("expected").jsonObject
        val inv = PairingInvitation.parse(expected.getValue("qrUrl").jsonPrimitive.content, Instant.ofEpochSecond(1_792_130_000))
        assertEquals(expected.getValue("hostFingerprint").jsonPrimitive.content, inv.hostFingerprint)
        assertEquals(listOf("192.168.1.20:47811"), inv.addresses)
        assertEquals("Salman’s MacBook Air", inv.displayName)
    }

    @Test
    fun rejectsBadOrExpiredCodes() {
        val now = Instant.ofEpochSecond(1_792_130_000)
        val good = "mybuddy://pair?v=1&h=10.0.0.2:47811&fp=${"A".repeat(43)}&s=${Base64Url.encode(ByteArray(32) { 1 })}&x=1792131000&n=Mac"
        PairingInvitation.parse(good, now)
        listOf(
            good.replace("mybuddy://", "https://"), good.replace("v=1", "v=2"), good.replace("10.0.0.2:47811", "10.0.0.2"),
            good.replace("10.0.0.2:47811", "evil.example/x:80"), good.replace("&n=Mac", "&n=Mac&n=Other"),
        ).forEach {
            try {
                PairingInvitation.parse(it, now)
                fail("accepted $it")
            } catch (e: PairingException) {
                // expected
            }
        }
        try {
            PairingInvitation.parse(good, Instant.ofEpochSecond(1_792_131_001))
            fail("expired code accepted")
        } catch (e: PairingException) {
            assertTrue(e.message!!.contains("expired"))
        }
    }

    @Test
    fun pairingAddressesMustStayOnTheLocalNetwork() {
        listOf("10.0.0.2:47811", "192.168.1.20:47811", "172.16.0.9:47811", "100.100.1.2:47811", "127.0.0.1:47811",
            "mac.local:47811", "[fe80::1%en0]:47811", "[fd12::1]:47811").forEach { assertTrue(it, PairingInvitation.isValidHostPort(it)) }
        listOf("8.8.8.8:47811", "172.32.0.1:47811", "evil.example:47811", "[2001:db8::1]:47811", "100.128.0.1:47811", "1.2.3:47811")
            .forEach { assertFalse(it, PairingInvitation.isValidHostPort(it)) }
        val now = Instant.ofEpochSecond(1_792_130_000)
        val public = "mybuddy://pair?v=1&h=10.0.0.2:47811,8.8.8.8:47811&fp=${"A".repeat(43)}&s=${Base64Url.encode(ByteArray(32) { 1 })}&x=1792131000&n=Mac"
        try {
            PairingInvitation.parse(public, now)
            fail("accepted an invitation that dials a public address")
        } catch (e: PairingException) {
            // expected
        }
    }

    @Test
    fun backoffIsBounded() {
        val b = Backoff(base = 0.5, cap = 30.0, maxAttempts = 8)
        val delays = generateSequence { b.nextDelay { it } }.toList()
        assertEquals(listOf(0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 30.0, 30.0), delays)
        assertEquals(null, b.nextDelay())
    }
}
