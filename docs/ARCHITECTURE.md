# MyBuddy Architecture

## 1. System overview

```
┌──────────────────────── Vivo X300 (Android) ────────────────────────┐        ┌──────────────── MacBook Air M1 (macOS) ────────────────┐
│ Compose UI (Home · Remote · AI · Files · Activity)                   │        │ SwiftUI shell (sidebar · canvas · inspector)            │
│ ViewModels (UDF) ── repositories ── use cases                         │        │ AppModel (@MainActor) ── stores ── services             │
│  SessionRepository ─ MBH1 client ─ LAN WebSocket / Connect relay  ◄──┼─ MBH1 ─┼─► LAN host (Network.framework, Bonjour) ─ MBH1 server  │
│  RemoteRepository ─ WebRTC receiver (libwebrtc M150)              ◄──┼─ SRTP ─┼─  ScreenCaptureKit → WebRTC (LiveKitWebRTC M150)       │
│  Input encoder (normalized coords, coalescing)                    ───┼─ data ─┼─► InputInjector (CGEvent, Accessibility-gated)        │
│  Keystore identity (P-256)                                           │        │ Keychain identity (P-256) · Keychain secrets           │
│  SpeechRecognizer / TextToSpeech                                      │        │ HealthCollector (IOKit · Mach · sysctl · NWPath)       │
└──────────────────────────────────────────────────────────────────────┘        │ AI: provider registry · coordinator · agent adapters   │
                    │ HTTPS/WSS (internet mode only)                            │ Voice: Speech · intent router · AVSpeechSynthesizer     │
                    ▼                                                           └─────────────────────────────────────────────────────────┘
          ┌────────── MyBuddy Connect (Go) ──────────┐                                      │ HTTPS (user's keys, Mac only)
          │ devices · auth challenges · tokens        │                                      ▼
          │ pairing registry · revocation             │                        Anthropic API · OpenAI API · Ollama (127.0.0.1)
          │ /v1/signal opaque relay · TURN creds      │                        Claude Code CLI · Codex CLI (local processes)
          │ PostgreSQL (metadata only) · coturn       │
          └───────────────────────────────────────────┘
```

## 2. Repository layout

```
apps/macos/MyBuddyMac/          SwiftPM package (builds with Command Line Tools; Xcode optional)
  Sources/MyBuddyCore/          Platform-neutral domain + protocol + crypto + policies (Foundation, CryptoKit)
  Sources/MyBuddyHost/          macOS adapters: Keychain, IOKit health, NSWorkspace, NSPasteboard,
                                Process runner, CLI agents, Speech, LAN host server
  Sources/MyBuddyDesign/        Design tokens + reusable SwiftUI components
  Sources/MyBuddyMedia/         ScreenCaptureKit capture + WebRTC publishing (the only target linking libwebrtc)
  Sources/MyBuddyMac/           App entry, AppModel, feature screens (`--demo`, `--snapshot <dir>`)
  Sources/MyBuddyTestSupport/   Test-only labelled test-pattern frame source (never linked into the app)
  Sources/MyBuddyInteropHost/   Test-only host for driving the Android app: loopback, or `--tailnet` (not bundled)
  Tests/…                       Swift Testing suites
  scripts/                      build-app.sh (bundle + ad-hoc sign), test.sh (CLT flags), embed-catalog.sh
apps/android/MyBuddyAndroid/    Gradle (AGP 9.4.1, Kotlin 2.4.21, Compose BOM 2026.09.00)
  app/src/main/java/app/mybuddy/android/
    core/{Encoding.kt, protocol, crypto, session, stream}   pure Kotlin, JVM-tested against shared fixtures/vectors
    data/{Identity, MacLink, MacDiscovery, ScreenReceiver, TailscaleApp, Models, Voice, DemoData}
                                Keystore, MBH1 link (Wi-Fi/Tailscale race), NSD discovery, WebRTC receiver, speech
    AppViewModel.kt  ui/{theme, components, screens}  MainActivity.kt
services/connect-api/           Go 1.26 service: cmd/connect-api, internal/{api,config,mbcrypto,ratelimit,signal,store,turn}
protocol/                       Envelope schema, event catalog, fixtures, MBH1 vectors (+ Go generator)
infrastructure/                 docker-compose, coturn + Caddy examples, deployment notes
docs/                           This documentation set
```

Swift and Kotlin code are separate implementations of the same contract; the contract is enforced
by shared fixtures and vectors, not by shared code.

## 3. Mac app layering

| Layer | Responsibility | Rules |
|---|---|---|
| `MyBuddyCore` | Types (`Device`, `Pairing`, `Session`, `PermissionGrant`, `ProviderConfig`, `ModelDescriptor`, `AgentDescriptor`, `Transfer`, `ClipboardRevision`, `NotificationEvent`, `VoiceCommand`, `HealthSnapshot`, `HealthMetric`, `ActivityEvent`, `AppSettings`), envelope codec, MBH1, path guard, clipboard loop guard, transfer chunking, health report rendering, AI provider protocols + HTTP adapters, intent registry, redaction | No AppKit/SwiftUI. Everything injectable (`HTTPClient`, `Clock`, `RandomSource`). 100% unit-testable. |
| `MyBuddyHost` | Concrete macOS services: `KeychainSecretStore`, `KeychainIdentityStore`, `SystemHealthCollector`, `WorkspaceAppCatalog`, `PasteboardMonitor`, `ProcessRunner`, `ClaudeCodeAdapter`, `CodexAdapter`, `SpeechInputService`, `SpeechOutputService`, `LANHostServer` | Talks to OS APIs. Never called from views directly; views go through `AppModel` stores. No shell (`/bin/sh -c`) anywhere. |
| `MyBuddyDesign` | Tokens (`MBColor`, `MBSpacing`, `MBRadius`, `MBType`, `MBMotion`), components (`BrandMark`, `StatusPill`, `MetricTile`, `SectionCard`, `StateView`, `VoiceOrb`, `ProviderBadge`, `KeyValueRow`, `TimelineRow`) | No raw colors or magic spacing outside this module. Respects Reduce Motion. |
| `MyBuddyMac` | `AppModel` + feature stores, navigation, screens, Preview/Demo mode | Screens render typed `LoadState<T>` (`loading`, `available`, `unavailable(reason)`, `notAuthorized(reason)`, `failed(error)`). Demo data only exists in `DemoData` and is shown with a visible "Preview data" badge. |

### State flow

`View → AppModel action → service (async) → typed result → @Published/@Observable state → View`.
Long-running work runs in `Task`s owned by stores, cancelled on teardown or session end.

## 4. Android layering

UDF: `Screen (Compose) → ViewModel (StateFlow<UiState>) → Repository → data source/service`.
`UiState` uses the same typed availability model as the Mac (`Loading`, `Available`, `Unavailable`,
`NotAuthorized`, `Error`). Pure logic (protocol codec, MBH1, intents, transfer assembly, clipboard
revision logic, backoff, stream state/stats parsing, discovery and Tailscale address rules) lives in
`core/*` with JVM unit tests. Platform pieces (Keystore, CameraX + ZXing QR scanning, NSD discovery,
WebRTC receiver + TextureView renderer, SpeechRecognizer/TextToSpeech) live in `data/` and
`ui/components/`. As built, a single `AppViewModel` exposes `StateFlow`s and a `Load<T>` availability
type (`Idle`, `Loading`, `Ready`, `Unavailable`, `NotAuthorized`, `Failed`).

## 5. Connectivity

Details, setup and security: `CONNECTIVITY.md`.

* **LAN mode (no cloud):** Mac runs `LANHostServer` (WebSocket over TCP, Bonjour `_mybuddy._tcp` with TXT
  `fp`). Phone uses the address list from the QR (or the pasted pairing link), and Android NSD finds the Mac
  again when its IP changes. Both sides accept only local-network addresses in an invitation
  (PROTOCOL §6.1). MBH1 secures the channel. WebRTC video uses host candidates on the LAN (no STUN/TURN).
* **Tailscale mode (no MyBuddy server):** the Mac's listener also accepts tailnet addresses (switchable);
  the QR carries the Mac's tailnet IP when Tailscale really routes; the phone can add a tailnet IP or
  MagicDNS name later. The phone races Wi-Fi addresses first and Tailscale 600 ms later; the UI says which
  route is in use on both sides.
* **Internet mode (MyBuddy Connect, CONNECTIVITY §3):** the Mac signs in with its device key (challenge → 15-min
  token, memory only) and stays on `/v1/signal` while internet access is on (`InternetHost`, MyBuddyMedia). The phone
  (`InternetDialer`) does the same only when Wi-Fi and Tailscale didn't answer, sends a signed offer for the
  `mb-session` data channel, verifies the Mac's signed answer, and trickles ICE through the server (STUN/TURN from
  `/v1/turn-credentials`). The open channel becomes an MBH1 transport: Mac `LANHostServer.adopt(HostTransport)`
  (resume only), phone `MacLink` over an `RtcPipe` — the rest of both apps can't tell the difference except for the
  session route (`localNetwork`, `tailscale`, `internetDirect`, `internetRelayed`), which drives labels and turns file
  transfer off when relayed. Enrolment rides the MBH1 session (`connect.offer/enroll/enrolled`).
* **Connection states** (shared enum on both platforms): `offline, discovering, pairing,
  awaitingApproval, connecting, directConnected, relayedConnected, reconnecting, suspended, failed,
  disconnected`. Reconnect uses bounded exponential backoff with full jitter (base 0.5 s, cap 30 s,
  max 8 attempts) and then surfaces `failed` with a retry button — never silent infinite retries.

## 6. Remote desktop pipeline (Phase 3 built; input over WebRTC data channels is Phase 4)

```
Mac   ScreenShareController (actor, MyBuddyMedia)
        ScreenCaptureKitSource: SCShareableContent → SCStream (display, or picker selection) scaled by the
          window server to the tier box, NV12 full range, ≤ 30 fps; last frame re-sent every 250 ms while the
          screen is static (keyframes for new decoders)
        → LKRTCVideoSource (screencast) → H.264 via VideoToolbox (hardware; High then Constrained Baseline,
          packetization-mode 1; VP8/VP9/AV1 fallback) → send-only transceiver, maintain-resolution
        → DTLS-SRTP over ICE host candidates (LAN or tailnet)
Phone ScreenReceiver: answers (receive-only), DefaultVideoDecoderFactory (MediaCodec, hardware where
        available) → VideoTrack → TextureViewRenderer (EglRenderer into a TextureView, so pinch-zoom/pan are
        plain view transforms)
Input: direct touch on the video (Control mode: tap/double-tap/long-press/drag/two-finger scroll, mapped by
        VideoGeometry) or the touchpad → normalized (x,y) → `mb-input` / `mb-input-rel` data channels while
        streaming (MBH1 `input.*` otherwise) → DataChannelInputGate + grant check → RemoteInput →
        streamed display's coordinates → CGEvent (Accessibility-gated; released when channels close)
```

Tiers: low 960×600@15 (0.8 Mbps), balanced 1280×800@30 (2.5 Mbps), high 1920×1200@30 (6 Mbps), never
upscaled. `auto` steps down after 4 s of `qualityLimitationReason = bandwidth|cpu`, up after 20 s of headroom
when the bandwidth estimate fits, holding 10 s after each change. Telemetry (fps, bitrate, resolution, codec,
encoder/decoder, RTT, direct/relayed path) comes from `getStats()` on each side — never estimated. The Mac's
Remote Desktop canvas renders the outgoing track itself (`LKRTCMTLVideoView`), so the preview is exactly
what the phone gets.

## 6a. Files and clipboard (Phase 6)

* **Mac** — `TransferService` (MyBuddyHost) runs both directions for every session on one lock: offers,
  `SendWindow` flow control (8 chunks), `FileReceiver` temp files + atomic rename, quarantine tagging,
  ask/auto-save policy, stall/acceptance watchdogs and session-end cleanup. `FilesStore` owns it, answers
  `file.request` through `FolderAccessStore.resolve` (the same path guard as browsing) and drives the
  Transfers panel (Accept/Decline, pause/resume/cancel, Show in Finder, Send File to Phone…). The connection
  handler hands `file.*` envelopes straight to the service on the connection queue (chunks never hop to the
  main actor). Clipboard: `PasteboardMonitor` + `ClipboardPolicy` (modes, concealed types, secret patterns).
* **Android** — `TransferManager` keeps all transfer state on one serial job queue: SAF reads through a
  `FileChannel` (no copies), pending MediaStore entries in `Downloads/MyBuddy` published after the SHA-256
  matches, `file.request` downloads auto-accepted by `requestId`. `TransferKeepAliveService` (foreground
  service, type `dataSync`) runs only while a transfer moves so Android doesn't freeze the process mid-way.
  `ClipboardBridge` implements Off/Ask/Automatic with the shared `ClipboardRules` and loop guard.
* **Background policy (Android)** — outside a moving transfer the link is not re-established while the app
  is in the background (`MacLink.holdReconnects` → `Suspended`); opening the app resumes it at once.
* **Test host** — `MyBuddyInteropHost --files <dir>` runs the real `TransferService` against the emulator
  with a log-only fake clipboard (TEST_PLAN §3.1 step 8).

## 6b. Notifications (Phase 12)

* **Android → Mac** — `MirrorListener` (`NotificationListenerService`, bound by Android after the user enables
  notification access) hands each notification to `NotificationMirror`, which applies the master switch, Do Not
  Disturb pause, app filters and `NotificationRules` (filtering, preview policy, masking, salted ids) and sends
  `notification.posted/removed` over the live session — nothing is queued. While the listener is bound Android keeps
  the process at foreground-service priority, so the link stays up in the background (`MacLink.holdReconnects` is off
  while mirroring is active). The app's single `AppViewModel` is process-scoped (`MyBuddyApplication` is the
  `ViewModelStoreOwner`) so the listener, the transfer foreground service and the UI share one link.
* **Mac** — `NotificationsStore` keeps the last 100 in memory for the Notifications page, optionally posts macOS
  banners (`UNUserNotificationCenter`, only inside the app bundle, only when turned on), and sends MyBuddy's own
  alerts to phones holding `notifications.mirror`: battery low (`BatteryAlertPolicy`, IOKit power sources every
  2 min) and going to sleep (`NSWorkspace.willSleepNotification`). macOS offers no public API for other apps'
  notifications.

## 7. AI architecture

```
AIProviderRegistry ── ProviderConfig[] (non-secret) + SecretStore (Keychain)
   ├─ ChatModelProvider: AnthropicProvider · OpenAIProvider · OllamaProvider · OpenAICompatibleProvider
   │     listModels() · testConnection() · streamChat(request) -> AsyncThrowingStream<ChatEvent>
   └─ CodingAgentAdapter: ClaudeCodeAdapter · CodexAdapter
         detect() -> AgentDetection(executable, version, auth) · start(task) -> AgentRun(events, cancel)
AIExecutionCoordinator: privacy policy (Local Only), endpoint validation, capability gating,
   cancellation, timeout, capped retries, activity logging (redacted)
```

* Chat providers and coding agents are different types with different UIs ("Chat Models" vs
  "Coding Agents"). Conversation state never silently transfers between providers; switching starts a
  new session (or sends a user-approved summary).
* Anthropic: `POST /v1/messages` (`anthropic-version: 2023-06-01`), SSE streaming, `GET /v1/models`
  for discovery + capabilities, handles `stop_reason: "refusal"`; optional server-side refusal fallback
  (`fallbacks: "default"`, beta header `server-side-fallback-2026-07-01`) on supported models, with the
  serving model shown in the UI.
* OpenAI: `POST /v1/responses` streaming (`response.output_text.delta`, `response.completed`, `error`,
  `response.failed`, `response.incomplete`), `store: false`, `GET /v1/models`.
* Ollama: `GET /api/version`, `GET /api/tags`, `POST /api/show` (context length from `model_info`),
  `POST /api/chat` NDJSON streaming; default `http://127.0.0.1:11434`.
* Claude Code: `claude -p --output-format stream-json --verbose --permission-mode plan` in the approved
  workspace, prompt via stdin; status via `claude auth status --json` (only `loggedIn`/`authMethod` kept).
* Codex: `codex exec --json --sandbox read-only -C <workspace> -` with the prompt on stdin;
  status via `codex login status` (only the "Logged in using …" method kept).

## 8. Health architecture

`SystemHealthCollector` runs collectors concurrently with per-collector timeouts and returns a
`HealthSnapshot`. Each `HealthMetric<Value>` has `status` (`available`, `unavailable(reason)`,
`notPermitted(reason)`, `estimated(note)`), `source` (e.g. `IOKit IOPSCopyPowerSourcesInfo`,
`system_profiler SPPowerDataType`, `host_statistics64`, `ProcessInfo.thermalState`) and `collectedAt`.
Derived values (e.g. capacity %) are labeled `derived` with their formula. No temperatures, fan RPM or
GPU load are shown because Apple Silicon exposes no supported public API for them.

## 9. Voice pipeline

`capture → recognize → transcript → intent extraction (rule-based, allowlisted) → policy check →
approval (if needed) → typed action on the Mac host → result → speech output`. Each stage is a state in
`VoicePipelineState` and is cancellable. Push-to-talk only; no wake word in v1.

## 10. Persistence

| Data | Mac | Android | Server |
|---|---|---|---|
| Identity key | Keychain | Keystore | public key only |
| Trusted devices / grants | Keychain item (JSON) | DataStore | pairing metadata |
| Provider configs (non-secret) | `Application Support/MyBuddy/settings.json` | — | — |
| Provider secrets | Keychain | never | never |
| Activity log, health history, chat history | `Application Support/MyBuddy/*.json`, retention-bounded | DataStore/Room (when added) | never |
