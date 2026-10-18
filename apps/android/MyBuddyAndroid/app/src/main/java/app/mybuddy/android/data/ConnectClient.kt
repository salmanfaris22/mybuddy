package app.mybuddy.android.data

import app.mybuddy.android.core.Base64Url
import app.mybuddy.android.core.connect.ConnectIds
import app.mybuddy.android.core.connect.ConnectServerUrl
import app.mybuddy.android.core.connect.ConnectStatements
import app.mybuddy.android.core.connect.ConnectTime
import app.mybuddy.android.core.connect.TurnCredentials
import app.mybuddy.android.core.crypto.DeviceIdentity
import app.mybuddy.android.core.crypto.deviceId
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.time.Instant
import java.util.concurrent.TimeUnit

class ConnectException(val code: String, message: String) : Exception(message)

/**
 * HTTPS client for the user's own MyBuddy Connect server (PROTOCOL §7). The Keystore device key is the only
 * credential; the 15-minute bearer token is kept in memory and never logged.
 */
class ConnectClient(val server: String, private val identity: DeviceIdentity) {
    private val http = OkHttpClient.Builder()
        .connectTimeout(8, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .pingInterval(25, TimeUnit.SECONDS)
        .build()
    private val json = Json { ignoreUnknownKeys = true }
    private var token: Pair<String, Instant>? = null

    suspend fun register() {
        val spki = identity.publicKeySpki
        val proof = identity.sign(ConnectStatements.register(spki, "android"))
        val (status, body) = call("POST", "/v1/devices", buildJsonObject {
            put("publicKey", Base64Url.encode(spki)); put("platform", "android"); put("proof", Base64Url.encode(proof))
        })
        if (status != 200 && status != 201) throw error(status, body)
        if (body?.get("deviceId")?.jsonPrimitive?.content != identity.deviceId) throw ConnectException("bad_answer", "The server returned a different device id.")
    }

    suspend fun token(): String {
        token?.let { (value, expires) -> if (expires.isAfter(Instant.now().plusSeconds(60))) return value }
        register()
        val (s1, challenge) = call("POST", "/v1/auth/challenge", buildJsonObject { put("deviceId", identity.deviceId) })
        if (s1 != 200 || challenge == null) throw error(s1, challenge)
        val challengeId = challenge["challengeId"]?.jsonPrimitive?.content ?: throw ConnectException("bad_answer", "Malformed challenge.")
        val nonce = challenge["nonce"]?.jsonPrimitive?.content?.let { Base64Url.decode(it) } ?: throw ConnectException("bad_answer", "Malformed challenge.")
        val signature = identity.sign(ConnectStatements.auth(challengeId, nonce, identity.deviceId))
        val (s2, answer) = call("POST", "/v1/auth/token", buildJsonObject {
            put("challengeId", challengeId); put("deviceId", identity.deviceId); put("signature", Base64Url.encode(signature))
        })
        if (s2 != 200 || answer == null) throw error(s2, answer)
        val value = answer["token"]?.jsonPrimitive?.content?.takeIf { it.length == 43 } ?: throw ConnectException("bad_answer", "Malformed token.")
        val expires = answer["expiresAt"]?.jsonPrimitive?.content?.let { ConnectTime.parse(it) } ?: Instant.now().plusSeconds(14 * 60)
        token = value to expires
        return value
    }

    fun dropToken() {
        token = null
    }

    suspend fun turnCredentials(): TurnCredentials? {
        val (status, body) = authed("GET", "/v1/turn-credentials")
        if (status == 503) return null
        if (status != 200 || body == null) throw error(status, body)
        return json.decodeFromJsonElement(TurnCredentials.serializer(), body)
    }

    suspend fun revokePairing(pairingId: String) {
        val (status, body) = authed("DELETE", "/v1/pairings/${pairingId.filter { it.isLetterOrDigit() || it == '_' || it == '-' }}")
        if (status != 204 && status != 404) throw error(status, body)
    }

    /** Pairing ids this phone is part of that are still active on the server. */
    suspend fun activePairings(): Set<String> {
        val (status, body) = authed("GET", "/v1/pairings")
        if (status != 200 || body == null) throw error(status, body)
        return body["pairings"]?.jsonArray?.mapNotNull { p ->
            val o = p.jsonObject
            if (o["revokedAt"] != null) null else o["pairingId"]?.jsonPrimitive?.content
        }?.toSet() ?: emptySet()
    }

    /** Opens `/v1/signal` with a fresh token. */
    suspend fun openSignal(): ConnectSignal {
        val signal = ConnectSignal(http, Request.Builder().url(ConnectServerUrl.signalUrl(server)).header("Authorization", "Bearer ${token()}").build())
        if (withTimeoutOrNull(10_000) { signal.opened.await() } == null) {
            signal.close()
            throw ConnectException("timeout", "The server didn’t answer.")
        }
        return signal
    }

    private suspend fun authed(method: String, path: String): Pair<Int, JsonObject?> {
        val first = call(method, path, null, token())
        if (first.first != 401) return first
        dropToken()
        return call(method, path, null, token())
    }

    private suspend fun call(method: String, path: String, body: JsonObject?, bearer: String? = null): Pair<Int, JsonObject?> = withContext(Dispatchers.IO) {
        val request = Request.Builder().url(server + path).header("Accept", "application/json").apply {
            if (bearer != null) header("Authorization", "Bearer $bearer")
            val payload = body?.toString()?.toRequestBody("application/json".toMediaType())
            method(method, payload ?: if (method == "POST") "{}".toRequestBody("application/json".toMediaType()) else null)
        }.build()
        try {
            http.newCall(request).execute().use { r ->
                val text = r.body.string()
                r.code to runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull()
            }
        } catch (e: Exception) {
            throw ConnectException("unreachable", "Can’t reach ${server.substringAfter("://")} (${e.javaClass.simpleName}).")
        }
    }

    private fun error(status: Int, body: JsonObject?): ConnectException {
        val e = body?.get("error")?.jsonObject
        return ConnectException(e?.get("code")?.jsonPrimitive?.content?.take(64) ?: "http_$status",
            e?.get("message")?.jsonPrimitive?.content?.take(200) ?: "Unexpected answer from the server (HTTP $status).")
    }
}

/** The `/v1/signal` WebSocket while an internet connection is being set up or running. */
class ConnectSignal(client: OkHttpClient, request: Request) : WebSocketListener() {
    sealed class Event {
        data class Relay(val from: String, val data: ByteArray) : Event()
        data class Presence(val peers: Map<String, Boolean>) : Event()
        data class ServerError(val code: String, val message: String) : Event()
        data class PairingRevoked(val pairingId: String) : Event()
        data class Closed(val reason: String) : Event()
    }

    val opened = CompletableDeferred<Unit>()
    val events = Channel<Event>(Channel.UNLIMITED)
    private val socket: WebSocket = client.newWebSocket(request, this)

    fun relay(to: String, data: ByteArray): Boolean = socket.send(buildJsonObject {
        put("type", "relay"); put("to", to); put("id", ConnectIds.newMessageId()); put("data", Base64Url.encode(data))
    }.toString())

    fun requestPresence() = socket.send("""{"type":"presence"}""")

    fun close() {
        socket.close(1000, null)
        events.close()
    }

    override fun onOpen(webSocket: WebSocket, response: Response) {
        opened.complete(Unit)
    }

    override fun onMessage(webSocket: WebSocket, text: String) {
        if (text.length > 128 * 1024) return
        val o = runCatching { Json.parseToJsonElement(text).jsonObject }.getOrNull() ?: return
        when (o["type"]?.jsonPrimitive?.content) {
            "relay" -> {
                val from = o["from"]?.jsonPrimitive?.content?.takeIf(ConnectIds::isDeviceId) ?: return
                val data = o["data"]?.jsonPrimitive?.content?.let { Base64Url.decode(it) } ?: return
                events.trySend(Event.Relay(from, data))
            }
            "presence" -> events.trySend(Event.Presence(o["peers"]?.jsonArray?.mapNotNull { p ->
                val po = p.jsonObject
                (po["deviceId"]?.jsonPrimitive?.content ?: return@mapNotNull null) to (po["online"]?.jsonPrimitive?.booleanOrNull ?: false)
            }?.toMap() ?: emptyMap()))
            "pairing.revoked" -> events.trySend(Event.PairingRevoked(o["pairingId"]?.jsonPrimitive?.content ?: ""))
            "error" -> events.trySend(Event.ServerError(o["code"]?.jsonPrimitive?.content ?: "error", o["message"]?.jsonPrimitive?.content?.take(200) ?: ""))
        }
    }

    override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
        webSocket.close(1000, null)
        events.trySend(Event.Closed("closed by the server"))
    }

    override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
        opened.completeExceptionally(t)
        events.trySend(Event.Closed(t.message ?: "connection failed"))
    }
}
