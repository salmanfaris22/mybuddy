package app.mybuddy.android.data

import app.mybuddy.android.core.Base64Url
import app.mybuddy.android.core.connect.SessionRoute
import app.mybuddy.android.core.crypto.DeviceIdentity
import app.mybuddy.android.core.crypto.FrameException
import app.mybuddy.android.core.crypto.HandshakeException
import app.mybuddy.android.core.crypto.Mbh1Client
import app.mybuddy.android.core.crypto.Mbh1Mode
import app.mybuddy.android.core.crypto.SecureSession
import app.mybuddy.android.core.protocol.Envelope
import app.mybuddy.android.core.protocol.EventType
import app.mybuddy.android.core.protocol.ProtocolException
import app.mybuddy.android.core.session.Backoff
import app.mybuddy.android.core.session.ConnectionState
import app.mybuddy.android.core.session.Discovery
import app.mybuddy.android.core.session.PairingInvitation
import app.mybuddy.android.core.session.Tailnet
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.util.concurrent.ConcurrentHashMap
import java.net.Inet6Address
import java.net.InetAddress
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/** What the Mac granted for this session (shown in the UI; enforced on the Mac). */
data class SessionInfo(
    val granted: Set<String>,
    val sharedFolders: List<Pair<String, String>>,
    val hostName: String,
    /** Optional event groups the Mac implements (`session.approved.features`), e.g. `screen`. */
    val features: Set<String> = emptySet(),
    /** Folders the Mac lets this phone run coding agents in (id → name; only with "Coding agents"). */
    val agentWorkspaces: List<Pair<String, String>> = emptyList(),
    /** Coding agents on the Mac (`claude_code`, `codex`) → ready (installed and signed in). */
    val agents: Map<String, Boolean> = emptyMap(),
)

sealed class PairOutcome {
    data class Paired(val host: PairedHost) : PairOutcome()
    data class Rejected(val reason: String) : PairOutcome()
    data class Failed(val message: String) : PairOutcome()
}

/**
 * A reliable, ordered, message-preserving channel to the Mac carrying MBH1 (text = handshake, binary = frames):
 * a LAN/Tailscale WebSocket ([WsPipe]) or, through MyBuddy Connect, a WebRTC data channel ([RtcPipe]).
 */
abstract class Pipe {
    sealed class Msg {
        data class Text(val text: String) : Msg()
        data class Binary(val bytes: ByteArray) : Msg()
        data class Closed(val reason: String) : Msg()
    }

    val inbox = Channel<Msg>(Channel.UNLIMITED)
    abstract fun sendText(text: String): Boolean
    abstract fun sendBinary(bytes: ByteArray): Boolean
    abstract fun close()

    suspend fun text(timeoutMs: Long): String = withTimeout(timeoutMs) {
        when (val m = inbox.receive()) {
            is Msg.Text -> m.text
            is Msg.Binary -> throw HandshakeException("unexpected binary during handshake")
            is Msg.Closed -> throw HandshakeException(m.reason)
        }
    }
}

/** WebSocket messages as a suspendable queue. */
private class WsPipe(client: OkHttpClient, url: String) : Pipe() {
    val opened = CompletableDeferred<Unit>()
    val socket: WebSocket = client.newWebSocket(Request.Builder().url(url).build(), object : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            opened.complete(Unit)
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            inbox.trySend(Msg.Text(text))
        }

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
            inbox.trySend(Msg.Binary(bytes.toByteArray()))
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(1000, null)
            inbox.trySend(Msg.Closed("closed by Mac"))
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            opened.completeExceptionally(t)
            inbox.trySend(Msg.Closed(t.message ?: "connection failed"))
        }
    })

    override fun sendText(text: String) = socket.send(text)
    override fun sendBinary(bytes: ByteArray) = socket.send(bytes.toByteString())
    override fun close() {
        socket.close(1000, null)
    }
}

/**
 * The phone's link to its Mac: MBH1 over a LAN WebSocket. All decisions (permissions, approvals)
 * are made on the Mac; this class only carries authenticated, encrypted envelopes.
 */
class MacLink(private val scope: CoroutineScope, private val identity: DeviceIdentity, private val deviceName: String, private val appVersion: String) {
    private val client = OkHttpClient.Builder()
        .connectTimeout(4, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.SECONDS)
        .pingInterval(20, TimeUnit.SECONDS)
        .build()

    private val _state = MutableStateFlow<ConnectionState>(ConnectionState.Offline)
    val state: StateFlow<ConnectionState> = _state
    private val _session = MutableStateFlow<SessionInfo?>(null)
    val session: StateFlow<SessionInfo?> = _session
    private val _rtt = MutableStateFlow<Long?>(null)
    val rttMs: StateFlow<Long?> = _rtt
    private val _address = MutableStateFlow<String?>(null)
    /** The address the current session uses (a Wi-Fi address or a Tailscale one; "internet" through MyBuddy Connect). */
    val connectedAddress: StateFlow<String?> = _address
    private val _route = MutableStateFlow<SessionRoute?>(null)
    /** How the current session reaches the Mac (null when not connected). */
    val route: StateFlow<SessionRoute?> = _route
    private var routeJob: Job? = null

    /** Reaches the Mac through MyBuddy Connect when Wi-Fi and Tailscale don't answer (set up per paired Mac). */
    var internet: InternetDialer? = null
    private val _events = MutableSharedFlow<Envelope>(extraBufferCapacity = 256)
    val events: SharedFlow<Envelope> = _events

    private var pipe: Pipe? = null
    private var secure: SecureSession? = null
    /** The current MBH1 session id (envelopes on the WebRTC input channels must carry it). */
    val sessionId: String? get() = secure?.sessionId
    private var reader: Job? = null
    private var heartbeat: Job? = null
    private val pending = ConcurrentHashMap<Long, CompletableDeferred<Envelope>>()
    private val probes = ConcurrentHashMap<String, Long>()
    private var lastFrameAt = System.currentTimeMillis()
    private var host: PairedHost? = null
    private var userClosed = false
    private val backoff = Backoff()
    private var reconnectJob: Job? = null

    /**
     * Set while MyBuddy is in the background with nothing that needs the link (no transfer moving): a dropped
     * link then waits ([ConnectionState.Suspended]) until the app returns instead of retrying — Android freezes
     * background apps, so retries there only produce connect/disconnect churn on both devices.
     */
    @Volatile var holdReconnects = false

    /** Finds the paired Mac on the current network (Bonjour), used when its stored addresses don't answer. */
    var discover: (suspend (PairedHost) -> List<String>)? = null

    /** Called when the Mac was reached at a new address, so it can be remembered. */
    var onHostUpdated: ((PairedHost) -> Unit)? = null

    companion object {
        /** `connectedAddress` while the session runs through MyBuddy Connect. */
        const val INTERNET = "internet"
    }

    val requestedCapabilities = listOf("screen.view", "input.control", "apps.launch", "files.browse", "files.transfer",
        "clipboard.sync", "notifications.mirror", "voice.commands", "ai.chat", "ai.agent", "health.read", "notes.sync")

    /**
     * Dials the candidates as a staggered race — Wi-Fi addresses first, each next one 600 ms later, Tailscale
     * addresses last — and keeps the first that answers: at home Wi-Fi wins without extra connections, away
     * from home the phone doesn't sit through several Wi-Fi timeouts before trying Tailscale. Only
     * local-network and tailnet addresses are dialled (defense in depth: they came from a validated invitation,
     * discovery match or Tailscale entry).
     */
    private suspend fun open(addresses: List<String>): Pair<WsPipe, String> = coroutineScope {
        val candidates = addresses.filter { PairingInvitation.isValidHostPort(it) || Tailnet.isUserHostPort(it) }
            .distinct().sortedBy { if (Tailnet.route(it) == Tailnet.Route.Tailscale) 1 else 0 }
        if (candidates.isEmpty()) throw HandshakeException("No address is known for your Mac. Pair again.")
        val winner = CompletableDeferred<Pair<WsPipe, String>>()
        val failures = AtomicInteger()
        val lastError = AtomicReference<String?>(null)
        fun failed(why: String?) {
            lastError.set(why)
            if (failures.incrementAndGet() == candidates.size) {
                val tailscaleOnly = candidates.all { Tailnet.route(it) == Tailnet.Route.Tailscale }
                winner.completeExceptionally(HandshakeException(
                    if (tailscaleOnly) "Can’t reach your Mac over Tailscale (${lastError.get() ?: "no answer"}). Check that Tailscale is on, on both devices."
                    else "Can’t reach your Mac (${lastError.get() ?: "no answer"}). Make sure both devices are on the same Wi-Fi, or turn on Tailscale on both."))
            }
        }
        val attempts = candidates.mapIndexed { i, address ->
            launch {
                delay(i * 600L)
                if (winner.isCompleted) return@launch
                val target = dialTarget(address) ?: return@launch failed("$address doesn’t point into your tailnet")
                val p = WsPipe(client, "ws://$target")
                try {
                    val opened = withTimeoutOrNull(5_000) { p.opened.await() } != null
                    if (opened && winner.complete(p to address)) return@launch
                    p.socket.cancel()
                    if (!opened) failed("timed out")
                } catch (e: CancellationException) {
                    p.socket.cancel()
                    throw e
                } catch (t: Throwable) {
                    p.socket.cancel()
                    failed(t.message)
                }
            }
        }
        try {
            winner.await()
        } finally {
            attempts.forEach { it.cancel() }
        }
    }

    /**
     * What to actually dial. MagicDNS names are resolved here and only addresses inside the tailnet ranges are
     * used (a `ts.net` name pointing at a public IP, e.g. a Funnel endpoint, is refused); the IP is dialled,
     * not the name, so it can't be re-resolved elsewhere.
     */
    private suspend fun dialTarget(address: String): String? {
        val host = Tailnet.hostOf(address) ?: return null
        if (!Tailnet.isMagicDnsName(host)) return address
        val port = address.substringAfterLast(':')
        val resolved = runCatching { withContext(Dispatchers.IO) { InetAddress.getAllByName(host).toList() } }.getOrNull() ?: return null
        val inTailnet = resolved.mapNotNull { it.hostAddress }.filter { Tailnet.isTailnetAddress(it) }
        if (inTailnet.isEmpty() || inTailnet.size != resolved.size) return null
        val pick = resolved.firstOrNull { it !is Inet6Address } ?: resolved.first()
        val ip = pick.hostAddress?.substringBefore('%') ?: return null
        return if (pick is Inet6Address) "[$ip]:$port" else "$ip:$port"
    }

    /**
     * Tries the remembered addresses first (no added delay when they work) while Bonjour discovery runs in
     * parallel; if they all fail — e.g. the Mac got a new IP from the router — tries what discovery found.
     */
    private suspend fun openPaired(h: PairedHost): Pair<WsPipe, String> = coroutineScope {
        val finder = discover?.let { find -> async { runCatching { find(h) }.getOrDefault(emptyList()) } }
        try {
            open(h.addresses)
        } catch (e: HandshakeException) {
            val found = finder?.await().orEmpty().filter { it !in h.addresses }
            if (found.isEmpty()) throw e
            open(found)
        } finally {
            finder?.cancel()
        }
    }

    /** Pair using the QR invitation. Suspends while the user approves on the Mac. */
    suspend fun pair(invitation: PairingInvitation): PairOutcome {
        disconnect(silent = true)
        userClosed = false
        _state.value = ConnectionState.Pairing
        return try {
            val (p, address) = open(invitation.addresses)
            pipe = p
            _address.value = address
            val c = Mbh1Client.create(Mbh1Mode.PAIR, identity, deviceName, "android", invitation.hostFingerprint, invitation.secret)
            p.sendText(c.makeHello())
            val (reply, result) = c.handleHost(p.text(10_000))
            p.sendText(reply)
            val s = SecureSession(result.keys)
            secure = s
            _state.value = ConnectionState.AwaitingApproval(result.keys.sas)
            sendRaw(EventType.PAIRING_REQUEST, buildJsonObject { put("deviceName", deviceName); put("platform", "android"); put("appVersion", appVersion) })
            val answer = withTimeout(130_000) { nextEnvelope(p) }
            when (answer.type) {
                EventType.PAIRING_APPROVED -> {
                    val hostName = answer.payload["hostName"]?.jsonPrimitive?.content ?: invitation.displayName
                    val paired = PairedHost(result.hostDeviceId, invitation.hostFingerprint, hostName, invitation.addresses, System.currentTimeMillis() / 1000,
                        hostKey = Base64Url.encode(result.hostIdentityKey))
                    host = paired
                    requestSession(p, hostName, Tailnet.route(address).toSessionRoute())
                    PairOutcome.Paired(paired)
                }
                EventType.PAIRING_REJECTED -> {
                    disconnect(silent = true)
                    _state.value = ConnectionState.Failed("Pairing was declined on the Mac")
                    PairOutcome.Rejected(answer.payload["reason"]?.jsonPrimitive?.content ?: "declined")
                }
                else -> throw HandshakeException("unexpected ${answer.type.wire}")
            }
        } catch (e: Exception) {
            disconnect(silent = true)
            val message = when (e) {
                is HandshakeException -> if (e.reason == "host key mismatch") "This isn’t the Mac that showed the code." else e.reason
                is kotlinx.coroutines.TimeoutCancellationException -> "No answer from the Mac in time."
                else -> e.message ?: "Pairing failed"
            }
            _state.value = ConnectionState.Failed(message)
            PairOutcome.Failed(message)
        }
    }

    /** Reconnect to an already paired Mac (resume mode — the Mac checks it still trusts this phone). */
    suspend fun connect(h: PairedHost) {
        host = h
        userClosed = false
        _state.value = ConnectionState.Connecting
        try {
            val (p, address) = try {
                openPaired(h)
            } catch (e: HandshakeException) {
                // Neither Wi-Fi nor Tailscale answered: try the internet if this Mac set it up (CONNECTIVITY §3).
                val dialer = internet?.takeIf { it.isSetUp(h) } ?: throw e
                dialer.dial(h) to INTERNET
            }
            pipe = p
            _address.value = address
            val c = Mbh1Client.create(Mbh1Mode.RESUME, identity, deviceName, "android", h.fingerprint, null)
            p.sendText(c.makeHello())
            val (reply, result) = c.handleHost(p.text(10_000))
            p.sendText(reply)
            secure = SecureSession(result.keys)
            requestSession(p, h.name, if (p is RtcPipe) p.route.value else Tailnet.route(address).toSessionRoute())
            if (p is RtcPipe) followRoute(p)
            backoff.reset()
            // The handshake proved this is the paired Mac; remember where it answered (and its key, for internet mode).
            val key = Base64Url.encode(result.hostIdentityKey)
            if ((address != INTERNET && h.addresses.firstOrNull() != address) || h.hostKey != key) {
                val updated = h.copy(addresses = if (address == INTERNET) h.addresses else Discovery.remember(address, h.addresses), hostKey = key)
                host = updated
                onHostUpdated?.invoke(updated)
            }
        } catch (e: Exception) {
            disconnect(silent = true)
            val message = when (e) {
                is HandshakeException -> if (e.reason == "host key mismatch") "The Mac’s identity changed — pair again." else e.reason
                else -> e.message ?: "Couldn’t connect"
            }
            scheduleReconnect(message)
        }
    }

    /** Internet sessions can move between a direct path and a TURN relay; the state follows. */
    private fun followRoute(p: RtcPipe) {
        routeJob?.cancel()
        routeJob = scope.launch {
            p.route.collect { r ->
                if (pipe !== p || secure == null) return@collect
                _route.value = r
                if (_state.value.isConnected) _state.value = if (r == SessionRoute.INTERNET_RELAYED) ConnectionState.RelayedConnected else ConnectionState.DirectConnected
            }
        }
    }

    /** The paired Mac this link talks to (set as soon as pairing succeeds, before the app has stored it). */
    val hostDeviceId: String? get() = host?.deviceId

    /** Lets the paired host record learn new fields (e.g. internet enrolment) without a reconnect. */
    fun updateHost(h: PairedHost) {
        if (host?.deviceId == h.deviceId) host = h
    }

    private suspend fun requestSession(p: Pipe, hostName: String, route: SessionRoute) {
        sendRaw(EventType.SESSION_REQUEST, buildJsonObject {
            put("requestedCapabilities", buildJsonArray { requestedCapabilities.forEach { add(JsonPrimitive(it)) } })
            put("protocolVersions", buildJsonArray { add(JsonPrimitive(1)) })
            put("features", buildJsonArray { add(JsonPrimitive("screen")) })
        })
        val answer = withTimeout(10_000) { nextEnvelope(p) }
        if (answer.type != EventType.SESSION_APPROVED) {
            val reason = answer.payload["reason"]?.jsonPrimitive?.content ?: "not_trusted"
            disconnect(silent = true)
            userClosed = true
            _state.value = ConnectionState.Failed(if (reason == "not_trusted" || reason == "revoked") "Your Mac no longer trusts this phone. Pair again." else reason)
            return
        }
        val granted = (answer.payload["grantedCapabilities"] as? JsonArray)?.map { it.jsonPrimitive.content }?.toSet() ?: emptySet()
        val folders = (answer.payload["sharedFolders"] as? JsonArray)?.mapNotNull {
            val o = it.jsonObject
            (o["rootId"]?.jsonPrimitive?.content ?: return@mapNotNull null) to (o["name"]?.jsonPrimitive?.content ?: "Folder")
        } ?: emptyList()
        val features = (answer.payload["features"] as? JsonArray)?.map { it.jsonPrimitive.content }?.toSet() ?: emptySet()
        val agentWorkspaces = (answer.payload["agentWorkspaces"] as? JsonArray)?.mapNotNull {
            val o = it.jsonObject
            (o["workspaceId"]?.jsonPrimitive?.content ?: return@mapNotNull null) to (o["name"]?.jsonPrimitive?.content ?: "Folder")
        } ?: emptyList()
        val agents = (answer.payload["agents"] as? JsonArray)?.mapNotNull {
            val o = it.jsonObject
            (o["kind"]?.jsonPrimitive?.content ?: return@mapNotNull null) to (o["ready"]?.jsonPrimitive?.content == "true")
        }?.toMap() ?: emptyMap()
        _session.value = SessionInfo(granted, folders, hostName, features, agentWorkspaces, agents)
        _route.value = route
        _state.value = if (route == SessionRoute.INTERNET_RELAYED) ConnectionState.RelayedConnected else ConnectionState.DirectConnected
        lastFrameAt = System.currentTimeMillis()
        startLoops(p)
    }

    private suspend fun nextEnvelope(p: Pipe): Envelope {
        while (true) {
            when (val m = p.inbox.receive()) {
                is Pipe.Msg.Binary -> {
                    val e = secure!!.open(m.bytes)
                    if (e.type == EventType.ERROR) continue
                    return e
                }
                is Pipe.Msg.Text -> throw HandshakeException("unexpected text frame")
                is Pipe.Msg.Closed -> throw HandshakeException(m.reason)
            }
        }
    }

    private fun startLoops(p: Pipe) {
        reader?.cancel()
        heartbeat?.cancel()
        reader = scope.launch {
            try {
                while (isActive) {
                    when (val m = p.inbox.receive()) {
                        is Pipe.Msg.Binary -> {
                            lastFrameAt = System.currentTimeMillis()
                            val e = try {
                                secure?.open(m.bytes) ?: continue
                            } catch (pe: ProtocolException) {
                                continue // invalid message from the Mac: drop it
                            }
                            when (e.type) {
                                EventType.HOST_HEARTBEAT -> {
                                    val probe = e.payload["probe"]?.jsonPrimitive?.content
                                    if (e.payload["reply"]?.jsonPrimitive?.content == "false") {
                                        // The Mac measures its own round trip: answer its probe.
                                        probe?.let { p -> runCatching { sendRaw(EventType.HOST_HEARTBEAT, buildJsonObject { put("probe", p); put("reply", true) }) } }
                                    } else {
                                        probes.remove(probe)?.let { _rtt.value = System.currentTimeMillis() - it }
                                    }
                                }
                                EventType.SESSION_CLOSED -> {
                                    val reason = e.payload["reason"]?.jsonPrimitive?.content ?: "closed"
                                    if (reason == "revoked") userClosed = true
                                    handleDrop(if (reason == "revoked") "Your Mac revoked this phone." else "Session ended on the Mac ($reason)")
                                    return@launch
                                }
                                else -> {}
                            }
                            e.replyTo?.let { pending.remove(it)?.complete(e) }
                            _events.emit(e)
                        }
                        is Pipe.Msg.Closed -> {
                            handleDrop(m.reason)
                            return@launch
                        }
                        is Pipe.Msg.Text -> {}
                    }
                }
            } catch (f: FrameException) {
                handleDrop("Secure channel error")
            }
        }
        heartbeat = scope.launch {
            var n = 0
            while (isActive) {
                delay(5_000)
                val probe = "p${++n}"
                probes[probe] = System.currentTimeMillis()
                runCatching { sendRaw(EventType.HOST_HEARTBEAT, buildJsonObject { put("probe", probe); put("reply", false) }) }
                if (System.currentTimeMillis() - lastFrameAt > 15_000) {
                    handleDrop("No response from the Mac")
                    return@launch
                }
            }
        }
    }

    private fun handleDrop(reason: String) {
        val wasUserClosed = userClosed
        disconnect(silent = true)
        if (wasUserClosed) {
            if (_state.value !is ConnectionState.Failed) _state.value = ConnectionState.Disconnected
        } else {
            scheduleReconnect(reason)
        }
    }

    private fun scheduleReconnect(reason: String) {
        val h = host ?: run {
            _state.value = ConnectionState.Failed(reason)
            return
        }
        if (holdReconnects) {
            _state.value = ConnectionState.Suspended
            return
        }
        val delaySeconds = backoff.nextDelay()
        if (delaySeconds == null || userClosed) {
            _state.value = ConnectionState.Failed(reason)
            return
        }
        _state.value = ConnectionState.Reconnecting(backoff.attempt, delaySeconds)
        reconnectJob?.cancel()
        reconnectJob = scope.launch {
            delay((delaySeconds * 1000).toLong())
            if (!userClosed && _state.value is ConnectionState.Reconnecting) connect(h)
        }
    }

    private fun seal(type: EventType, payload: JsonObject, replyTo: Long? = null): Pair<ByteArray, Long> {
        val s = secure ?: throw IllegalStateException("not connected")
        return s.seal(type, payload, replyTo)
    }

    private fun transmit(frame: ByteArray) {
        val sent = pipe?.sendBinary(frame) ?: false
        if (!sent) throw IllegalStateException("not connected")
    }

    /**
     * Seal + transmit under one lock: frames must reach the Mac in sequence order (it treats a
     * non-increasing sequence as a replay), and WebRTC callbacks send from their own thread.
     */
    private val sendLock = Any()

    private fun sendRaw(type: EventType, payload: JsonObject, replyTo: Long? = null): Long = synchronized(sendLock) {
        val (frame, seq) = seal(type, payload, replyTo)
        transmit(frame)
        seq
    }

    /** Fire-and-forget event (validated locally before sending). */
    fun send(type: EventType, payload: JsonObject): Long? = runCatching { sendRaw(type, payload) }.getOrNull()

    /** Request/response: waits for the Mac's reply (`replyTo` = our sequence). */
    suspend fun request(type: EventType, payload: JsonObject, timeoutMs: Long = 10_000): Envelope {
        val deferred = CompletableDeferred<Envelope>()
        // Register the waiter before transmitting so a fast reply can't be missed.
        val seq = synchronized(sendLock) {
            val (frame, seq) = seal(type, payload)
            pending[seq] = deferred
            try {
                transmit(frame)
            } catch (e: Exception) {
                pending.remove(seq)
                throw e
            }
            seq
        }
        return try {
            withTimeout(timeoutMs) { deferred.await() }
        } finally {
            pending.remove(seq)
        }
    }

    fun disconnect(silent: Boolean = false) {
        if (!silent) {
            userClosed = true
            runCatching { sendRaw(EventType.SESSION_CLOSED, buildJsonObject { put("reason", "user") }) }
        }
        reader?.cancel()
        heartbeat?.cancel()
        reader = null
        heartbeat = null
        routeJob?.cancel()
        routeJob = null
        pipe?.close()
        pipe = null
        secure = null
        _session.value = null
        _rtt.value = null
        _address.value = null
        _route.value = null
        pending.values.forEach { it.cancel() }
        pending.clear()
        if (!silent) _state.value = ConnectionState.Disconnected
    }

    /**
     * Retries now (fresh backoff) if the link dropped and has not been closed on purpose — e.g. attempts made
     * while Android blocked background network access. Revoked/untrusted and user-closed links stay closed.
     */
    fun resumeIfDropped() {
        val h = host ?: return
        if (userClosed || holdReconnects) return
        val s = _state.value
        if (s is ConnectionState.Failed || s is ConnectionState.Reconnecting || s is ConnectionState.Suspended) {
            reconnectJob?.cancel()
            backoff.reset()
            scope.launch { connect(h) }
        }
    }

    private fun Tailnet.Route.toSessionRoute() = if (this == Tailnet.Route.Tailscale) SessionRoute.TAILSCALE else SessionRoute.WIFI

    /** Emergency disconnect: tells the Mac to stop immediately. */
    fun emergencyStop() {
        userClosed = true
        runCatching { sendRaw(EventType.SESSION_CLOSED, buildJsonObject { put("reason", "emergency_stop") }) }
        disconnect(silent = true)
        _state.value = ConnectionState.Disconnected
    }
}
