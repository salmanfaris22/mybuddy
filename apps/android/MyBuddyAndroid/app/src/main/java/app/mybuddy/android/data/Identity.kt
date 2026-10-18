package app.mybuddy.android.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import app.mybuddy.android.core.crypto.DeviceIdentity
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec

/**
 * This phone's P-256 identity in the Android Keystore. The private key is non-exportable and
 * hardware-backed (StrongBox when present, otherwise the TEE).
 */
class KeystoreIdentity private constructor(private val privateKey: PrivateKey, override val publicKeySpki: ByteArray, val backend: String) : DeviceIdentity {
    override fun sign(message: ByteArray): ByteArray = Signature.getInstance("SHA256withECDSA").run {
        initSign(privateKey)
        update(message)
        sign()
    }

    companion object {
        private const val ALIAS = "mybuddy-identity-v1"

        fun loadOrCreate(): KeystoreIdentity {
            val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            if (!ks.containsAlias(ALIAS)) generate()
            val entry = ks.getEntry(ALIAS, null) as KeyStore.PrivateKeyEntry
            return KeystoreIdentity(entry.privateKey, entry.certificate.publicKey.encoded, backendOf(entry.privateKey))
        }

        private fun generate() {
            fun spec(strongBox: Boolean) = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256)
                .setIsStrongBoxBacked(strongBox)
                .build()
            val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
            try {
                generator.initialize(spec(true))
                generator.generateKeyPair()
            } catch (e: StrongBoxUnavailableException) {
                generator.initialize(spec(false))
                generator.generateKeyPair()
            }
        }

        private fun backendOf(key: PrivateKey): String = try {
            val info = KeyFactory.getInstance(key.algorithm, "AndroidKeyStore").getKeySpec(key, KeyInfo::class.java)
            when (info.securityLevel) {
                KeyProperties.SECURITY_LEVEL_STRONGBOX -> "StrongBox"
                KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT -> "Trusted Execution Environment"
                KeyProperties.SECURITY_LEVEL_SOFTWARE -> "Software keystore"
                else -> "Android Keystore"
            }
        } catch (e: Exception) {
            "Android Keystore"
        }

        fun delete() {
            KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(ALIAS)
        }
    }
}

/** The Mac this phone paired with (public data only; no secrets). */
data class PairedHost(
    val deviceId: String,
    val fingerprint: String,
    val name: String,
    val addresses: List<String>,
    val pairedAtEpochSeconds: Long,
    /** The Mac's public key (SPKI, base64url), learned in the MBH1 handshake; verifies its internet answers. */
    val hostKey: String? = null,
    /** Internet access through MyBuddy Connect, once the user agreed (server URL + pairing id on that server). */
    val connectUrl: String? = null,
    val connectPairingId: String? = null,
)

private val Context.store by preferencesDataStore("mybuddy")

class HostStore(private val context: Context) {
    private object Keys {
        val id = stringPreferencesKey("host_id")
        val fp = stringPreferencesKey("host_fp")
        val name = stringPreferencesKey("host_name")
        val addresses = stringPreferencesKey("host_addresses")
        val pairedAt = longPreferencesKey("host_paired_at")
        val hostKey = stringPreferencesKey("host_key")
        val connectUrl = stringPreferencesKey("connect_url")
        val connectPairing = stringPreferencesKey("connect_pairing")
    }

    val host: Flow<PairedHost?> = context.store.data.map { p ->
        val id = p[Keys.id] ?: return@map null
        PairedHost(id, p[Keys.fp] ?: return@map null, p[Keys.name] ?: "Mac", (p[Keys.addresses] ?: "").split(",").filter { it.isNotBlank() }, p[Keys.pairedAt] ?: 0,
            hostKey = p[Keys.hostKey], connectUrl = p[Keys.connectUrl], connectPairingId = p[Keys.connectPairing])
    }

    suspend fun current(): PairedHost? = host.first()

    suspend fun save(h: PairedHost) {
        context.store.edit {
            it[Keys.id] = h.deviceId
            it[Keys.fp] = h.fingerprint
            it[Keys.name] = h.name
            it[Keys.addresses] = h.addresses.joinToString(",")
            it[Keys.pairedAt] = h.pairedAtEpochSeconds
            if (h.hostKey != null) it[Keys.hostKey] = h.hostKey else it.remove(Keys.hostKey)
            if (h.connectUrl != null) it[Keys.connectUrl] = h.connectUrl else it.remove(Keys.connectUrl)
            if (h.connectPairingId != null) it[Keys.connectPairing] = h.connectPairingId else it.remove(Keys.connectPairing)
        }
    }

    suspend fun forget() {
        context.store.edit { it.clear() }
    }
}
