package app.mybuddy.android

import android.app.Application
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import app.mybuddy.android.core.Base64Url
import app.mybuddy.android.core.connect.ConnectServerUrl
import app.mybuddy.android.core.connect.ConnectStatements
import app.mybuddy.android.core.connect.SessionRoute
import app.mybuddy.android.core.crypto.DeviceIdentity
import app.mybuddy.android.core.crypto.SoftwareIdentity
import app.mybuddy.android.core.crypto.deviceId
import app.mybuddy.android.core.protocol.Envelope
import app.mybuddy.android.core.protocol.EventType
import app.mybuddy.android.core.session.ConnectionState
import app.mybuddy.android.core.session.PairingException
import app.mybuddy.android.core.session.PairingInvitation
import app.mybuddy.android.core.session.Tailnet
import android.net.Uri
import app.mybuddy.android.data.ActivityItem
import app.mybuddy.android.data.ClipboardBridge
import app.mybuddy.android.data.ConnectClient
import app.mybuddy.android.data.ConnectException
import app.mybuddy.android.data.InternetDialer
import app.mybuddy.android.data.NotificationMirror
import app.mybuddy.android.data.TransferKeepAliveService
import app.mybuddy.android.data.NotesSync
import app.mybuddy.android.data.PhoneSettings
import app.mybuddy.android.data.TransferManager
import app.mybuddy.android.data.ActivityKind
import app.mybuddy.android.data.ChatTurn
import app.mybuddy.android.data.DemoData
import app.mybuddy.android.data.FileEntry
import app.mybuddy.android.data.HealthParser
import app.mybuddy.android.data.HealthView
import app.mybuddy.android.data.HostStore
import app.mybuddy.android.data.KeystoreIdentity
import app.mybuddy.android.data.Load
import app.mybuddy.android.data.MacDiscovery
import app.mybuddy.android.data.MacLink
import app.mybuddy.android.data.PairOutcome
import app.mybuddy.android.data.PairedHost
import app.mybuddy.android.data.ScreenReceiver
import app.mybuddy.android.data.TailscaleApp
import app.mybuddy.android.data.TailscaleInfo
import app.mybuddy.android.data.SessionInfo
import app.mybuddy.android.data.VoiceController
import app.mybuddy.android.data.VoiceResult
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.util.Locale
import java.util.UUID

class AppViewModel(app: Application) : AndroidViewModel(app) {
    companion object {
        const val RELAYED_TRANSFERS = "File transfer needs a direct connection — this session goes through a relay server."
    }

    val demo = MutableStateFlow(false)
    val identityBackend: String
    private val identity: DeviceIdentity
    val deviceId: String

    init {
        var backend = "Android Keystore"
        identity = try {
            KeystoreIdentity.loadOrCreate().also { backend = it.backend }
        } catch (e: Exception) {
            // Keystore unavailable (e.g. some emulators): fall back to an in-memory key and say so.
            backend = "Temporary in-memory key (Keystore unavailable)"
            SoftwareIdentity()
        }
        identityBackend = backend
        deviceId = identity.deviceId
    }

    private val hostStore = HostStore(app)
    val link = MacLink(viewModelScope, identity, deviceName = "${Build.MANUFACTURER.replaceFirstChar(Char::uppercase)} ${Build.MODEL}".take(64), appVersion = BuildConfig.VERSION_NAME)

    val pairedHost: StateFlow<PairedHost?> = combine(hostStore.host, demo) { h, d -> if (d) DemoData.host else h }
        .stateIn(viewModelScope, SharingStarted.Eagerly, null)
    val connection: StateFlow<ConnectionState> = combine(link.state, demo) { s, d -> if (d) ConnectionState.DirectConnected else s }
        .stateIn(viewModelScope, SharingStarted.Eagerly, ConnectionState.Offline)
    val session: StateFlow<SessionInfo?> = combine(link.session, demo) { s, d -> if (d) DemoData.session else s }
        .stateIn(viewModelScope, SharingStarted.Eagerly, null)
    val rttMs: StateFlow<Long?> = combine(link.rttMs, demo) { r, d -> if (d) 18L else r }
        .stateIn(viewModelScope, SharingStarted.Eagerly, null)
    /** Which route the current session uses: Wi-Fi, Tailscale or the internet (null when not connected). */
    val route: StateFlow<SessionRoute?> = combine(link.route, demo) { r, d -> if (d) SessionRoute.WIFI else r }
        .stateIn(viewModelScope, SharingStarted.Eagerly, null)

    /** Internet access through MyBuddy Connect — used only when Wi-Fi and Tailscale don't answer. */
    val internet = InternetDialer(app, viewModelScope, identity)
    data class InternetOffer(val serverUrl: String, val createdAt: String)
    /** The Mac offered internet access in this session; the user decides here. */
    val internetOffer = MutableStateFlow<InternetOffer?>(null)
    val internetBusy = MutableStateFlow(false)
    val internetMessage = MutableStateFlow<String?>(null)
    /** Debug builds only: refuse direct candidates to test the TURN relay path. */
    val forceRelay = MutableStateFlow(false)
    val tailscale = MutableStateFlow(TailscaleInfo(installed = false, vpnActive = false))

    val health = MutableStateFlow<Load<HealthView>>(Load.Idle)
    val transcript = MutableStateFlow<List<ChatTurn>>(emptyList())
    val providerLine = MutableStateFlow<String?>(null)
    val chatBusy = MutableStateFlow(false)
    val files = MutableStateFlow<Load<List<FileEntry>>>(Load.Idle)
    val filePath = MutableStateFlow<Pair<String, String>?>(null) // rootId to relative path
    val activity = MutableStateFlow<List<ActivityItem>>(emptyList())
    val lastVoice = MutableStateFlow<VoiceResult?>(null)
    val remoteNotice = MutableStateFlow<String?>(null)
    val pairingError = MutableStateFlow<String?>(null)

    val voice = VoiceController(app) { text -> onTranscript(text) }

    private val discovery = MacDiscovery(app)
    private val connectivity = app.getSystemService(ConnectivityManager::class.java)
    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        // Joining (or rejoining) a network: if the link dropped, try the Mac again right away.
        override fun onAvailable(network: Network) {
            viewModelScope.launch { if (!demo.value) link.resumeIfDropped() }
        }
    }

    /** File transfers with the Mac (both directions) and clipboard sync. */
    val transfers = TransferManager(app, viewModelScope, link)
    /** Phone-side preferences (auto-save files from the Mac, …). */
    val settings = PhoneSettings(app, viewModelScope)
    /** Shared notes, kept on this phone and synced with the Mac. */
    val notes = NotesSync(app, viewModelScope, link)
    val clipboard = ClipboardBridge(app, link, deviceId)

    /** Phone → Mac notification mirroring (off by default) and MyBuddy's alerts from the Mac. */
    val notifications = NotificationMirror(app, viewModelScope, link)

    /** The Mac's screen over WebRTC (receive-only). */
    val screen = ScreenReceiver(app, viewModelScope, link)
    val remoteFullscreen = MutableStateFlow(false)
    /** Set by the Remote screen while it is on screen; viewing only ever happens there. */
    var remoteVisible = false
        set(value) {
            field = value
            if (!value) resumeScreenOnStart = false
        }
    private var resumeScreenOnStart = false
    /** Between onStart and onStop: only then may a foreground service be started. */
    private var inForeground = false

    private var currentRequest: String? = null
    private val _pointer = MutableStateFlow(0.5 to 0.5)
    /** Where MyBuddy last put the Mac pointer (normalized frame coordinates) — drawn over the picture. */
    val pointer: StateFlow<Pair<Double, Double>> = _pointer
    private var cursor: Pair<Double, Double>
        get() = _pointer.value
        set(value) { _pointer.value = value }
    private var pointerJob: Job? = null
    private var pendingPointer = false

    init {
        link.discover = { h -> discovery.find(h) }
        link.internet = internet
        // Screen video in an internet session uses the same STUN/TURN servers as the session itself.
        screen.iceSetup = { if (link.route.value?.isInternet == true || forceRelay.value) internet.iceSetup(pairedHost.value) else null }
        // File bytes never pass through a server: relayed internet sessions don't transfer files.
        transfers.blockedReason = { if (link.route.value?.allowsFileTransfer == false) RELAYED_TRANSFERS else null }
        transfers.autoSave = { settings.autoSaveFromMac.value }
        refreshTailscale()
        link.onHostUpdated = { h -> viewModelScope.launch { hostStore.save(h) } }
        runCatching { connectivity?.registerDefaultNetworkCallback(networkCallback) }
        viewModelScope.launch {
            hostStore.current()?.let { link.connect(it) }
        }
        viewModelScope.launch { link.events.collect(::route) }
        // A moving transfer keeps the process (and the link) alive in the background, with a progress notification.
        viewModelScope.launch {
            transfers.items.collect {
                TransferKeepAliveService.update(app, it, inForeground)
                updateReconnectPolicy()
            }
        }
        // Mirroring needs the link while the app isn't visible.
        viewModelScope.launch { notifications.config.collect { updateReconnectPolicy() } }
        viewModelScope.launch { notifications.listenerConnected.collect { updateReconnectPolicy() } }
        viewModelScope.launch {
            var wasConnected = false
            link.state.collect { s ->
                if (s.isConnected && !wasConnected) {
                    record(ActivityKind.Session, "Connected to ${link.session.value?.hostName ?: "your Mac"}", "Encrypted · ${link.route.value?.label ?: "Wi-Fi"}")
                    refreshHealth()
                    notes.sessionStarted()
                    // Viewing was paused by going to the background and the link has just come back.
                    if (resumeScreenOnStart && remoteVisible) {
                        resumeScreenOnStart = false
                        startScreen()
                    }
                }
                if (!s.isConnected && wasConnected) {
                    record(ActivityKind.Session, "Disconnected", s.title)
                    screen.sessionEnded()
                    transfers.sessionEnded()
                    clipboard.sessionEnded()
                    notifications.sessionEnded()
                }
                wasConnected = s.isConnected
            }
        }
    }

    fun setDemo(on: Boolean) {
        demo.value = on
        if (on) {
            health.value = Load.Ready(DemoData.health)
            transcript.value = DemoData.chat
            providerLine.value = "Runs on your Mac via Anthropic API · claude-opus-5-5"
            activity.value = DemoData.activity
            files.value = Load.Ready(DemoData.files)
            filePath.value = "downloads" to ""
            lastVoice.value = DemoData.voice
        } else {
            health.value = Load.Idle
            transcript.value = emptyList()
            providerLine.value = null
            activity.value = emptyList()
            files.value = Load.Idle
            filePath.value = null
            lastVoice.value = null
        }
    }

    private fun record(kind: ActivityKind, title: String, detail: String? = null) {
        activity.value = (listOf(ActivityItem(kind, title, detail)) + activity.value).take(200)
    }

    fun clearActivity() {
        activity.value = emptyList()
    }

    // region Pairing

    fun pair(text: String) {
        pairingError.value = null
        val invitation = try {
            PairingInvitation.parse(text)
        } catch (e: PairingException) {
            pairingError.value = e.message
            return
        }
        viewModelScope.launch {
            when (val outcome = link.pair(invitation)) {
                is PairOutcome.Paired -> {
                    hostStore.save(outcome.host)
                    record(ActivityKind.Pairing, "Paired with ${outcome.host.name}", "Code confirmed on the Mac")
                }
                is PairOutcome.Rejected -> {
                    pairingError.value = "Pairing was declined on the Mac."
                    record(ActivityKind.Pairing, "Pairing declined", outcome.reason)
                }
                is PairOutcome.Failed -> pairingError.value = outcome.message
            }
        }
    }

    fun reconnect() {
        viewModelScope.launch { hostStore.current()?.let { link.connect(it) } }
    }

    fun disconnect() = link.disconnect()

    /** "Connected · Wi-Fi" / "Connected · Tailscale" while connected; otherwise the state's own title. */
    fun statusTitle(s: ConnectionState): String = if (!s.isConnected) s.title else "Connected · ${route.value?.label ?: "Wi-Fi"}"

    // region Internet access (MyBuddy Connect)

    private fun onInternetOffer(e: Envelope) {
        // The offer can arrive right after pairing, before the paired Mac is stored: check against the live link.
        val hostId = link.hostDeviceId ?: pairedHost.value?.deviceId ?: return
        val url = e.payload["serverUrl"]?.jsonPrimitive?.content?.let { ConnectServerUrl.normalize(it, allowDevCleartext = BuildConfig.DEBUG) } ?: return
        val createdAt = e.payload["createdAt"]?.jsonPrimitive?.content ?: return
        if (e.payload["hostDeviceId"]?.jsonPrimitive?.content != hostId) return
        internetOffer.value = InternetOffer(url, createdAt)
        internetMessage.value = null
        record(ActivityKind.Security, "Your Mac offers internet access", url.substringAfter("://"))
    }

    /** The user agreed: register this phone's key with the server, sign the pairing, let the Mac co-sign it. */
    fun allowInternetAccess() {
        val offer = internetOffer.value ?: return
        val h = pairedHost.value ?: return
        viewModelScope.launch {
            internetBusy.value = true
            internetMessage.value = null
            try {
                ConnectClient(offer.serverUrl, identity).register()
                val signature = identity.sign(ConnectStatements.pairing(h.deviceId, deviceId, offer.createdAt))
                val reply = link.request(EventType.CONNECT_ENROLL, buildJsonObject {
                    put("clientDeviceId", deviceId)
                    put("createdAt", offer.createdAt)
                    put("clientSignature", Base64Url.encode(signature))
                }, timeoutMs = 20_000)
                if (reply.type != EventType.CONNECT_ENROLLED) {
                    throw ConnectException(reply.payload["code"]?.jsonPrimitive?.content ?: "error",
                        reply.payload["message"]?.jsonPrimitive?.content ?: "Your Mac couldn’t register internet access.")
                }
                val pairingId = reply.payload["pairingId"]?.jsonPrimitive?.content ?: throw ConnectException("bad_answer", "No pairing id.")
                val updated = (pairedHost.value ?: h).copy(connectUrl = offer.serverUrl, connectPairingId = pairingId)
                hostStore.save(updated)
                link.updateHost(updated)
                internetOffer.value = null
                record(ActivityKind.Security, "Internet access on", offer.serverUrl.substringAfter("://"))
            } catch (e: Exception) {
                internetMessage.value = e.message ?: "Couldn’t turn on internet access."
            } finally {
                internetBusy.value = false
            }
        }
    }

    fun declineInternetOffer() {
        internetOffer.value = null
    }

    /** Removes the pairing from the server (best effort) and forgets the setting; Wi-Fi and Tailscale keep working. */
    fun removeInternetAccess() {
        val h = pairedHost.value ?: return
        val url = h.connectUrl ?: return
        viewModelScope.launch {
            internetBusy.value = true
            runCatching { h.connectPairingId?.let { ConnectClient(url, identity).revokePairing(it) } }
            val updated = h.copy(connectUrl = null, connectPairingId = null)
            hostStore.save(updated)
            link.updateHost(updated)
            internetBusy.value = false
            record(ActivityKind.Security, "Removed internet access", url.substringAfter("://"))
        }
    }

    fun setForceRelay(on: Boolean) {
        if (!BuildConfig.DEBUG) return
        forceRelay.value = on
        internet.forceRelay = on
    }

    // endregion

    fun refreshTailscale() {
        tailscale.value = TailscaleApp.info(getApplication())
    }

    /**
     * Adds the Mac's Tailscale address (100.x.y.z, fd7a:115c:a1e0:…, or a MagicDNS name) for a Mac that was paired
     * before Tailscale was set up. Returns an error message, or null when saved.
     */
    fun addTailscaleAddress(input: String): String? {
        val host = pairedHost.value ?: return "Pair with your Mac first."
        if (demo.value) return "Not available in preview mode."
        val address = Tailnet.normalizeUserAddress(input)
            ?: return "Enter the Mac’s Tailscale address: 100.x.y.z, fd7a:115c:a1e0:… or a name ending in .ts.net."
        if (address in host.addresses) return "That address is already saved."
        val updated = host.copy(addresses = (host.addresses + address).take(6))
        viewModelScope.launch {
            hostStore.save(updated)
            record(ActivityKind.Security, "Added a Tailscale address for ${host.name}", null)
            if (!link.state.value.isConnected) link.connect(updated)
        }
        return null
    }

    fun removeAddress(address: String) {
        val host = pairedHost.value ?: return
        if (demo.value || host.addresses.size <= 1) return
        viewModelScope.launch { hostStore.save(host.copy(addresses = host.addresses - address)) }
    }

    /** Back in the foreground: retry a link that dropped or gave up while the app was in the background. */
    fun onForeground() {
        inForeground = true
        updateReconnectPolicy()
        TransferKeepAliveService.update(getApplication<Application>(), transfers.items.value, foreground = true)
        refreshTailscale()
        if (demo.value) return
        link.resumeIfDropped()
        resumeScreenAfterBackground()
    }

    fun onBackground() {
        inForeground = false
        updateReconnectPolicy()
        pauseScreenForBackground()
    }

    /** In the background the link is only re-established while something needs it (a moving transfer, mirroring). */
    private fun updateReconnectPolicy() {
        val needed = TransferKeepAliveService.summary.value != null || notifications.activeInBackground
        link.holdReconnects = !inForeground && !needed
        if (needed && !inForeground) link.resumeIfDropped()
    }

    fun emergencyStop() {
        link.emergencyStop()
        record(ActivityKind.Security, "Emergency disconnect", "All input stopped")
    }

    fun forgetMac() {
        viewModelScope.launch {
            link.disconnect()
            hostStore.forget()
            record(ActivityKind.Security, "Forgot the paired Mac")
        }
    }

    // endregion

    // region Health

    fun refreshHealth() {
        if (demo.value) return
        viewModelScope.launch {
            if (!link.state.value.isConnected) {
                health.value = Load.Unavailable("Connect to your Mac to see its health.")
                return@launch
            }
            if (health.value !is Load.Ready) health.value = Load.Loading
            health.value = try {
                val reply = link.request(EventType.HEALTH_SNAPSHOT_REQUEST, buildJsonObject { }, timeoutMs = 20_000)
                when (reply.type) {
                    EventType.HEALTH_SNAPSHOT_RESULT -> Load.Ready(HealthParser.parse(reply.payload.getValue("snapshot").jsonObject))
                    else -> errorLoad(reply)
                }
            } catch (e: Exception) {
                Load.Failed("Your Mac didn’t answer in time.")
            }
        }
    }

    private fun errorLoad(e: Envelope): Load<Nothing> {
        val code = e.payload["code"]?.jsonPrimitive?.content
        val message = e.payload["message"]?.jsonPrimitive?.content ?: "Request failed"
        return if (code == "not_permitted") Load.NotAuthorized(message) else Load.Failed(message)
    }

    // endregion

    // region AI (runs on the Mac; this phone never holds provider keys)

    fun sendChat(text: String) {
        val trimmed = text.trim()
        if (trimmed.isEmpty() || chatBusy.value) return
        val id = UUID.randomUUID().toString()
        val history = transcript.value.filter { it.status == ChatTurn.Status.Complete }.takeLast(20)
        transcript.value = transcript.value + ChatTurn(UUID.randomUUID().toString(), true, trimmed) + ChatTurn(id, false, "", ChatTurn.Status.Streaming)
        if (demo.value) return
        chatBusy.value = true
        currentRequest = id
        val messages = buildJsonArray {
            (history + ChatTurn("", true, trimmed)).forEach { t ->
                add(buildJsonObject { put("role", if (t.fromUser) "user" else "assistant"); put("text", t.text.take(8000)) })
            }
        }
        viewModelScope.launch {
            try {
                val reply = link.request(EventType.AI_REQUEST, buildJsonObject {
                    put("requestId", id)
                    put("mode", "chat")
                    put("messages", messages)
                    put("contextSources", buildJsonArray { })
                })
                when (reply.type) {
                    EventType.AI_PROVIDER_STATUS -> {
                        val p = reply.payload
                        providerLine.value = "Runs on your Mac via ${p["displayName"]?.jsonPrimitive?.content} · ${p["modelId"]?.jsonPrimitive?.content ?: ""}"
                        record(ActivityKind.Ai, "Asked ${p["displayName"]?.jsonPrimitive?.content}", "Ran on the Mac")
                    }
                    EventType.AI_ERROR, EventType.ERROR -> failTurn(id, reply.payload["message"]?.jsonPrimitive?.content ?: "Request failed")
                    else -> {}
                }
            } catch (e: Exception) {
                failTurn(id, "Your Mac didn’t answer in time.")
            }
        }
    }

    /**
     * Starts a coding agent on the Mac — [kind] `claude_code` or `codex`, in one of the folders the Mac shares for
     * agents, [level] `read_only` or `edit_workspace` (the Mac asks its user first). Output streams into the transcript.
     */
    fun startAgentTask(prompt: String, kind: String, workspaceId: String, level: String) {
        val trimmed = prompt.trim()
        if (trimmed.isEmpty() || chatBusy.value) return
        val id = UUID.randomUUID().toString()
        val agentName = if (kind == "codex") "Codex CLI" else "Claude Code"
        val folder = session.value?.agentWorkspaces?.firstOrNull { it.first == workspaceId }?.second ?: "folder"
        val label = "$agentName · ${if (level == "edit_workspace") "may edit files" else "read-only"} · $folder"
        transcript.value = transcript.value + ChatTurn(UUID.randomUUID().toString(), true, "$trimmed\n\n— $label") +
            ChatTurn(id, false, "", ChatTurn.Status.Streaming, servedBy = agentName, note = "Starting on your Mac…")
        if (demo.value) return
        chatBusy.value = true
        currentRequest = id
        viewModelScope.launch {
            try {
                val reply = link.request(EventType.AI_REQUEST, buildJsonObject {
                    put("requestId", id)
                    put("mode", "agent")
                    put("messages", buildJsonArray { add(buildJsonObject { put("role", "user"); put("text", trimmed.take(8000)) }) })
                    put("contextSources", buildJsonArray { })
                    put("agent", buildJsonObject { put("kind", kind); put("workspaceId", workspaceId); put("level", level) })
                })
                when (reply.type) {
                    EventType.AI_PROVIDER_STATUS -> {
                        val detail = reply.payload["detail"]?.jsonPrimitive?.content
                        transcript.value = transcript.value.map { if (it.id == id && it.text.isEmpty()) it.copy(note = detail ?: "Running on your Mac…") else it }
                        record(ActivityKind.Ai, "Started $agentName", "$folder · ${if (level == "edit_workspace") "edits need approval on the Mac" else "read-only"}")
                    }
                    EventType.AI_ERROR, EventType.ERROR -> failTurn(id, reply.payload["message"]?.jsonPrimitive?.content ?: "Request failed")
                    else -> {}
                }
            } catch (e: Exception) {
                failTurn(id, "Your Mac didn’t answer in time.")
            }
        }
    }

    fun stopChat() {
        val id = currentRequest ?: return
        link.send(EventType.AI_CANCEL, buildJsonObject { put("requestId", id) })
        failTurn(id, "Stopped")
    }

    private fun failTurn(id: String, message: String) {
        transcript.value = transcript.value.map { if (it.id == id) it.copy(status = ChatTurn.Status.Failed, text = it.text.ifEmpty { message }, note = null) else it }
        chatBusy.value = false
        currentRequest = null
    }

    // endregion

    // region Files

    fun openFolder(rootId: String, path: String) {
        filePath.value = rootId to path
        if (demo.value) return
        files.value = Load.Loading
        viewModelScope.launch {
            files.value = try {
                val reply = link.request(EventType.HOST_FILE_LIST, buildJsonObject { put("rootId", rootId); put("path", path) })
                if (reply.type == EventType.HOST_FILE_LIST) {
                    Load.Ready((reply.payload["entries"] as? JsonArray ?: JsonArray(emptyList())).map {
                        val o = it.jsonObject
                        FileEntry(o.getValue("name").jsonPrimitive.content, o["kind"]?.jsonPrimitive?.content == "folder", o["size"]?.jsonPrimitive?.content?.toLongOrNull())
                    })
                } else {
                    errorLoad(reply)
                }
            } catch (e: Exception) {
                Load.Failed("Your Mac didn’t answer in time.")
            }
        }
    }

    fun sendFileToMac(uri: Uri) {
        if (demo.value) return
        transfers.sendFile(uri)
        record(ActivityKind.Files, "Sending a file to your Mac", null)
    }

    fun downloadFromMac(rootId: String, path: String) {
        if (demo.value) return
        val name = path.substringAfterLast('/')
        record(ActivityKind.Files, "Downloading a file from the Mac", name)
        if (!transfers.requestDownload(rootId, path)) {
            remoteNotice.value = transfers.blockedReason() ?: "Not connected to your Mac."
            return
        }
        val notice = "Asked your Mac for “$name”…"
        val askedAt = System.currentTimeMillis()
        remoteNotice.value = notice
        // The notice gives way to the transfer card as soon as the Mac's offer arrives.
        viewModelScope.launch {
            withTimeoutOrNull(15_000) { transfers.items.first { list -> list.any { !it.toMac && it.name == name && it.updatedAt >= askedAt } } }
            if (remoteNotice.value == notice) remoteNotice.value = null
        }
    }

    fun openFileOnMac(rootId: String, path: String) {
        if (demo.value) return
        viewModelScope.launch {
            val status = runCatching { link.request(EventType.HOST_FILE_OPEN, buildJsonObject { put("rootId", rootId); put("path", path) }) }
                .getOrNull()?.payload?.get("status")?.jsonPrimitive?.content ?: "failed"
            remoteNotice.value = if (status == "opened") "Opened on your Mac" else "Couldn’t open it on your Mac ($status)"
            record(ActivityKind.Files, "Opened a file on the Mac", status)
        }
    }

    // endregion

    // region Voice

    private fun onTranscript(text: String) {
        if (demo.value) {
            voice.showResult("Preview mode: connect to your Mac to run “$text”.", false)
            return
        }
        if (!link.state.value.isConnected) {
            voice.showResult("Connect to your Mac first.", false)
            return
        }
        if (session.value?.granted?.contains("voice.commands") != true) {
            voice.showResult("Voice commands are off for this phone. Turn them on in MyBuddy on your Mac.", false)
            return
        }
        val utterance = UUID.randomUUID().toString()
        viewModelScope.launch {
            var transcriptSeq: Long? = null
            // Subscribe before sending so neither a fast answer nor a refusal can be missed.
            val answer = async(start = CoroutineStart.UNDISPATCHED) {
                withTimeoutOrNull(60_000) {
                    link.events.first {
                        (it.type == EventType.VOICE_INTENT_RESULT && it.payload["utteranceId"]?.jsonPrimitive?.content == utterance) ||
                            (it.type == EventType.ERROR && it.replyTo != null && it.replyTo == transcriptSeq)
                    }
                }
            }
            link.send(EventType.VOICE_STARTED, buildJsonObject { put("utteranceId", utterance); put("source", "phone") })
            transcriptSeq = link.send(EventType.VOICE_TRANSCRIPT, buildJsonObject {
                put("utteranceId", utterance)
                put("text", text.take(2000))
                put("isFinal", true)
                put("locale", Locale.getDefault().toLanguageTag())
            })
            val result = answer.await()
            if (result == null) {
                voice.showResult("No answer from your Mac.", false)
            } else if (result.type == EventType.ERROR) {
                record(ActivityKind.Voice, "“$text”", "refused")
                voice.showResult(result.payload["message"]?.jsonPrimitive?.content ?: "Your Mac refused the command.", false)
            } else {
                val status = result.payload["status"]?.jsonPrimitive?.content ?: "failed"
                val summary = result.payload["spokenSummary"]?.jsonPrimitive?.content ?: ""
                lastVoice.value = VoiceResult(text, status, summary)
                record(ActivityKind.Voice, "“$text”", status)
                voice.showResult(summary, status == "succeeded")
            }
        }
    }

    // endregion

    // region Remote screen (the Mac decides; this phone only asks and renders)

    /** Why the phone can't offer "View screen" right now, or null when it can. */
    fun screenBlocker(): String? {
        val s = session.value
        return when {
            demo.value -> "Preview mode has no real Mac to show. Connect to your Mac to view its screen."
            !link.state.value.isConnected -> "Connect to your Mac to view its screen."
            s?.granted?.contains("screen.view") != true -> "“View screen” is off for this phone. Turn it on in MyBuddy on your Mac (Settings → Devices)."
            "screen" !in s.features -> "Your Mac’s MyBuddy can’t stream its screen yet. Update MyBuddy on your Mac."
            else -> null
        }
    }

    fun startScreen(quality: String = screen.state.value.quality) {
        if (screenBlocker() != null) return
        screen.start(quality)
        record(ActivityKind.Session, "Started viewing the Mac’s screen", "Quality: $quality")
    }

    fun stopScreen(reason: String = "user") {
        if (screen.state.value.isActive) record(ActivityKind.Session, "Stopped viewing the Mac’s screen", null)
        screen.stop(reason)
    }

    /** The app went to the background: never keep receiving the Mac's screen invisibly. */
    fun pauseScreenForBackground() {
        resumeScreenOnStart = remoteVisible && screen.state.value.isActive
        if (resumeScreenOnStart) screen.stop("background")
    }

    /** Resumes viewing now, or as soon as the link is back (see the connection observer). */
    fun resumeScreenAfterBackground() {
        if (!resumeScreenOnStart || !remoteVisible) return
        if (screenBlocker() == null) {
            resumeScreenOnStart = false
            startScreen()
        }
    }

    // endregion

    // region Remote input (absolute normalized coordinates; the Mac enforces permission + Accessibility)

    val hasInputPermission: Boolean get() = session.value?.granted?.contains("input.control") == true

    /** Input goes over the low-latency WebRTC channel while the screen is streaming, else the control channel. */
    private fun sendInput(type: EventType, payload: kotlinx.serialization.json.JsonObject) {
        if (!screen.sendInput(type, payload)) link.send(type, payload)
    }

    private val inputDisplayId: String get() = screen.state.value.host?.displayId ?: "main"

    /** Touchpad: relative movement. */
    fun movePointer(dxFraction: Double, dyFraction: Double) {
        cursor = (cursor.first + dxFraction).coerceIn(0.0, 1.0) to (cursor.second + dyFraction).coerceIn(0.0, 1.0)
        schedulePointer()
    }

    /** Direct touch on the video: absolute position in the streamed frame. */
    fun pointAt(x: Double, y: Double) {
        cursor = x.coerceIn(0.0, 1.0) to y.coerceIn(0.0, 1.0)
        schedulePointer()
    }

    // Coalesce: at most one pointer event per frame interval; never queue stale moves.
    private fun schedulePointer() {
        pendingPointer = true
        if (pointerJob?.isActive == true) return
        pointerJob = viewModelScope.launch {
            while (pendingPointer) {
                pendingPointer = false
                sendInput(EventType.INPUT_POINTER, buildJsonObject {
                    put("x", cursor.first); put("y", cursor.second); put("displayId", inputDisplayId); put("action", "move")
                })
                delay(16)
            }
        }
    }

    /** Sends a pointer move that is still waiting for the next frame slot, so a click/drop never lands before it. */
    private fun flushPointer() {
        if (!pendingPointer) return
        pendingPointer = false
        sendInput(EventType.INPUT_POINTER, buildJsonObject {
            put("x", cursor.first); put("y", cursor.second); put("displayId", inputDisplayId); put("action", "move")
        })
    }

    fun click(button: String = "left", action: String = "click") {
        flushPointer()
        sendInput(EventType.INPUT_BUTTON, buildJsonObject {
            put("button", button); put("action", action); put("x", cursor.first); put("y", cursor.second); put("displayId", inputDisplayId)
        })
    }

    /** Direct touch: click exactly where the finger landed on the picture. */
    fun clickAt(x: Double, y: Double, button: String = "left", action: String = "click") {
        cursor = x.coerceIn(0.0, 1.0) to y.coerceIn(0.0, 1.0)
        click(button, action)
    }

    /** Trackpad drag: hold the left button at the pointer (down) and release it (up). */
    fun pointerButton(down: Boolean) {
        flushPointer()
        sendInput(EventType.INPUT_BUTTON, buildJsonObject {
            put("button", "left"); put("action", if (down) "down" else "up"); put("x", cursor.first); put("y", cursor.second); put("displayId", inputDisplayId)
        })
    }

    /** Three-finger swipe → the macOS shortcut a real trackpad gesture triggers (Spaces, Mission Control, App windows). */
    fun swipe(direction: app.mybuddy.android.core.stream.Trackpad.Swipe) {
        val (code, modifiers) = app.mybuddy.android.core.stream.Trackpad.shortcut(direction)
        key(code, modifiers)
    }

    /** Live typing from the full-screen keyboard (see `LiveTyping`): Backspaces, then the new text. */
    fun liveType(backspaces: Int, text: String) {
        repeat(backspaces.coerceAtMost(64)) { key("Backspace") }
        if (text.isNotEmpty()) typeText(text)
    }

    fun scroll(dx: Double, dy: Double) {
        sendInput(EventType.INPUT_SCROLL, buildJsonObject { put("dx", dx.coerceIn(-2000.0, 2000.0)); put("dy", dy.coerceIn(-2000.0, 2000.0)); put("unit", "pixel") })
    }

    fun key(code: String, modifiers: List<String> = emptyList()) {
        sendInput(EventType.INPUT_KEY, buildJsonObject {
            put("code", code); put("action", "press"); put("modifiers", buildJsonArray { modifiers.forEach { add(JsonPrimitive(it)) } })
        })
    }

    fun typeText(text: String) {
        text.chunked(200).forEach { chunk -> sendInput(EventType.INPUT_TEXT, buildJsonObject { put("text", chunk) }) }
    }

    // endregion

    private fun route(e: Envelope) {
        when (e.type) {
            EventType.CONNECT_OFFER -> onInternetOffer(e)
            EventType.NOTIFICATION_POSTED, EventType.NOTIFICATION_REMOVED -> {
                notifications.handleFromMac(e)
                if (e.type == EventType.NOTIFICATION_POSTED) record(ActivityKind.Session, "Your Mac: ${e.payload["title"]?.jsonPrimitive?.content ?: "alert"}", null)
            }
            EventType.WEBRTC_OFFER, EventType.WEBRTC_ICE, EventType.SCREEN_STATE -> screen.handle(e)
            EventType.FILE_OFFER, EventType.FILE_START, EventType.FILE_CHUNK, EventType.FILE_ACK, EventType.FILE_PAUSE, EventType.FILE_RESUME,
            EventType.FILE_CANCEL, EventType.FILE_COMPLETE, EventType.FILE_ERROR -> transfers.handle(e)
            EventType.CLIPBOARD_OFFER, EventType.CLIPBOARD_REQUEST, EventType.CLIPBOARD_CONTENT, EventType.CLIPBOARD_APPLIED,
            EventType.CLIPBOARD_PAUSED -> clipboard.handle(e)
            EventType.NOTES_INDEX, EventType.NOTES_PUT -> notes.handle(e)
            EventType.AI_DELTA -> {
                val id = e.payload["requestId"]?.jsonPrimitive?.content
                val delta = e.payload["text"]?.jsonPrimitive?.content ?: ""
                transcript.value = transcript.value.map { if (it.id == id) it.copy(text = it.text + delta, note = null) else it }
            }
            EventType.AI_COMPLETE -> {
                val id = e.payload["requestId"]?.jsonPrimitive?.content
                val servedBy = e.payload["servedBy"]?.jsonPrimitive?.content
                transcript.value = transcript.value.map { if (it.id == id) it.copy(status = ChatTurn.Status.Complete, servedBy = servedBy, note = null) else it }
                chatBusy.value = false
                currentRequest = null
            }
            EventType.AI_ERROR -> failTurn(e.payload["requestId"]?.jsonPrimitive?.content ?: "", e.payload["message"]?.jsonPrimitive?.content ?: "AI request failed")
            EventType.ERROR -> {
                val code = e.payload["code"]?.jsonPrimitive?.content
                if (code in setOf("accessibility_required", "not_permitted", "path_denied", "window_share_no_input", "hash_mismatch", "relayed_session")) {
                    remoteNotice.value = e.payload["message"]?.jsonPrimitive?.content
                }
            }
            else -> {}
        }
    }

    override fun onCleared() {
        TransferKeepAliveService.update(getApplication<Application>(), emptyList(), foreground = false)
        runCatching { connectivity?.unregisterNetworkCallback(networkCallback) }
        voice.shutdown()
        screen.dispose()
        link.disconnect(silent = true)
    }
}
