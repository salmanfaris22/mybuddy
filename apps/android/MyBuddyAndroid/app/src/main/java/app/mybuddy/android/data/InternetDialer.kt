package app.mybuddy.android.data

import android.content.Context
import app.mybuddy.android.core.Base64Url
import app.mybuddy.android.core.connect.ConnectIds
import app.mybuddy.android.core.connect.IceRoute
import app.mybuddy.android.core.connect.RendezvousMessage
import app.mybuddy.android.core.connect.SessionRoute
import app.mybuddy.android.core.connect.StatsLite
import app.mybuddy.android.core.connect.TurnCredentials
import app.mybuddy.android.core.crypto.DeviceIdentity
import app.mybuddy.android.core.crypto.HandshakeException
import app.mybuddy.android.core.crypto.deviceId
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import org.webrtc.CandidatePairChangeEvent
import org.webrtc.DataChannel
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RtpReceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import java.nio.ByteBuffer
import java.time.Instant
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** STUN/TURN for a peer connection; `relayOnly` forces TURN (a debug-build test switch). */
data class IceSetup(val servers: List<PeerConnection.IceServer>, val relayOnly: Boolean)

/**
 * Reaches the paired Mac over the internet through the user's MyBuddy Connect server (CONNECTIVITY §3):
 * signs in, sends a signed offer for the `mb-session` data channel, verifies the Mac's signed answer
 * against its pinned key, trickles ICE through the server, and returns the open channel as a [Pipe] for the
 * usual MBH1 resume handshake. The server only relays this introduction.
 */
class InternetDialer(private val context: Context, private val scope: CoroutineScope, private val identity: DeviceIdentity) {
    @Volatile var forceRelay = false
    private var factory: PeerConnectionFactory? = null
    @Volatile private var turn: Pair<TurnCredentials, Instant>? = null
    @Volatile private var client: ConnectClient? = null

    fun isSetUp(h: PairedHost) = h.connectUrl != null && h.hostKey != null

    private fun clientFor(url: String): ConnectClient = client?.takeIf { it.server == url } ?: ConnectClient(url, identity).also { client = it }

    /** ICE servers for this Mac's internet sessions (also used for screen video), cached until 80 % of their lifetime. */
    suspend fun iceSetup(h: PairedHost?): IceSetup {
        val url = h?.connectUrl ?: return IceSetup(emptyList(), forceRelay)
        val cached = turn?.takeIf { it.second.isAfter(Instant.now()) }?.first
        val creds = cached ?: runCatching { clientFor(url).turnCredentials() }.getOrNull()?.also {
            turn = it to Instant.now().plusSeconds((it.ttlSeconds * 0.8).toLong())
        }
        val servers = creds?.let { c -> listOf(PeerConnection.IceServer.builder(c.urls).setUsername(c.username).setPassword(c.credential).createIceServer()) }
        return IceSetup(servers ?: emptyList(), forceRelay)
    }

    suspend fun dial(h: PairedHost): RtcPipe {
        val url = h.connectUrl ?: throw HandshakeException("Internet access isn’t set up for this Mac.")
        val hostKey = h.hostKey?.let { Base64Url.decode(it) } ?: throw HandshakeException("Connect once over Wi-Fi so this phone learns your Mac’s key.")
        val connect = clientFor(url)
        val signal = try {
            connect.openSignal()
        } catch (e: ConnectException) {
            throw HandshakeException(if (e.code == "unreachable") "Can’t reach your MyBuddy Connect server (${url.substringAfter("://")})." else e.message ?: e.code)
        }
        var pipe: RtcPipe? = null
        try {
            val setup = iceSetup(h)
            WebRtcRuntime.ensureInitialized(context)
            val f = factory ?: PeerConnectionFactory.builder().createPeerConnectionFactory().also { factory = it }
            val rid = ConnectIds.newRendezvousId()
            val observer = DialObserver(rid, identity.deviceId, h.deviceId, signal)
            val config = PeerConnection.RTCConfiguration(setup.servers).apply {
                sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
                bundlePolicy = PeerConnection.BundlePolicy.MAXBUNDLE
                rtcpMuxPolicy = PeerConnection.RtcpMuxPolicy.REQUIRE
                continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
                keyType = PeerConnection.KeyType.ECDSA
                if (setup.relayOnly) iceTransportsType = PeerConnection.IceTransportsType.RELAY
            }
            val pc = f.createPeerConnection(config, observer) ?: throw HandshakeException("Couldn’t create the internet connection.")
            val channel = pc.createDataChannel(RtcPipe.LABEL, DataChannel.Init().apply { ordered = true })
            val p = RtcPipe(scope, pc, channel, signal, relayOnly = setup.relayOnly)
            pipe = p
            val offer = pc.createOfferDescription()
            pc.setLocal(offer)
            signal.relay(h.deviceId, RendezvousMessage.signed(RendezvousMessage.OFFER, rid, identity, h.deviceId, offer.description).encode())

            // The Mac's answer must be signed by its pinned key; its candidates trickle in through the server.
            val answered = CompletableDeferred<Unit>()
            val pendingIce = ArrayList<RendezvousMessage>()
            var remoteSet = false
            p.signalJob = scope.launch {
                for (event in signal.events) {
                    when (event) {
                        is ConnectSignal.Event.Relay -> {
                            val m = RendezvousMessage.decode(event.data) ?: continue
                            if (m.rid != rid || m.from != h.deviceId || event.from != h.deviceId) continue
                            when (m.kind) {
                                RendezvousMessage.ANSWER -> if (!answered.isCompleted && m.verify(hostKey, identity.deviceId)) {
                                    runCatching { pc.setRemote(SessionDescription(SessionDescription.Type.ANSWER, m.sdp)) }
                                        .onSuccess {
                                            remoteSet = true
                                            pendingIce.forEach { c -> pc.addIceCandidate(IceCandidate(c.sdpMid, c.sdpMLineIndex ?: 0, c.candidate)) }
                                            pendingIce.clear()
                                            answered.complete(Unit)
                                        }
                                        .onFailure { answered.completeExceptionally(HandshakeException("Your Mac’s answer was rejected.")) }
                                }
                                RendezvousMessage.ICE -> if (!m.candidate.isNullOrEmpty()) {
                                    if (remoteSet) pc.addIceCandidate(IceCandidate(m.sdpMid, m.sdpMLineIndex ?: 0, m.candidate))
                                    else if (pendingIce.size < 64) pendingIce += m
                                }
                                RendezvousMessage.BYE -> answered.completeExceptionally(HandshakeException("Your Mac declined the connection."))
                            }
                        }
                        is ConnectSignal.Event.ServerError -> when (event.code) {
                            "peer_offline" -> answered.completeExceptionally(HandshakeException("Your Mac isn’t online. Open MyBuddy on the Mac and turn on internet access."))
                            "not_paired" -> answered.completeExceptionally(HandshakeException("Internet access for this phone was removed. Turn it on again from your Mac."))
                            "token_expired" -> connect.dropToken()
                        }
                        is ConnectSignal.Event.PairingRevoked -> p.close()
                        is ConnectSignal.Event.Closed -> if (!answered.isCompleted) answered.completeExceptionally(HandshakeException("Lost the connection to the server."))
                        is ConnectSignal.Event.Presence -> {}
                    }
                }
            }
            withTimeoutOrNull(15_000) { answered.await() } ?: throw HandshakeException("No answer from your Mac through the server.")
            if (withTimeoutOrNull(20_000) { p.opened.await() } == null) {
                throw HandshakeException(if (setup.servers.isEmpty()) "Couldn’t open a path to your Mac (the server has no TURN relay)." else "Couldn’t open a path to your Mac.")
            }
            p.watchRoute()
            return p
        } catch (e: Exception) {
            pipe?.close() ?: signal.close()
            throw if (e is HandshakeException) e else HandshakeException(e.message ?: "Internet connection failed")
        }
    }

    /** Sends our ICE candidates to the Mac as they are gathered. */
    private class DialObserver(private val rid: String, private val self: String, private val peer: String, private val signal: ConnectSignal) : PeerConnection.Observer {
        override fun onIceCandidate(candidate: IceCandidate) {
            signal.relay(peer, RendezvousMessage(kind = RendezvousMessage.ICE, rid = rid, from = self, to = peer, candidate = candidate.sdp,
                sdpMid = candidate.sdpMid, sdpMLineIndex = candidate.sdpMLineIndex).encode())
        }
        override fun onSignalingChange(state: PeerConnection.SignalingState) {}
        override fun onIceConnectionChange(state: PeerConnection.IceConnectionState) {}
        override fun onIceConnectionReceivingChange(receiving: Boolean) {}
        override fun onIceGatheringChange(state: PeerConnection.IceGatheringState) {}
        override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>) {}
        override fun onSelectedCandidatePairChanged(event: CandidatePairChangeEvent) {}
        override fun onAddStream(stream: MediaStream) {}
        override fun onRemoveStream(stream: MediaStream) {}
        override fun onDataChannel(channel: DataChannel) = channel.close() // only our own channel is used
        override fun onRenegotiationNeeded() {}
        override fun onAddTrack(receiver: RtpReceiver, streams: Array<out MediaStream>) {}
    }
}

/** MBH1 over the `mb-session` data channel (reliable, ordered; text = handshake, binary = frames). */
class RtcPipe(
    private val scope: CoroutineScope,
    private val pc: PeerConnection,
    private val channel: DataChannel,
    private val signal: ConnectSignal,
    /** A relay-only connection is relayed whatever the candidate types say. */
    private val relayOnly: Boolean = false,
) : Pipe() {
    val opened = CompletableDeferred<Unit>()
    private val _route = MutableStateFlow(if (relayOnly) SessionRoute.INTERNET_RELAYED else SessionRoute.INTERNET_DIRECT)
    val route: StateFlow<SessionRoute> = _route
    var signalJob: Job? = null
    private var routeJob: Job? = null
    @Volatile private var closed = false

    init {
        channel.registerObserver(object : DataChannel.Observer {
            override fun onBufferedAmountChange(previousAmount: Long) {}
            override fun onStateChange() {
                when (channel.state()) {
                    DataChannel.State.OPEN -> opened.complete(Unit)
                    DataChannel.State.CLOSED, DataChannel.State.CLOSING -> inbox.trySend(Msg.Closed("internet connection closed"))
                    else -> {}
                }
            }
            override fun onMessage(buffer: DataChannel.Buffer) {
                val bytes = ByteArray(buffer.data.remaining()).also { buffer.data.get(it) }
                inbox.trySend(if (buffer.binary) Msg.Binary(bytes) else Msg.Text(bytes.toString(Charsets.UTF_8)))
            }
        })
    }

    override fun sendText(text: String) = !closed && channel.send(DataChannel.Buffer(ByteBuffer.wrap(text.toByteArray(Charsets.UTF_8)), false))
    override fun sendBinary(bytes: ByteArray) = !closed && channel.send(DataChannel.Buffer(ByteBuffer.wrap(bytes), true))

    /** Reads the selected candidate pair every few seconds: TURN on either end means "relayed". */
    fun watchRoute() {
        routeJob = scope.launch {
            while (isActive && !closed) {
                val entries = pc.statsReport().statsMap.values.map { StatsLite(it.id, it.type, it.members) }
                IceRoute.isRelayed(entries)?.let { _route.value = if (it || relayOnly) SessionRoute.INTERNET_RELAYED else SessionRoute.INTERNET_DIRECT }
                delay(4_000)
            }
        }
    }

    override fun close() {
        if (closed) return
        closed = true
        routeJob?.cancel()
        signalJob?.cancel()
        runCatching { channel.unregisterObserver(); channel.close(); channel.dispose() }
        runCatching { pc.close(); pc.dispose() }
        signal.close()
        inbox.trySend(Msg.Closed("closed"))
    }

    companion object {
        const val LABEL = "mb-session"
    }
}

private suspend fun PeerConnection.createOfferDescription(): SessionDescription = suspendCancellableCoroutine { c ->
    createOffer(object : SdpObserver {
        override fun onCreateSuccess(d: SessionDescription) = c.resume(d)
        override fun onCreateFailure(error: String?) = c.resumeWithException(IllegalStateException("offer failed: $error"))
        override fun onSetSuccess() {}
        override fun onSetFailure(error: String?) {}
    }, MediaConstraints())
}
