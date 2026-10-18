package app.mybuddy.android.data

import android.content.Context
import android.net.wifi.WifiManager
import android.util.Log
import app.mybuddy.android.core.protocol.Envelope
import app.mybuddy.android.core.protocol.EnvelopeCodec
import app.mybuddy.android.core.protocol.ProtocolRole
import app.mybuddy.android.core.protocol.EventType
import app.mybuddy.android.core.stream.CandidateBuffer
import app.mybuddy.android.core.stream.HostStreamState
import app.mybuddy.android.core.stream.InboundStatsParser
import app.mybuddy.android.core.stream.ScreenEvents
import app.mybuddy.android.core.stream.StatsEntry
import app.mybuddy.android.core.stream.StreamPhase
import app.mybuddy.android.core.stream.StreamText
import app.mybuddy.android.core.stream.StreamUi
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.webrtc.CandidatePairChangeEvent
import org.webrtc.DataChannel
import org.webrtc.DefaultVideoDecoderFactory
import org.webrtc.EglBase
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RTCStatsReport
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.VideoFrame
import org.webrtc.VideoSink
import org.webrtc.VideoTrack
import java.nio.ByteBuffer
import java.time.Instant
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Receives the Mac's screen over WebRTC. The Mac is the offerer (it owns the media); this side answers.
 * Signaling (`webrtc.offer/answer/ice`) travels inside the MBH1 session, so the DTLS fingerprints — and
 * with them the media keys — are bound to the paired, authenticated Mac. Receive-only: this phone never
 * sends audio or video.
 *
 * All peer-connection work runs strictly in order on one thread ([jobs]); WebRTC's callbacks post into it.
 */
class ScreenReceiver(private val context: Context, private val scope: CoroutineScope, private val link: MacLink) {
    private val rtcDispatcher = Executors.newSingleThreadExecutor { r -> Thread(r, "mybuddy-rtc") }.asCoroutineDispatcher()
    private val jobs = Channel<suspend () -> Unit>(Channel.UNLIMITED)

    private val _state = MutableStateFlow(StreamUi())
    val state: StateFlow<StreamUi> = _state
    private val _track = MutableStateFlow<VideoTrack?>(null)
    /** The remote video track (null unless a stream exists). */
    val track: StateFlow<VideoTrack?> = _track

    /** STUN/TURN for internet sessions (null on Wi-Fi/Tailscale, where host candidates suffice). */
    var iceSetup: (suspend () -> IceSetup?)? = null

    /** Shared GL context for decoding and rendering (created on first use). */
    val eglBase: EglBase by lazy { EglBase.create() }
    private var factory: PeerConnectionFactory? = null
    private var pc: PeerConnection? = null
    private var generation = 0
    private val candidates = CandidateBuffer()
    private var parser = InboundStatsParser()
    private var statsJob: Job? = null
    private var lostJob: Job? = null
    private var watchdogJob: Job? = null
    /** The last request (quality, display), for the one automatic retry when no picture arrives. */
    private var lastRequest: Pair<String, String?>? = null
    private var autoRetried = false
    /** Keeps the phone's Wi-Fi out of power save while a stream exists (first pings took 0.6–1.6 s without it). */
    private val wifiLock: WifiManager.WifiLock? by lazy {
        (context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager)
            ?.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "MyBuddy:screen")?.apply { setReferenceCounted(false) }
    }
    private val framesRendered = AtomicLong()
    private val frameCounter = VideoSink { framesRendered.incrementAndGet() }

    /** Input channels the Mac opened on the video connection (null when not streaming). */
    @Volatile private var pointerChannel: DataChannel? = null
    @Volatile private var reliableChannel: DataChannel? = null
    private val pointerSequence = AtomicLong()
    private val reliableSequence = AtomicLong()
    private val _inputOverWebRtc = MutableStateFlow(false)
    /** True while input can go over the low-latency WebRTC channels instead of the control channel. */
    val inputOverWebRtc: StateFlow<Boolean> = _inputOverWebRtc

    /**
     * Sends an `input.*` event over the matching WebRTC data channel: pointer moves and scrolling over the
     * unordered/lossy `mb-input`, clicks, keys and text over the reliable `mb-input-rel`. Returns false when
     * no open channel exists — the caller then uses the encrypted control channel.
     */
    fun sendInput(type: EventType, payload: JsonObject): Boolean {
        val lossy = type == EventType.INPUT_POINTER || type == EventType.INPUT_SCROLL
        val channel = (if (lossy) pointerChannel else reliableChannel)?.takeIf { it.state() == DataChannel.State.OPEN } ?: return false
        val sessionId = link.sessionId ?: return false
        val sequence = (if (lossy) pointerSequence else reliableSequence).incrementAndGet()
        val bytes = try {
            EnvelopeCodec.encode(Envelope(type, sessionId, sequence, Instant.now(), null, payload), ProtocolRole.MAC)
        } catch (e: Exception) {
            return false
        }
        return channel.send(DataChannel.Buffer(ByteBuffer.wrap(bytes), false))
    }

    init {
        scope.launch(rtcDispatcher) {
            for (job in jobs) {
                try {
                    job()
                } catch (e: Exception) {
                    teardown()
                    _state.value = _state.value.copy(phase = StreamPhase.Failed, message = "Video error: ${e.message ?: e.javaClass.simpleName}")
                }
            }
        }
    }

    private fun enqueue(job: suspend () -> Unit) {
        jobs.trySend(job)
    }

    // region Commands from the UI

    fun start(quality: String = "auto", displayId: String? = null) = enqueue {
        autoRetried = false
        begin(quality, displayId)
    }

    private suspend fun begin(quality: String, displayId: String?, retrying: Boolean = false) {
        teardown()
        lastRequest = quality to displayId
        runCatching { wifiLock?.acquire() }
        _state.value = StreamUi(StreamPhase.Requesting, if (retrying) "No picture yet — trying once more…" else null, quality = quality)
        Log.i(TAG, "start (quality $quality${if (retrying) ", automatic retry" else ""})")
        val reply = try {
            link.request(EventType.SCREEN_START, buildJsonObject {
                put("quality", quality)
                if (displayId != null) put("displayId", displayId)
            }, timeoutMs = 15_000)
        } catch (e: Exception) {
            _state.value = StreamUi(StreamPhase.Failed, "Your Mac didn’t answer.", quality = quality)
            releaseWifi()
            return
        }
        // A `screen.state` reply also arrives through [handle]; only errors need handling here.
        if (reply.type == EventType.ERROR) {
            val code = reply.payload["code"]?.jsonPrimitive?.content
            val message = reply.payload["message"]?.jsonPrimitive?.content
            _state.value = when (code) {
                "not_permitted" -> StreamUi(StreamPhase.NotAuthorized, message ?: "Viewing the screen is off for this phone.", quality = quality)
                "unknown_type", "unsupported" -> StreamUi(StreamPhase.Failed, "Update MyBuddy on your Mac to view its screen.", quality = quality)
                else -> StreamUi(StreamPhase.Failed, message ?: "Your Mac refused to share its screen.", quality = quality)
            }
            releaseWifi()
        }
    }

    fun stop(reason: String = "user") = enqueue {
        if (!_state.value.isActive) return@enqueue
        link.send(EventType.SCREEN_STOP, buildJsonObject { put("reason", reason) })
        teardown()
        releaseWifi()
        _state.value = StreamUi(StreamPhase.Stopped, if (reason == "background") "Paused while MyBuddy is in the background." else null, quality = _state.value.quality)
    }

    fun setQuality(quality: String) = enqueue {
        if (_state.value.phase != StreamPhase.Live) return@enqueue
        link.send(EventType.SCREEN_UPDATE, buildJsonObject { put("quality", quality) })
        _state.value = _state.value.copy(quality = quality)
    }

    fun selectDisplay(displayId: String) = enqueue {
        if (_state.value.phase != StreamPhase.Live) return@enqueue
        link.send(EventType.SCREEN_UPDATE, buildJsonObject { put("displayId", displayId) })
    }

    /** The MBH1 session ended: the stream is gone with it. */
    fun sessionEnded() = enqueue {
        if (!_state.value.isActive) return@enqueue
        teardown()
        releaseWifi()
        _state.value = StreamUi(StreamPhase.Stopped, "Disconnected from your Mac.", quality = _state.value.quality)
    }

    fun dispose() {
        enqueue {
            teardown()
            releaseWifi()
            factory?.dispose()
            factory = null
        }
        jobs.close()
    }

    // endregion

    /** `webrtc.offer`, `webrtc.ice` and `screen.state` from the Mac. */
    fun handle(e: Envelope) = enqueue {
        when (e.type) {
            EventType.WEBRTC_OFFER -> onOffer(e.payload["sdp"]?.jsonPrimitive?.content ?: return@enqueue)
            EventType.WEBRTC_ICE -> {
                val c = ScreenEvents.parseCandidate(e.payload) ?: return@enqueue
                if (candidates.offer(c)) pc?.addIceCandidate(IceCandidate(c.sdpMid, c.sdpMLineIndex, c.sdp))
            }
            EventType.SCREEN_STATE -> onHostState(HostStreamState.parse(e.payload))
            else -> {}
        }
    }

    private suspend fun onOffer(sdp: String) {
        if (!_state.value.isActive) return // an offer we never asked for (or after Stop) is ignored
        val peer = pc ?: createPeerConnection(iceSetup?.invoke()) ?: run {
            _state.value = _state.value.copy(phase = StreamPhase.Failed, message = "Couldn’t create the video connection.")
            return
        }
        // Candidates that arrived before this offer (the Mac gathers while it sends it) wait — they're not dropped.
        candidates.hold()
        peer.setRemote(SessionDescription(SessionDescription.Type.OFFER, sdp))
        if (_track.value == null) {
            val remote = peer.transceivers.firstNotNullOfOrNull { it.receiver.track() as? VideoTrack }
            remote?.addSink(frameCounter)
            _track.value = remote
        }
        val answer = peer.createAnswerDescription()
        peer.setLocal(answer)
        link.send(EventType.WEBRTC_ANSWER, buildJsonObject { put("sdp", answer.description) })
        val early = candidates.drain(CandidateBuffer.ufragOfSdp(sdp))
        for (c in early) peer.addIceCandidate(IceCandidate(c.sdpMid, c.sdpMLineIndex, c.sdp))
        Log.i(TAG, "answer sent (${early.size} early candidates applied)")
        if (_state.value.phase == StreamPhase.Requesting || _state.value.phase == StreamPhase.Starting) {
            _state.value = _state.value.copy(phase = StreamPhase.Connecting)
        }
    }

    private fun onHostState(h: HostStreamState) {
        val current = _state.value
        when (h.state) {
            "starting" -> if (current.isActive && current.phase != StreamPhase.Live) _state.value = current.copy(phase = StreamPhase.Starting, host = h)
            "awaiting_selection" -> if (current.isActive) _state.value = current.copy(phase = StreamPhase.AwaitingSelection, host = h)
            "live" -> if (current.isActive) {
                if (current.phase != StreamPhase.Live) Log.i(TAG, "live (tier ${h.tier ?: "?"}, ${h.width}×${h.height} @ ${h.fps})")
                lostJob?.cancel()
                _state.value = current.copy(phase = StreamPhase.Live, host = h, quality = h.quality ?: current.quality, message = null)
            }
            "stopped", "failed" -> {
                Log.i(TAG, "${h.state} by the Mac (${h.reason ?: "no reason"})")
                teardown()
                releaseWifi()
                val phase = when {
                    h.reason == "not_authorized" -> StreamPhase.NotAuthorized
                    h.state == "failed" -> StreamPhase.Failed
                    else -> StreamPhase.Stopped
                }
                _state.value = StreamUi(phase, StreamText.reason(h.reason, h.message), host = h, quality = current.quality)
            }
        }
    }

    private fun createPeerConnection(ice: IceSetup?): PeerConnection? {
        val f = factory ?: run {
            WebRtcRuntime.ensureInitialized(context)
            PeerConnectionFactory.builder()
                .setVideoDecoderFactory(DefaultVideoDecoderFactory(eglBase.eglBaseContext))
                .apply { WebRtcRuntime.fieldTrials?.let(::setFieldTrials) }
                .createPeerConnectionFactory()
                .also { factory = it }
        }
        val config = PeerConnection.RTCConfiguration(ice?.servers ?: emptyList()).apply {
            if (ice?.relayOnly == true) iceTransportsType = PeerConnection.IceTransportsType.RELAY
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            bundlePolicy = PeerConnection.BundlePolicy.MAXBUNDLE
            rtcpMuxPolicy = PeerConnection.RtcpMuxPolicy.REQUIRE
            continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_ONCE
            keyType = PeerConnection.KeyType.ECDSA
        }
        val gen = ++generation
        val peer = f.createPeerConnection(config, Observer(gen)) ?: return null
        pc = peer
        pointerSequence.set(0)
        reliableSequence.set(0)
        parser = InboundStatsParser()
        framesRendered.set(0)
        startStats(gen)
        startWatchdog(gen)
        return peer
    }

    /**
     * Never sit on "Connecting video…" forever: if no picture arrives within [FIRST_PICTURE_MS] of the offer, start
     * over once (the Mac rebuilds the stream), then fail with a clear message.
     */
    private fun startWatchdog(gen: Int) {
        watchdogJob?.cancel()
        watchdogJob = scope.launch(rtcDispatcher) {
            delay(FIRST_PICTURE_MS)
            enqueue { firstPictureOverdue(gen) }
        }
    }

    private suspend fun firstPictureOverdue(gen: Int) {
        val s = _state.value
        if (gen != generation || framesRendered.get() > 0 || !s.isActive || s.phase == StreamPhase.AwaitingSelection) return
        val (quality, displayId) = lastRequest ?: return
        Log.w(TAG, "no picture ${FIRST_PICTURE_MS / 1000} s after the offer (phase ${s.phase}, network check ${s.ice ?: "not started"}, retried $autoRetried)")
        if (!autoRetried) {
            autoRetried = true
            begin(quality, displayId, retrying = true)
        } else {
            link.send(EventType.SCREEN_STOP, buildJsonObject { put("reason", "error") })
            teardown()
            releaseWifi()
            _state.value = StreamUi(StreamPhase.Failed,
                "The video didn’t connect (network check: ${s.ice ?: "not started"}). Keep both on the same Wi-Fi or Tailscale and try again.",
                quality = quality)
        }
    }

    private fun releaseWifi() {
        runCatching { if (wifiLock?.isHeld == true) wifiLock?.release() }
    }

    private fun startStats(gen: Int) {
        statsJob?.cancel()
        statsJob = scope.launch(rtcDispatcher) {
            while (isActive) {
                delay(1_000)
                val peer = pc ?: return@launch
                if (gen != generation) return@launch
                val report = peer.statsReport()
                if (gen != generation) return@launch
                val entries = report.statsMap.values.map { StatsEntry(it.id, it.type, it.timestampUs, it.members) }
                _state.value = _state.value.copy(stats = parser.sample(entries), framesRendered = framesRendered.get())
            }
        }
    }

    private fun teardown() {
        statsJob?.cancel()
        lostJob?.cancel()
        watchdogJob?.cancel()
        statsJob = null
        lostJob = null
        watchdogJob = null
        _track.value?.removeSink(frameCounter)
        _track.value = null
        listOfNotNull(pointerChannel, reliableChannel).forEach { runCatching { it.unregisterObserver(); it.close(); it.dispose() } }
        pointerChannel = null
        reliableChannel = null
        _inputOverWebRtc.value = false
        generation++
        pc?.let {
            it.close()
            it.dispose()
        }
        pc = null
        candidates.reset()
    }

    /** WebRTC callbacks (signaling thread). Local candidates go out immediately, in order. */
    private inner class Observer(private val gen: Int) : PeerConnection.Observer {
        override fun onIceCandidate(candidate: IceCandidate) {
            link.send(EventType.WEBRTC_ICE, buildJsonObject {
                put("candidate", candidate.sdp)
                candidate.sdpMid?.let { put("sdpMid", it) }
                put("sdpMLineIndex", candidate.sdpMLineIndex)
            })
        }

        override fun onIceGatheringChange(state: PeerConnection.IceGatheringState) {
            if (state == PeerConnection.IceGatheringState.COMPLETE) link.send(EventType.WEBRTC_ICE, buildJsonObject { put("endOfCandidates", true) })
        }

        override fun onConnectionChange(newState: PeerConnection.PeerConnectionState) = enqueue {
            if (gen != generation) return@enqueue
            val s = _state.value
            when (newState) {
                PeerConnection.PeerConnectionState.CONNECTED -> {
                    Log.i(TAG, "video connection up")
                    lostJob?.cancel()
                    if (s.phase == StreamPhase.Reconnecting) _state.value = s.copy(phase = if (s.host?.state == "live") StreamPhase.Live else StreamPhase.Connecting, message = null)
                }
                PeerConnection.PeerConnectionState.DISCONNECTED, PeerConnection.PeerConnectionState.FAILED -> {
                    if (!s.isActive) return@enqueue
                    Log.w(TAG, "video connection ${newState.name.lowercase()} (phase ${s.phase})")
                    _state.value = s.copy(phase = StreamPhase.Reconnecting, message = "Video interrupted — reconnecting…")
                    // The Mac restarts ICE on its own; give up if nothing recovers in time.
                    lostJob?.cancel()
                    lostJob = scope.launch(rtcDispatcher) {
                        delay(25_000)
                        if (gen == generation && _state.value.phase == StreamPhase.Reconnecting) {
                            link.send(EventType.SCREEN_STOP, buildJsonObject { put("reason", "error") })
                            teardown()
                            _state.value = StreamUi(StreamPhase.Failed, StreamText.reason("connection_failed", null), quality = s.quality)
                        }
                    }
                }
                else -> {}
            }
        }

        override fun onSignalingChange(state: PeerConnection.SignalingState) {}
        override fun onIceConnectionChange(state: PeerConnection.IceConnectionState) = enqueue {
            if (gen != generation) return@enqueue
            Log.i(TAG, "network check: ${state.name.lowercase()}")
            _state.value = _state.value.copy(ice = state.name.lowercase())
        }
        override fun onIceConnectionReceivingChange(receiving: Boolean) {}
        override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>) {}
        override fun onSelectedCandidatePairChanged(event: CandidatePairChangeEvent) {}
        override fun onAddStream(stream: MediaStream) {}
        override fun onRemoveStream(stream: MediaStream) {}
        override fun onDataChannel(channel: DataChannel) {
            // Only the Mac's two input channels are accepted; anything else is closed.
            when (channel.label()) {
                "mb-input" -> pointerChannel = channel
                "mb-input-rel" -> reliableChannel = channel
                else -> {
                    channel.close()
                    channel.dispose()
                    return
                }
            }
            channel.registerObserver(object : DataChannel.Observer {
                override fun onStateChange() {
                    _inputOverWebRtc.value = pointerChannel?.state() == DataChannel.State.OPEN && reliableChannel?.state() == DataChannel.State.OPEN
                }
                override fun onBufferedAmountChange(previousAmount: Long) {}
                override fun onMessage(buffer: DataChannel.Buffer) {} // the Mac sends nothing on these channels
            })
            _inputOverWebRtc.value = pointerChannel?.state() == DataChannel.State.OPEN && reliableChannel?.state() == DataChannel.State.OPEN
        }
        override fun onRenegotiationNeeded() {}
    }
}

private const val TAG = "MyBuddyStream"
/** How long after the Mac's offer the first decoded frame may take before the stream is retried once. */
private const val FIRST_PICTURE_MS = 12_000L

/** Loads libwebrtc's native code once per process, on first use (not at app start). */
internal object WebRtcRuntime {
    @Volatile private var initialized = false

    /**
     * Low-latency playout: render each frame as soon as it's decoded instead of holding it in a smoothing buffer
     * (a screen is interactive, not a movie). Read when the video factory is created (first stream); debug builds can
     * turn it off with the launch extra `--ez lowLatency false` to compare.
     */
    @Volatile var lowLatencyPlayout = true

    val fieldTrials: String? get() = if (lowLatencyPlayout) "WebRTC-ForcePlayoutDelay/min_ms:0,max_ms:0/" else null

    @Synchronized
    fun ensureInitialized(context: Context) {
        if (initialized) return
        PeerConnectionFactory.initialize(PeerConnectionFactory.InitializationOptions.builder(context.applicationContext).createInitializationOptions())
        initialized = true
    }
}

internal suspend fun PeerConnection.setRemote(description: SessionDescription) = suspendCancellableCoroutine { c ->
    setRemoteDescription(object : SdpObserver {
        override fun onSetSuccess() = c.resume(Unit)
        override fun onSetFailure(error: String?) = c.resumeWithException(IllegalStateException("remote description rejected: $error"))
        override fun onCreateSuccess(d: SessionDescription?) {}
        override fun onCreateFailure(error: String?) {}
    }, description)
}

internal suspend fun PeerConnection.setLocal(description: SessionDescription) = suspendCancellableCoroutine { c ->
    setLocalDescription(object : SdpObserver {
        override fun onSetSuccess() = c.resume(Unit)
        override fun onSetFailure(error: String?) = c.resumeWithException(IllegalStateException("local description rejected: $error"))
        override fun onCreateSuccess(d: SessionDescription?) {}
        override fun onCreateFailure(error: String?) {}
    }, description)
}

internal suspend fun PeerConnection.createAnswerDescription(): SessionDescription = suspendCancellableCoroutine { c ->
    createAnswer(object : SdpObserver {
        override fun onCreateSuccess(d: SessionDescription) = c.resume(d)
        override fun onCreateFailure(error: String?) = c.resumeWithException(IllegalStateException("answer failed: $error"))
        override fun onSetSuccess() {}
        override fun onSetFailure(error: String?) {}
    }, MediaConstraints())
}

internal suspend fun PeerConnection.statsReport(): RTCStatsReport = suspendCancellableCoroutine { c -> getStats { report -> c.resume(report) } }
