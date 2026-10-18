package app.mybuddy.android.core.crypto

import app.mybuddy.android.core.Base64Url
import app.mybuddy.android.core.Hex
import app.mybuddy.android.core.lengthPrefixed
import app.mybuddy.android.core.protocol.Envelope
import app.mybuddy.android.core.protocol.EnvelopeCodec
import app.mybuddy.android.core.protocol.EventType
import app.mybuddy.android.core.protocol.ProtocolException
import app.mybuddy.android.core.protocol.ProtocolRole
import app.mybuddy.android.core.protocol.SequenceGuard
import app.mybuddy.android.core.randomBytes
import app.mybuddy.android.core.sha256
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.math.BigInteger
import java.nio.ByteBuffer
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.PublicKey
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPrivateKeySpec
import java.security.spec.ECPublicKeySpec
import java.security.spec.X509EncodedKeySpec
import java.time.Instant
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** A device's long-term ECDSA P-256 identity (Android Keystore in production). */
interface DeviceIdentity {
    /** SubjectPublicKeyInfo DER of the public key. */
    val publicKeySpki: ByteArray

    /** Signs SHA-256(message), returning an ASN.1 DER ECDSA signature. */
    fun sign(message: ByteArray): ByteArray
}

val DeviceIdentity.deviceId: String get() = IdentityMath.deviceId(publicKeySpki)
val DeviceIdentity.fingerprint: String get() = IdentityMath.fingerprint(publicKeySpki)

object IdentityMath {
    fun deviceId(spki: ByteArray): String = Hex.encode(spki.sha256().copyOf(16))
    fun fingerprint(spki: ByteArray): String = Base64Url.encode(spki.sha256())

    fun verify(spki: ByteArray, message: ByteArray, der: ByteArray): Boolean {
        if (spki.size > 200 || der.size > 80) return false
        return try {
            val key = Ec.publicFromSpki(spki) ?: return false
            Signature.getInstance("SHA256withECDSA").run {
                initVerify(key)
                update(message)
                verify(der)
            }
        } catch (e: Exception) {
            false
        }
    }
}

/** P-256 helpers on plain JCA (works on the JVM for tests and on Android). */
object Ec {
    val params: ECParameterSpec by lazy {
        AlgorithmParameters.getInstance("EC").apply { init(ECGenParameterSpec("secp256r1")) }.getParameterSpec(ECParameterSpec::class.java)
    }

    fun generateKeyPair(): KeyPair = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()

    private fun pad32(v: BigInteger): ByteArray {
        val raw = v.toByteArray()
        return when {
            raw.size == 32 -> raw
            raw.size == 33 && raw[0] == 0.toByte() -> raw.copyOfRange(1, 33)
            raw.size < 32 -> ByteArray(32 - raw.size) + raw
            else -> throw IllegalArgumentException("coordinate too large")
        }
    }

    /** X9.63 uncompressed point (0x04 ‖ X ‖ Y). */
    fun x963(pub: ECPublicKey): ByteArray = byteArrayOf(4) + pad32(pub.w.affineX) + pad32(pub.w.affineY)

    /** Parses an X9.63 point and checks it lies on P-256 (guards against invalid-curve inputs). */
    fun publicFromX963(b: ByteArray): PublicKey? {
        if (b.size != 65 || b[0] != 4.toByte()) return null
        val x = BigInteger(1, b.copyOfRange(1, 33))
        val y = BigInteger(1, b.copyOfRange(33, 65))
        val p = (params.curve.field as java.security.spec.ECFieldFp).p
        if (x >= p || y >= p) return null
        val lhs = y.modPow(BigInteger.valueOf(2), p)
        val rhs = x.modPow(BigInteger.valueOf(3), p).add(params.curve.a.multiply(x)).add(params.curve.b).mod(p)
        if (lhs != rhs) return null
        return KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(x, y), params))
    }

    fun privateFromScalar(scalar: ByteArray): PrivateKey =
        KeyFactory.getInstance("EC").generatePrivate(ECPrivateKeySpec(BigInteger(1, scalar), params))

    fun publicFromSpki(spki: ByteArray): ECPublicKey? {
        val key = KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(spki)) as? ECPublicKey ?: return null
        return if (key.params.order == params.order && key.params.curve == params.curve) key else null
    }

    fun ecdh(private: PrivateKey, peer: PublicKey): ByteArray =
        KeyAgreement.getInstance("ECDH").run {
            init(private)
            doPhase(peer, true)
            generateSecret()
        }
}

/** In-memory identity (tests, previews). Production uses `KeystoreIdentity`. */
class SoftwareIdentity(private val privateKey: PrivateKey, override val publicKeySpki: ByteArray) : DeviceIdentity {
    constructor(pair: KeyPair = Ec.generateKeyPair()) : this(pair.private, pair.public.encoded)

    override fun sign(message: ByteArray): ByteArray = Signature.getInstance("SHA256withECDSA").run {
        initSign(privateKey)
        update(message)
        sign()
    }
}

object Hkdf {
    private fun hmac(key: ByteArray, data: ByteArray): ByteArray =
        Mac.getInstance("HmacSHA256").run {
            init(SecretKeySpec(if (key.isEmpty()) ByteArray(32) else key, "HmacSHA256"))
            doFinal(data)
        }

    /** RFC 5869 HKDF-SHA256. */
    fun derive(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val prk = hmac(salt, ikm)
        val out = java.io.ByteArrayOutputStream()
        var t = ByteArray(0)
        var counter = 1
        while (out.size() < length) {
            t = hmac(prk, t + info + byteArrayOf(counter.toByte()))
            out.write(t)
            counter++
        }
        return out.toByteArray().copyOf(length)
    }
}

class SessionKeys(val c2h: ByteArray, val h2c: ByteArray, val sas: String, val sessionId: String)

enum class Mbh1Mode(val wire: String) { PAIR("pair"), RESUME("resume") }

class HandshakeException(val reason: String) : Exception(reason)

/** MBH1 primitives (docs/PROTOCOL.md §6), byte-compatible with the Mac and Go implementations. */
object Mbh1 {
    const val PROTOCOL = 1
    const val MAX_FRAME_BYTES = 192 * 1024

    fun th1(mode: Mbh1Mode, clientEph: ByteArray, clientNonce: ByteArray, hostEph: ByteArray, hostNonce: ByteArray, hostKey: ByteArray): ByteArray =
        ("MBH1/th1".toByteArray() + mode.wire.toByteArray().lengthPrefixed() + clientEph.lengthPrefixed() + clientNonce.lengthPrefixed() +
            hostEph.lengthPrefixed() + hostNonce.lengthPrefixed() + hostKey.lengthPrefixed()).sha256()

    fun th2(th1: ByteArray, clientKey: ByteArray, clientName: String, platform: String): ByteArray =
        ("MBH1/th2".toByteArray() + th1 + clientKey.lengthPrefixed() + clientName.toByteArray().lengthPrefixed() + platform.toByteArray().lengthPrefixed()).sha256()

    fun hostSignedMessage(th1: ByteArray) = "MBH1/host-sig".toByteArray() + th1
    fun clientSignedMessage(th2: ByteArray) = "MBH1/client-sig".toByteArray() + th2

    fun pairingProof(secret: ByteArray, th2: ByteArray): ByteArray = Mac.getInstance("HmacSHA256").run {
        init(SecretKeySpec(secret, "HmacSHA256"))
        doFinal("MBH1/pair-proof".toByteArray() + th2)
    }

    fun deriveSession(shared: ByteArray, th2: ByteArray): SessionKeys {
        val okm = Hkdf.derive(shared, th2, "MBH1/keys".toByteArray(), 64)
        val sasBytes = Hkdf.derive(shared, th2, "MBH1/sas".toByteArray(), 4)
        val sasValue = (ByteBuffer.wrap(sasBytes).int.toLong() and 0xffffffffL) % 1_000_000
        val sid = "s_" + Base64Url.encode(Hkdf.derive(shared, th2, "MBH1/session-id".toByteArray(), 12))
        return SessionKeys(okm.copyOfRange(0, 32), okm.copyOfRange(32, 64), "%06d".format(sasValue), sid)
    }
}

/**
 * The phone side of the MBH1 handshake. Pins the Mac's key fingerprint (from the QR or the
 * stored pairing) and proves knowledge of the QR secret in pair mode.
 */
class Mbh1Client(
    private val mode: Mbh1Mode,
    private val identity: DeviceIdentity,
    private val clientName: String,
    private val platform: String,
    private val pinnedFingerprint: String,
    private val pairingSecret: ByteArray?,
    private val ephemeralPrivate: PrivateKey,
    private val ephemeralPublicX963: ByteArray,
    private val nonce: ByteArray = randomBytes(32),
) {
    class Result(val keys: SessionKeys, val hostIdentityKey: ByteArray) {
        val hostDeviceId: String get() = IdentityMath.deviceId(hostIdentityKey)
    }

    companion object {
        fun create(mode: Mbh1Mode, identity: DeviceIdentity, clientName: String, platform: String, pinnedFingerprint: String, pairingSecret: ByteArray?): Mbh1Client {
            val pair = Ec.generateKeyPair()
            return Mbh1Client(mode, identity, clientName, platform, pinnedFingerprint, pairingSecret, pair.private, Ec.x963(pair.public as ECPublicKey))
        }
    }

    private var sentHello = false

    fun makeHello(): String {
        sentHello = true
        return buildJsonObject {
            put("type", "hs.hello")
            put("protocol", Mbh1.PROTOCOL)
            put("mode", mode.wire)
            put("clientEphemeral", Base64Url.encode(ephemeralPublicX963))
            put("clientNonce", Base64Url.encode(nonce))
        }.toString()
    }

    private fun field(o: JsonObject, name: String, exact: Int? = null, max: Int = 200): ByteArray {
        val s = (o[name] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: throw HandshakeException("malformed: $name")
        val d = Base64Url.decode(s) ?: throw HandshakeException("malformed: $name")
        if (d.isEmpty() || d.size > max || (exact != null && d.size != exact)) throw HandshakeException("malformed: $name")
        return d
    }

    /** Verifies the Mac and returns the `hs.client` reply plus the session keys. */
    fun handleHost(text: String): Pair<String, Result> {
        if (!sentHello) throw HandshakeException("wrong state")
        sentHello = false
        if (text.length > 4096) throw HandshakeException("malformed: too large")
        val o = try {
            Json.parseToJsonElement(text).jsonObject
        } catch (e: Exception) {
            throw HandshakeException("malformed: json")
        }
        if (o["type"]?.jsonPrimitive?.content != "hs.host") throw HandshakeException("malformed: type")
        val hostEph = field(o, "hostEphemeral", exact = 65)
        val hostNonce = field(o, "hostNonce", exact = 32)
        val hostKey = field(o, "hostIdentityKey")
        val hostSig = field(o, "signature", max = 80)
        if (IdentityMath.fingerprint(hostKey) != pinnedFingerprint) throw HandshakeException("host key mismatch")
        val th1 = Mbh1.th1(mode, ephemeralPublicX963, nonce, hostEph, hostNonce, hostKey)
        if (!IdentityMath.verify(hostKey, Mbh1.hostSignedMessage(th1), hostSig)) throw HandshakeException("bad host signature")
        val clientKey = identity.publicKeySpki
        val th2 = Mbh1.th2(th1, clientKey, clientName, platform)
        val signature = identity.sign(Mbh1.clientSignedMessage(th2))
        val hostPublic = Ec.publicFromX963(hostEph) ?: throw HandshakeException("malformed: hostEphemeral")
        val keys = Mbh1.deriveSession(Ec.ecdh(ephemeralPrivate, hostPublic), th2)
        val reply = buildJsonObject {
            put("type", "hs.client")
            put("clientIdentityKey", Base64Url.encode(clientKey))
            put("clientName", clientName)
            put("platform", platform)
            put("signature", Base64Url.encode(signature))
            if (mode == Mbh1Mode.PAIR && pairingSecret != null) put("pairingProof", Base64Url.encode(Mbh1.pairingProof(pairingSecret, th2)))
        }.toString()
        return reply to Result(keys, hostKey)
    }
}

class FrameException(message: String) : Exception(message)

private fun nonceAndAad(direction: Byte, counter: Long): Pair<ByteArray, ByteArray> {
    val ctr = ByteBuffer.allocate(8).putLong(counter).array()
    return (ByteArray(4) + ctr) to ("MBH1/frame".toByteArray() + byteArrayOf(direction) + ctr)
}

class FrameSealer(private val key: ByteArray, private val direction: Byte, start: Long = 0) {
    var counter: Long = start
        private set

    fun seal(plaintext: ByteArray): ByteArray {
        if (plaintext.size + 24 > Mbh1.MAX_FRAME_BYTES) throw FrameException("too large")
        val (nonce, aad) = nonceAndAad(direction, counter)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
            updateAAD(aad)
        }
        val out = ByteBuffer.allocate(8).putLong(counter).array() + cipher.doFinal(plaintext)
        counter++
        return out
    }
}

class FrameOpener(private val key: ByteArray, private val direction: Byte) {
    var expected: Long = 0
        private set

    fun open(frame: ByteArray): ByteArray {
        if (frame.size > Mbh1.MAX_FRAME_BYTES) throw FrameException("too large")
        if (frame.size < 24) throw FrameException("truncated")
        val counter = ByteBuffer.wrap(frame, 0, 8).long
        if (counter != expected) throw FrameException("unexpected counter $counter (expected $expected)")
        val (nonce, aad) = nonceAndAad(direction, counter)
        val plaintext = try {
            Cipher.getInstance("AES/GCM/NoPadding").run {
                init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
                updateAAD(aad)
                doFinal(frame, 8, frame.size - 8)
            }
        } catch (e: Exception) {
            throw FrameException("authentication failed")
        }
        expected++
        return plaintext
    }
}

const val DIRECTION_C2H: Byte = 1
const val DIRECTION_H2C: Byte = 2

/** An established MBH1 session on the phone: encrypts envelopes and enforces envelope rules. */
class SecureSession(keys: SessionKeys) {
    val sessionId = keys.sessionId
    val sas = keys.sas
    private val sealer = FrameSealer(keys.c2h, DIRECTION_C2H)
    private val opener = FrameOpener(keys.h2c, DIRECTION_H2C)
    private var nextSequence = 0L
    private val guard = SequenceGuard()

    @Synchronized
    fun seal(type: EventType, payload: JsonObject, replyTo: Long? = null, now: Instant = Instant.now()): Pair<ByteArray, Long> {
        nextSequence++
        val envelope = Envelope(type, sessionId, nextSequence, now, replyTo, payload)
        return sealer.seal(EnvelopeCodec.encode(envelope, ProtocolRole.MAC)) to nextSequence
    }

    /** Frame errors are fatal; [ProtocolException] may be answered with an `error` event. */
    @Synchronized
    fun open(frame: ByteArray): Envelope {
        val envelope = EnvelopeCodec.decode(opener.open(frame), ProtocolRole.PHONE)
        if (envelope.sessionId != sessionId) throw FrameException("session mismatch")
        guard.accept(envelope)
        return envelope
    }
}
