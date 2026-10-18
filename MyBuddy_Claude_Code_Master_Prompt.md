# MYBUDDY — MASTER ENGINEERING PROMPT FOR CLAUDE CODE

> Paste this entire prompt into Claude Code from the root of your project repository. It is designed to make Claude Code inspect, plan, implement, test, and document the project phase by phase. Do not enable unsafe permission bypasses. Review requested permissions normally.

---

## ROLE AND MISSION

You are the principal software architect, senior macOS engineer, senior Android engineer, real-time networking engineer, AI-platform engineer, security engineer, and product designer responsible for building **MyBuddy**.

MyBuddy is a premium, privacy-first companion platform connecting my **Apple Silicon MacBook M1** and **Vivo X300 Android phone**. It must have two real native applications with a matching premium dark design language:

1. **MyBuddy for Mac** — native macOS host and desktop companion.
2. **MyBuddy for Android** — native Android controller and companion.
3. **MyBuddy Connect** — a small, secure connection/signaling service and optional TURN relay infrastructure for internet connectivity.

The product should let an explicitly paired phone view and control an authorized Mac session, use Mac applications and files, synchronize selected clipboard content, transfer files, receive supported notifications, inspect Mac health and battery information, and operate a voice-first assistant. The app also needs an AI workspace where users can select between supported Claude models/services, OpenAI models/services, the Codex coding agent, Claude Code, and local models served by Ollama or another compatible local inference server.

This is a real engineering project, not a mockup-only exercise. Build working slices, run checks, record what was verified, and never claim a capability works unless it has been implemented and tested.

## NON-NEGOTIABLE OPERATING RULES

1. **Inspect before editing.** Run `pwd`, inspect the complete top-level tree, Git status, current branch, README, package manifests, build files, tests, and existing architectural conventions. Determine if this repository is empty, partially built, or contains unrelated code.
2. **Protect existing work.** Do not delete, reset, overwrite or broadly refactor unrelated files. Do not run destructive Git commands. Preserve the current branch and uncommitted work. Before large edits, state the affected files in `docs/IMPLEMENTATION_LOG.md`.
3. **Plan, then implement.** Create `docs/MASTER_PLAN.md`, `docs/ARCHITECTURE.md`, `docs/SECURITY.md`, `docs/PRODUCT_DESIGN.md`, `docs/PROTOCOL.md`, `docs/TEST_PLAN.md`, and `docs/IMPLEMENTATION_LOG.md`. Keep them updated as reality changes.
4. **Build in verified phases.** Do not generate the whole system in one giant speculative patch. Implement a small vertical slice, compile/test it, fix failures, then proceed. Do not stop after creating the plan or scaffolding; keep making concrete progress in the available session.
5. **No fake working UI.** Every screen must be connected to explicit state and an actual service or be clearly shown as a development/preview state. Never fabricate live battery, temperature, network, AI-provider, device status, or session data. Use typed `Unavailable`, `NotAuthorized`, `Loading`, `Error`, and `Available` states.
6. **No insecure shortcuts.** Never use `--dangerously-skip-permissions`, disable security prompts, expose a raw remote shell, hard-code tokens, hard-code private keys, expose Ollama publicly, or create an unauthenticated public control endpoint. Do not bypass macOS or Android permission dialogs.
7. **Use current official documentation** before locking APIs, dependency versions, CLI integration methods, signing requirements or OS behavior. If internet research is unavailable, record the uncertainty and make the implementation behind an interface.
8. **Compatibility first.** Primary development target is Apple Silicon Mac M1 and Android on Vivo X300. Detect actual installed macOS, Xcode, JDK, Android SDK and OS versions before selecting deployment targets. Never invent installed versions.
9. **Explain blockers honestly.** If the current machine cannot compile iOS/Android/macOS artifacts, if a dependency cannot be downloaded, or if a capability requires OS permission/hardware, implement a testable adapter or clear blocker note and continue with tasks that can be verified.
10. **Human approval for risky operations.** The remote-control session must require trusted pairing and explicit permission. Sensitive file access, unattended access, shell/agent commands, deleting files, modifying code, and other risky actions need understandable approval gates.
11. **Tests are part of implementation.** Add unit tests and integration/test harnesses as each module is written. Add a manual hardware test checklist for behavior that cannot be automated in the current environment.
12. **No fake completion.** At the end of each phase list files changed, commands executed, checks passed/failed, real behavior verified, unverified behavior, and the next concrete phase.

## PRODUCT VISION

MyBuddy should feel like a high-end personal computer companion: a mixture of an elegant remote desktop, a device-health dashboard, a secure phone-to-Mac bridge, and a voice-first AI workspace. The UX should feel intentional, responsive, polished and calm—not a generic SaaS template, not a grid of repetitive cards, and not a toy dashboard.

The product should use progressive disclosure: show the important live state first; expose advanced diagnostics, AI tools and permissions only when relevant. Keep the remote-control path fast and direct. AI features must never be able to silently bypass the security model.

## FINAL TECHNOLOGY DECISIONS

Unless repository constraints or a verified incompatibility force a documented change, use this stack:

### macOS
- Language: Swift 6, using the concurrency model supported by the installed toolchain.
- UI: SwiftUI with AppKit integration for platform-specific behavior.
- Screen capture: ScreenCaptureKit with user-visible source selection and the OS permission flow.
- Input: Core Graphics event APIs and Accessibility APIs only for legitimate, explicitly permitted interaction.
- Applications/files: `NSWorkspace`, Foundation file URLs, and user-approved file/folder access.
- Clipboard: `NSPasteboard` with change/revision tracking and loop prevention.
- Voice: Apple Speech framework where supported, AVFoundation/AVSpeechSynthesizer for text-to-speech, and a push-to-talk-first interaction model.
- Battery/power: public IOKit power-source APIs where available, plus safe process/system APIs for other metrics. Use private or undocumented APIs only if a separate research note clearly documents why and they are not required for baseline support; default is not to use them.
- Secure local storage: Keychain.

### Android
- Language: Kotlin.
- UI: Jetpack Compose with Material 3 as a base, heavily customized with MyBuddy design tokens.
- Architecture: MVVM or UDF with repositories and use cases; Kotlin Coroutines/Flow.
- Remote media: maintained libwebrtc Android implementation selected after a compatibility and licensing check.
- Local storage: Room only where persistence is needed; Android Keystore for sensitive cryptographic material.
- Files: Storage Access Framework and user-mediated storage permissions.
- Notifications: `NotificationListenerService`, enabled explicitly by the user through system settings.
- Voice: Android speech APIs when appropriate, optional local STT provider, Android TextToSpeech; microphone capture must have a clear user-visible state and follow foreground-service and current OS restrictions.

### Real-time transport
- WebRTC for video and optional audio, plus data channels for low-latency control/metadata.
- Prefer direct LAN/WebRTC connectivity when possible. Use STUN/TURN to negotiate connectivity and TURN fallback when direct connectivity fails.
- Start with H.264 after verifying the chosen Mac and Android WebRTC builds support the desired hardware acceleration. Use adaptive resolution/bitrate and backpressure. Do not invent a custom video codec or send continuous screenshots over WebSocket.
- Signaling is a separate authenticated HTTPS/WSS protocol. WebSocket carries offers, answers, ICE candidates and session events only; it is not the media transport.

### Backend / infrastructure
- Go for the REST API, WebSocket signaling service, device/session registry and health endpoints.
- PostgreSQL for user/device metadata, pairing records, revocations and minimal audit metadata. Do not store screen frames, remote audio, clipboard content, private files, voice recordings, or model conversations by default.
- coturn for authenticated TURN relay support. Use short-lived credentials; document UDP/TCP/TLS configuration and relay port ranges.
- Docker Compose for local infrastructure and an uncomplicated deployment recipe. Do not add Kubernetes, Redis, microservices or a message broker without a measurable need.
- TLS reverse proxy and a real DNS name for public deployment. Never expose a raw control port to the public internet.

### AI integrations
Implement an explicit provider/agent adapter architecture. Keep **chat model providers** distinct from **coding agents** because authentication, tools, context, approvals and process behavior differ.

**Chat Model mode** should support, through separate adapters:
- Anthropic API models, using the official supported API and a user-provided API key.
- OpenAI API models, using official supported API methods and a user-provided API key.
- Local models served by Ollama using its current supported local API/OpenAI-compatible interface.
- An optional OpenAI-compatible custom endpoint for local inference servers, with a warning and explicit trust configuration.
- A future adapter interface for additional compatible servers without hard-coding provider assumptions into the UI.

**Coding Agent mode** should detect/use supported installed tools such as:
- Claude Code through its documented CLI/SDK interface and normal supported authentication flow.
- OpenAI Codex CLI through its documented CLI/authentication and approval workflow.
- Other local coding agents only through a defined adapter and explicit configuration.

Do not scrape or automate the Claude, ChatGPT, or Codex website UI; do not reverse-engineer private endpoints; do not copy browser cookies; do not harvest OAuth credentials; do not silently reuse a subscription login as an API key. Treat CLI products, API model access, and consumer chat subscriptions as separate integration types. The app must explain whether the selected provider uses an API key, a signed-in official CLI, or a local model server.

All secrets must be held in Keychain on Mac and Android Keystore where applicable, or by the official CLI's supported authentication store. Do not pass secrets in logs, crash reports, URLs, analytics or shell command arguments. When possible, provider credentials should be used only on the Mac host; Android must never receive Mac API keys. The Android client can securely request model work from the paired Mac host over an authenticated session.

### Shared communication contract
- Keep Swift and Kotlin native code separate.
- Define versioned event schemas in `protocol/` and document compatibility rules.
- Prefer strongly typed events and exhaustive decoding; reject unknown privileged commands safely.
- If adopting JSON, use a versioned envelope. Consider Protobuf only if it provides a real benefit; do not introduce it merely for fashion.

## MYBUDDY FEATURE REQUIREMENTS

### A. Device pairing and connections
- QR-based pairing with a short expiry and random high-entropy nonce.
- User must approve new pairing on the Mac.
- Device identity uses public-key material; private keys remain in Keychain/Keystore.
- Manage trusted devices, last-seen time, revocation, and current session state.
- Local Wi-Fi mode must work without a cloud account where feasible.
- Internet mode uses authenticated signaling and TURN fallback.
- Connection states: Offline, Discovering, Pairing, Awaiting Approval, Connecting, Direct Connected, Relayed Connected, Reconnecting, Suspended, Failed, Disconnected.
- Reconnect with bounded exponential backoff and jitter. Never endlessly retry without surfacing state.
- Visible connection quality, round-trip latency measurement where accurate, FPS, bitrate and whether traffic is direct or relayed.

### B. Live remote desktop
- Mac host can stream selected display/window content using system-approved capture selection.
- Android displays the actual received video stream, with pinch-to-zoom, pan, fit/fill, rotate behavior, and multi-display selection if supported.
- Mouse: move, left/right click, double click, drag, scroll and modifier-assisted actions.
- Keyboard: key down/up, modifiers, Unicode text insertion, shortcuts supported by the implementation, keyboard hide/show and stuck-key cleanup on disconnect.
- Separate remote screen viewing from input-control permission.
- Settings for adaptive quality, frame rate target, image quality, fit mode, pointer visualization and audio where supported.
- Initial target: stable 720p/30 FPS local testing, adaptive quality after the pipeline works. Performance figures are targets, not guarantees.
- When the Mac is locked, sleeping, displaying protected content or showing a secure system UI, state the limitations accurately. Do not claim universal pre-login or powered-off remote control.

### C. App and file launcher
- Search/filter installed apps and open normal apps via an allowlisted application-launching interface.
- Browse only a user-approved set of folders/files. Provide explicit permission status and a clear “Grant Folder Access” flow.
- Open normal TXT, Markdown, PDF and other supported files with the default Mac application.
- Provide recent items only with consent and limited local retention.
- Never use an arbitrary shell command as the normal implementation of “open app/file”. Do not expose arbitrary command execution through the phone.

### D. Clipboard and fast transfer
- Two-way plain text clipboard first, with user setting: Off / Ask Every Time / Trusted Pair Auto Sync.
- Android background clipboard access may be restricted; provide foreground/manual copy-paste fallback and show limitation clearly.
- Revision IDs, origin device, content hash, size limits and loop prevention.
- Never synchronize passwords or flagged sensitive clipboard content automatically where it can be detected; offer a pause toggle.
- File transfers: user approval, source/destination picker, transfer ID, chunking, progress, pause/resume where practical, cancel, size caps, checksum verification, temporary filenames and atomic completion.
- No file bytes should pass through a cloud backend unless a future explicit transfer-relay feature is implemented and clearly disclosed.

### E. Notifications
- Android-to-Mac notifications use `NotificationListenerService` after user enablement.
- Mac-to-Android support must be capability-based: MyBuddy's own Mac notifications can be handled; arbitrary third-party macOS notifications cannot be promised universally through public APIs. Build supported adapters and document constraints.
- App filters, content redaction, preview policy, Do Not Disturb behavior where accessible and a master kill switch.
- Notifications are not sent to an AI provider by default.

### F. Mac health and system report
Create a real health dashboard and a detailed report/export view with timestamp and collection status. Include as available:
- Battery percentage, charging/discharging state, power-adapter state, estimated/remaining time only where actually available.
- Battery cycle count, health/condition, maximum capacity/design capacity or health estimate only when the system exposes trustworthy values. Clearly label missing/estimated data and source.
- Storage total/free/used and usage by volume.
- Memory pressure / total and available memory where public APIs provide it; process-level memory/CPU only with a clear scope.
- CPU load or process activity from supported APIs, system uptime, OS version, model/chip identity when available, network interface/IP status subject to privacy settings, connectivity quality, and the MyBuddy host service status.
- Thermal pressure / process activity only when exposed through supported public APIs. Do not invent exact CPU or GPU temperatures or fan RPM if no supported API is available.
- Health score must be explainable; prefer explicit statuses and trends over a fabricated single score. If a score is created, publish its formula and label it as an application estimate.
- History should be local by default with configurable retention. No serial numbers or sensitive hardware identifiers are uploaded to the backend.
- Generate a shareable report (for example JSON and human-readable Markdown/PDF only if dependencies and scope justify it) with preview and redaction controls.
- The “health report” must distinguish OS-reported facts from derived metrics.

### G. Voice assistant — “MyBuddy Voice”
- Design a refined voice mode with an animated orb/waveform, listening/transcribing/thinking/speaking states, live captions, microphone mute and cancel button.
- Start with push-to-talk and tap-to-talk. Add an optional wake phrase later only after a feasibility and battery/privacy audit; never silently record all the time by default.
- Voice interaction on both Mac and Android. For remote commands, the Mac host is the action authority and confirms sensitive actions.
- Support a command router with a small allowlist of typed intents, e.g.:
  - “Show my Mac battery health.”
  - “Start remote screen sharing.”
  - “Open Xcode on my Mac.”
  - “Open the Downloads folder.”
  - “Copy this text to my Mac.”
  - “Pause clipboard sync.”
  - “Show my system health report.”
  - “Switch assistant to my local model.”
  - “Summarize the current visible app” only if screen capture/AI analysis is explicitly consented to.
- Use operating-system speech APIs where appropriate, and allow a local speech-to-text adapter later. Make cloud speech use visible and optional.
- Assistant responses should speak via AVSpeechSynthesizer on Mac and Android TextToSpeech on Android, with voice, speed and mute settings.
- Do not claim Siri integration or impersonate Siri. Call the feature **MyBuddy Voice** or **Voice Assistant**. Do not register a fake OS wake phrase or silently override system voice assistant behavior.
- Confirm destructive, externally visible, money-related, security-sensitive or broad-access actions before executing them.
- Never let model-generated natural language directly call arbitrary shell commands. Use a typed intent registry, permission checks, preview/approval, and action result reporting.

### H. AI workspace and model/agent switcher
- AI Hub should contain provider status, model selector, agent selector, context mode, privacy mode, connection test, token/cost display only when reliable, and per-provider settings.
- Make it clear whether the user is in **Chat Models** or **Coding Agents** mode.
- Chat models: Anthropic API, OpenAI API, local Ollama, configurable OpenAI-compatible local server.
- Coding agents: Claude Code CLI/SDK and Codex CLI using official methods and their own supported sign-in/approval requirements.
- Detect whether the local CLI exists, its reported version, whether it is authenticated using supported checks, and how to install/open its official setup page. Do not expose secrets in diagnostics.
- Model IDs must be provider-defined/configurable and discoverable where official APIs support model listing. Do not hard-code claims of access to a model solely because a name appears in the UI.
- Ollama: default to `http://127.0.0.1:11434` on the Mac. Never bind the Ollama API to the public internet. The phone talks to the MyBuddy Mac host, not directly to an exposed Ollama port. Support test connection, list models, selected model, context-limit/display where actually available, and missing-model status.
- Optional custom local endpoint must be opt-in, validate URL scheme and host, protect against accidental public exposure, and allow user-defined trust. Do not quietly send private code to a remote custom URL.
- Store provider/API settings securely. Show what provider receives content before first use. Offer a “Local Only” mode that blocks network AI providers, telemetry and cloud transcription, except the MyBuddy connection infrastructure needed for remote connectivity as explicitly disclosed.
- Chat history local by default, with clear delete/export controls. Do not sync code, screen content, files, microphone audio or health reports to AI unless the user explicitly sends them.
- Coding-agent tasks operate in a user-selected workspace with a visible allowed path. Provide a diff/command review panel. Keep commands and file changes within a workspace sandbox as far as each official tool supports. Ask before running destructive shell commands, installing dependencies, changing permissions, using network access broadly, deleting files, or committing/pushing changes.
- When an agent cannot provide a stable embeddable API, launch/use its officially supported CLI in an approved local process/terminal mode and disclose its separate authentication. Do not force Claude Code and Codex into a fake universal API.
- Distinguish regular assistant text from executed actions. Log each approved tool/action, its arguments in redacted form, approval result and final status.

## VISUAL AND INTERACTION DESIGN — MUST BE HIGH QUALITY

Create a sophisticated, custom, animated dark visual system for **both** Mac and Android. The interfaces must feel like two views of the same premium product, not duplicate screen layouts.

### Brand direction
- Product: **MyBuddy**.
- Personality: precise, calm, intelligent, trusted, fast, premium, personal.
- Use a custom MyBuddy mark (a simple orbit/pulse/companion symbol built from native vector primitives); do not use third-party or OS logos as the primary brand mark.
- Default theme is dark, with optional light theme only after dark mode is polished.
- Suggested tokens: base obsidian `#0A0C10`, surface `#11151B`, elevated surface `#171D25`, borders `#27303B`, primary text `#F4F7FB`, secondary text `#9AA6B5`, accent electric mint `#B8F36B`, supporting cool cyan `#6CDCF5`, warning amber `#F4BE62`, danger coral `#FF6B76`. Use accent sparingly. Validate contrast and do not rely on color alone.
- Use restrained blurred material, subtle gradient lighting, soft depth, precise typography, consistent icon strokes, carefully tuned spacing and deliberate hierarchy. Avoid excessive glow, neon outlines around everything, distracting particles, unnecessary glass effects, huge empty hero text or generic dashboard cards.
- Use high-quality native animations: short spring-based transitions, progress morphs, connection pulse, level-meter animations, shared content transitions where appropriate, loading skeletons and thoughtful haptics on Android.
- Respect system Reduce Motion and accessibility. Provide dynamic type, screen-reader labels, visible focus states, contrast and touch targets. Animations must not block input or degrade remote control performance.
- Use reusable design tokens; never scatter raw color/spacing constants across components.
- Use real icons from SF Symbols on macOS and Material Symbols / a vetted icon set on Android. Do not use emoji as interface icons.

### Mac information architecture
Use a native, resizable, three-zone layout:
- Left navigation rail/sidebar with MyBuddy brand, status indicator and primary nav: Overview, Remote Desktop, AI Studio, Voice, Files & Clipboard, Notifications, Mac Health, Activity, Settings.
- Main content canvas changes by section.
- Right-side details/inspector on wide displays when useful (session, selected device, AI provider details, health metadata); collapse responsively on smaller windows.
- Top status area shows current paired device/connection state, search/command palette, and user/settings action.
- Avoid a rigid repeated card grid. Use a deliberate mix of live visual surface, tables, compact metrics, timelines, controls and informative empty states.

Mac Overview content:
- Main hero: MyBuddy status, Mac host health and connected Vivo status.
- Remote session preview with “Connect / View Desktop” and explicit status.
- Battery ring/bar, charge state, health/cycle details with provenance where available.
- Live activity timeline: approved sessions, transfers, provider changes, notifications and voice commands, with privacy-safe details.
- AI selector with current provider/model and a “Test connection” action.
- Quick actions: Connect phone, Open app, Send file, Clipboard, Ask MyBuddy, Generate health report.

Mac Remote Desktop content:
- Large live desktop preview / actual stream, quality picker, display selection, pointer visualization, keyboard shortcuts help, fit/zoom controls, latency/FPS diagnostics and obvious Disconnect/Emergency Stop. For no connection, show an elegant pairing/connect state—not fabricated video.

Mac AI Studio content:
- Chat or agent session view with provider/model selector, agent type, streaming output, code/diff view if applicable, approval cards, terminal/process status, cancel/stop, context inclusion controls, privacy indicator and history. The active provider must always be visible.

Mac Voice content:
- Large animated voice orb, explicit mic state, live transcript, last command and its result, voice/locale settings and a large push-to-talk control.

Mac Health content:
- Overview/status; Battery; Storage; Memory & CPU; Connectivity; Host Diagnostics; History; Export Report. Show measured values plus collection source/time and unavailable explanations. No fake gauges.

### Android information architecture
Use a native phone-first UI with bottom navigation: Home, Remote, AI, Files, Activity. Put notifications, health, voice and settings inside Home or secondary navigation without overcrowding the bottom bar.

Android Home:
- Compact paired-Mac identity and connection state.
- Remote connect CTA; battery and health summary; MyBuddy Voice orb/action; AI model/agent status; recent notifications/transfers/activity.
- Content hierarchy and scroll rhythm matter more than stacking many same-sized cards.

Android Remote:
- Video view occupying most of the screen, adaptive controls, full-screen/fit/zoom, touchpad mode, keyboard toggle, left/right click, scroll and drag affordances, quality/latency display, clipboard/file shortcuts, emergency disconnect.
- Touch gestures must be unambiguous. Never send accidental commands while users zoom or pan the remote view. Provide dedicated Touchpad mode and a small control hint.

Android AI:
- Same provider/model and agent concepts as Mac, but phone-optimized. Show if a task actually runs on the Mac host; do not imply the local phone itself is running a large model unless it is.
- Chat composer with voice input, attachments subject to consent, streaming status, context/source chips, tool approval requests and stop generation.

Android Files:
- Paired Mac file browser scoped to approved folders, uploads/downloads, progress, pause/resume/cancel, file hash confirmation and download destination controls.

Android Activity:
- Sessions, file transfers, clipboard sync, notifications and AI actions with filters and privacy-preserving local history.

### Responsive and motion requirements
- Mac: layouts from small window to large desktop and different display scaling.
- Android: phone portrait, landscape remote-control view, keyboard visible, narrow widths and larger font settings.
- Empty/loading/error/offline/no-permission/no-model/no-network states are designed, not raw exception text.
- All controls use consistent radius/spacing/typography tokens and semantic accessibility labels.
- Build reusable components, not one 2,000-line screen.

## SECURITY AND PRIVACY MODEL

Threat-model a stolen phone, malicious local network, session replay, compromised signaling service, malicious file paths, unsafe AI-generated tool calls, provider-key leaks and accidental capture of sensitive content.

Required defenses:
- Pairing QR codes are short-lived, single-use, cryptographically random and tied to a server/mac-host-verified pairing transaction.
- Give each device a public/private key identity; store private keys in Keychain/Keystore.
- Use TLS for HTTPS/WSS, WebRTC's authenticated encrypted media/data transport, and authenticated short-lived TURN credentials.
- Authenticate and authorize every session and every privileged action. Device IDs/session IDs are not secrets or authorization by themselves.
- Enforce a server-side and host-side allowlist of control message types; validate all payload sizes, sequence values, file paths, session participants and command types.
- Reject path traversal and symlink escapes when a file path is resolved within a granted root.
- No arbitrary shell endpoint; no model-generated shell command auto-run; no hidden unattended access.
- Separate capabilities: screen view, input, file access, clipboard, notifications, microphone, AI screen analysis and unattended mode.
- Explicit host confirmation for new pairing and risky actions. The app must keep a visible active-session indicator.
- Immediate local emergency stop and revocation. Stop input and transfers on disconnect/revoke.
- Redact secrets from logs, traces and exception output. No telemetry by default; opt-in if ever added.
- Limit file size, chunk size, number of concurrent transfers and in-memory buffers. Use backpressure and cancellation.
- Apply strict origin/host validation to provider endpoint configuration to reduce SSRF and data exfiltration risk.
- Do not upload battery serial number, full local paths, copied text, raw notifications or transcripts by default.
- Provide clear session audit history and “delete local history” UI.

## PROTOCOL AND DOMAIN MODEL

Define a versioned common envelope, for example:

```json
{
  "version": 1,
  "type": "input.pointer",
  "sessionId": "opaque-session-id",
  "sequence": 1042,
  "sentAt": "ISO-8601 timestamp",
  "payload": { "x": 0.52, "y": 0.38, "action": "move" }
}
```

Treat this as a design example, not permission to trust client values. Specify and test the actual typed schema.

Define event groups:
- Pairing/session: `pairing.request`, `pairing.approved`, `pairing.rejected`, `session.request`, `session.approved`, `session.rejected`, `session.closed`, `host.heartbeat`, `host.status`.
- Signaling: `webrtc.offer`, `webrtc.answer`, `webrtc.ice`.
- Input: `input.pointer`, `input.button`, `input.scroll`, `input.key`, `input.text`.
- App/file: `host.app.list`, `host.app.open`, `host.file.list`, `host.file.open`, `file.offer`, `file.start`, `file.chunk`, `file.ack`, `file.pause`, `file.resume`, `file.cancel`, `file.complete`, `file.error`.
- Clipboard: `clipboard.offer`, `clipboard.request`, `clipboard.content`, `clipboard.applied`, `clipboard.paused`.
- AI: `ai.provider.status`, `ai.request`, `ai.delta`, `ai.complete`, `ai.error`, `ai.tool.proposed`, `ai.tool.approval`, `ai.tool.result`, `ai.cancel`.
- Voice: `voice.started`, `voice.transcript`, `voice.intent.proposed`, `voice.intent.approved`, `voice.intent.result`, `voice.cancelled`.
- Health: `health.snapshot.request`, `health.snapshot.result`, `health.report.exported`.

Use separate transport paths for high-frequency pointer movement, reliable commands, video, and chunked file transfer. Coalesce pointer movement under load; do not let file transfers starve input events. Set per-message limits and timeouts. Cancel in-flight work on session end.

Domain model should include typed entities for Device, Pairing, Session, PermissionGrant, ProviderConfig (without raw key in Codable/loggable types), ModelDescriptor, AgentDescriptor, Transfer, ClipboardRevision, NotificationEvent, VoiceCommand, HealthSnapshot, HealthMetric, ActivityEvent and AppSettings.

## HEALTH AND REPORTING DETAILS

Implement collection as an asynchronous `HealthCollector` with a per-metric status and provenance. Do not let UI views invoke shell commands or perform blocking reads. Prefer documented public APIs. If an API is unavailable or denied, mark that metric unavailable and explain why.

Battery fields when available: level percent, isCharging, power source, charge/health condition, cycle count, full-charge/max capacity, design capacity, current capacity, condition source and capture timestamp. Calculate capacity-health percentage only if both values come from trustworthy values with compatible units. Do not mislabel a current charge percentage as battery health.

System fields when available: OS version, model identifier with privacy controls, uptime, disk capacity by volume, memory pressure/available memory, CPU/process utilization over a sampling interval, network interfaces and connection state. Distinguish app process CPU/memory from whole-system CPU/memory. Do not fabricate temperature, fan speed, GPU load or remaining-time predictions. Document API gaps on Apple Silicon.

Create JSON export with schema version and a human-readable Markdown report. If PDF export is implemented, preview before share and redact local usernames/paths/identifiers by default. Never automatically send a report to an AI provider or cloud.

## AI ARCHITECTURE DETAILS

Build an `AIProviderRegistry`, `ChatModelProvider` interface, `CodingAgentAdapter` interface and `AIExecutionCoordinator`.

Provider configuration fields should include: provider ID, display name, provider kind, endpoint where applicable, auth method, model list status, selected model, supported capabilities (streaming/tools/vision), privacy label, last connection test, and non-secret settings. Secret references point to Keychain/Keystore/official CLI auth storage; the data model must not include or stringify raw secrets.

For normal API chat, support streaming, cancellation, timeouts, retries with a cap, context size handling where reported, and provider-specific error messages. Do not assume all providers support the same response format, tool calling, vision, JSON mode or reasoning settings. Capability-gate UI controls.

For Ollama, add “Test Local Model Server”, “Refresh Models”, “Run local only” and connection diagnostics. Default only to loopback on the Mac. If phone-originated AI prompts must use the Mac's Ollama, route them through the authenticated MyBuddy host and keep Ollama loopback-only. Never put a model server directly on a public interface.

For Claude Code and Codex:
- Use documented supported official CLI/SDK integration methods only, and confirm current method/versions by consulting official docs during implementation.
- Detect CLI installation and version safely.
- Respect each tool's own login, sandbox, approvals and configuration. Do not attempt to bypass approval modes.
- Provide separate UI indicators for “Chat API” and “Coding Agent CLI”.
- Agent job receives a selected workspace and limited context; show active workspace, agent executable/version, running state, stdout/stderr or structured events, current proposed tool/command, changed-file summary and stop/cancel button.
- Require user review before filesystem-wide changes, destructive commands, installing packages, changing security settings, committing/pushing, or broad network access.
- If only an interactive TTY is supported, use a dedicated, explicit terminal/session surface and don't falsely simulate a stable API by parsing fragile terminal screen text. Prefer documented SDK/programmatic mode when it is suitable.
- The UI can let the user switch between providers/agents between tasks, but do not assume conversation state, tool definitions or history transfer seamlessly across providers. Explicitly show when a new provider starts a new session or receives a user-approved summary.

## VOICE MODE AND ACTION ROUTER

Define a `VoicePipeline` interface: audio capture -> speech recognition -> transcript -> intent extraction -> policy/permission check -> user approval if needed -> typed action execution -> result summary -> speech output. Each stage must be cancellable and visible.

Use push-to-talk initially. Avoid continuous microphone capture by default. If future wake-word support is explored, require a separate opt-in, local wake-word processing where practical, explicit microphone indicator, battery measurements, an immediate disable control and documented OS restrictions.

Do not execute a command just because the model produced JSON. Validate intent type and arguments against a strict schema, perform authorization on the Mac host, and display a confirmation for sensitive actions. Use a timeout and reject ambiguous/high-risk intents.

## IMPLEMENTATION PHASES — FOLLOW IN ORDER

### PHASE 0 — Repository reconnaissance and decision record
1. Inspect repo, Git state, installed compilers/toolchains, existing app/server scaffolding, dependencies and docs.
2. Write a concise current-state report and identify verified constraints.
3. Make the docs listed above, including a phase matrix, risks, dependency/license list and initial threat model.
4. Choose concrete currently maintained WebRTC dependencies for macOS and Android after checking platform support, release activity, licensing and build integration. Do not guess coordinates/versions.
5. Establish formatting, linting, unit tests and build commands available in this repo.
6. Do not destroy or restructure unrelated files.
**Phase 0 exit:** plan and design records are committed to disk, buildability has been assessed, and the first vertical slice is identified.

### PHASE 1 — Design system and native app skeletons
1. Build a polished SwiftUI Mac app shell and Compose Android shell with shared brand tokens and dark theme.
2. Implement navigation and complete first-pass screens for Overview/Home, Remote, AI Studio, Voice, Files & Clipboard, Notifications, Mac Health, Activity and Settings.
3. Use believable static design-preview data only in an explicitly named Preview/Demo mode; production state must come from repositories and typed states.
4. Add loading, empty, offline, permission-needed and error states.
5. Add reusable controls, typography, icon conventions, spacing, motion, accessibility labels and Reduce Motion behavior.
6. Build/run each available target and fix compile errors before proceeding.
**Exit:** both apps build with premium coherent dark UI, real navigation and testable state/repository boundaries.

### PHASE 2 — Local identity, pairing and connection state
1. Implement device identities and secure key storage.
2. Implement short-lived QR pairing and Mac approval UI.
3. Implement local device discovery and explicit manual host address fallback for development.
4. Implement typed session states and status diagnostics.
5. Implement Go API/signaling minimum endpoints and authentication tests.
6. Add revocation and reject untrusted peers.
**Exit:** the Vivo and Mac pair securely on local Wi-Fi, display actual connection states, and unknown devices are refused.

### PHASE 3 — Real screen streaming
1. Implement the Mac ScreenCaptureKit service with system permission/source-selection flow.
2. Integrate the selected native WebRTC build and publish real captured frames.
3. Implement the Android receiver/renderer.
4. Establish WebRTC signaling/ICE through the backend and make local LAN media path work.
5. Add quality settings, frame/bitrate telemetry and stream restart/recovery.
6. Add tests for stream states and a documented hardware test for actual rendering/performance.
**Exit:** real Mac screen content renders on Vivo; no placeholder is mistaken for a live connection.

### PHASE 4 — Mouse, keyboard and emergency stop
1. Implement versioned data channel input protocol.
2. Implement normalized coordinate mapping for scaling/rotation.
3. Add mouse movement, button click, double click, drag, scroll and keyboard/modifier/text input.
4. Ensure key/button states are released on disconnect or error.
5. Add independent permissions for viewing and controlling.
6. Add host-side rate/size validation, command allowlists, audit events and immediate stop.
**Exit:** remote input works on ordinary authorized desktop apps; revoking/disconnecting stops input promptly.

### PHASE 5 — App launcher and safe file access
1. Implement app listing/open via native API and search.
2. Implement user-granted folder access and file metadata browsing.
3. Open selected files with their default applications.
4. Defend against path traversal and symlink escape.
5. Add tests for access denial and unauthorized path attempts.
**Exit:** ordinary apps and selected files open remotely without arbitrary shell execution.

### PHASE 6 — Clipboard and file transfer
1. Implement clipboard revision/hash protocol and loop protection.
2. Add settings for Off, Ask, Trusted Pair Auto Sync; provide Android foreground/manual fallback.
3. Implement file metadata/chunk/ack/progress/cancel flow.
4. Add checksum verification, temporary-file strategy, size/concurrency limits and path validation.
5. Add disconnect/retry behavior and tests for corrupt chunks, cancellation, duplicate revisions and oversized input.
**Exit:** text copies in supported directions and selected files transfer with verified integrity.

### PHASE 7 — Laptop health and report
1. Implement asynchronous public-API-first collectors and typed per-metric status/provenance.
2. Implement battery state and health/cycle information only when exposed and trustworthy.
3. Implement storage, memory/CPU scopes, uptime, OS/version, network/host status and supported thermal pressure signals.
4. Build the Mac Health UI and report detail/export flows.
5. Add synthetic unit-test fixtures but ensure production never displays fixtures as actual measurements.
6. Test denied/missing data and explain unsupported metrics.
**Exit:** report values are sourced, timestamped, exportable and do not fabricate unavailable battery/thermal data.

### PHASE 8 — AI Chat provider hub
1. Define provider interfaces and capability model.
2. Implement Anthropic API, OpenAI API and local Ollama adapters with stream/cancel/errors where supported.
3. Add model discovery/selection only where supported, provider test, credential storage, endpoint validation and privacy disclosure.
4. Add local-only mode and test it prevents cloud provider requests.
5. Keep secrets out of logs and ensure Android does not receive Mac provider keys.
6. Add UI for Chat Models vs Coding Agents and clearly indicate selected provider/model.
**Exit:** at least one cloud provider and one local Ollama model can complete a real streaming test when credentials/model are available; missing credentials are shown clearly.

### PHASE 9 — Claude Code/Codex agent connections
1. Check official current documentation for the Claude Code CLI/Agent SDK and Codex CLI, including versioning, authentication, approvals and usage constraints.
2. Implement independent `ClaudeCodeAdapter` and `CodexAdapter` based on supported integration surfaces.
3. Safely detect executable/version/auth readiness without printing secrets.
4. Implement user-selected workspace, visible agent process status, streaming output/events if supported, cancellation and review of changes/commands.
5. Keep command execution gated by each agent's supported permission model and add MyBuddy's independent approval layer.
6. Never scrape service UIs or merge provider auth/session cookies.
7. Provide setup instructions if an official CLI is missing or requires the user to authenticate in its own official flow.
**Exit:** the app can safely detect and start or hand off to a supported agent flow; if an integration cannot be embedded reliably, document the limitation and offer a first-class launch/open-terminal fallback rather than faking it.

### PHASE 10 — MyBuddy Voice
1. Implement push-to-talk UI and mic permission state on both platforms.
2. Implement transcription via supported system speech APIs and a pluggable future local STT provider.
3. Implement typed intent recognition and command registry.
4. Implement approval for sensitive actions and route actual action to the Mac host.
5. Implement speech output, interruption/cancel and live captions.
6. Test ambiguous command, permission denied, no network, noisy transcript, cancellation and dangerous command rejection.
7. Add wake phrase only as a separate opt-in project after proving privacy, battery and OS feasibility.
**Exit:** voice can ask battery status and issue low-risk allowlisted commands with visible transcript and accurate result; no silent/high-risk command execution.

### PHASE 11 — Internet access, TURN and resilience
1. Deploy Go API/signaling service and TLS reverse proxy.
2. Configure coturn with short-lived credentials, valid firewall ports and documented rate/bandwidth metrics.
3. Test direct connection from different networks and a forced-TURN case.
4. Add reconnect logic, host offline state, internet loss state and bounded retries.
5. Add relay resource limits, metrics and deployment security notes.
6. Verify local-only sessions continue where feasible without cloud reachability.
**Exit:** remote access works across the tested external networks, including relay fallback, without exposing raw control ports.

### PHASE 12 — Notifications, polishing and release readiness
1. Add Android notification listening after explicit consent and app filters/redaction.
2. Add supported Mac notification integrations and document what cannot be captured universally.
3. Finish cross-device visual consistency, responsive states, animations, reduced motion and accessibility.
4. Add full regression testing, dependency license review, key/secret scan, static checks and crash-state handling.
5. Add Mac signing/notarization guidance and Android APK build/signing guidance. Never store release signing secrets in the repository.
6. Add end-to-end manual test guide for Mac M1 + Vivo X300 and known limitations.
**Exit:** the release checklist identifies verified, unverified and platform-limited features without overclaiming.

## TESTING STRATEGY

For each phase, add:
- Unit tests for domain/state/protocol parsing, coordinate transforms, clipboard revisions, path containment, provider capability handling, health calculations and voice intent schema.
- Integration tests for API authorization, pairing lifecycle, WebSocket message authorization, session termination, provider errors and file transfer integrity.
- Static checks: Swift build/tests and formatting/lint tool if configured; Android Gradle build/tests/lint; Go `gofmt`, `go vet`, and `go test ./...`; dependency/security scan if tooling exists.
- Manual hardware tests for real screen capture, permission prompts, remote mouse input, WebRTC codec/hardware acceleration, Android lifecycle, Vivo background/battery behavior, voice capture, actual battery data availability and TURN relay.
- Failure tests: host sleeps/goes offline, network switches Wi-Fi to hotspot, app permission is revoked, unknown device connects, invalid event schema sent, oversized file submitted, provider key missing, local Ollama stopped, agent CLI missing, user cancels, and app force-quits during transfer.

Never suppress failing tests to make the build appear green. If hardware cannot be accessed in this session, mark that test “not run — requires target device” and provide exact manual steps.

## DEFINITION OF DONE

A feature is complete only when:
1. Production code exists and is wired into the actual UI.
2. Failure/loading/permission states are implemented.
3. Security and cancellation paths are covered.
4. Tests or clearly documented hardware checks exist.
5. The current phase's builds/checks have been run and their real output recorded.
6. Documentation matches what is truly implemented.
7. The user can tell clearly what data is local, what goes to a provider, and when remote access is active.

## REQUIRED FIRST RESPONSE AND EXECUTION BEHAVIOR

When this prompt is submitted, do not reply with another high-level plan and stop. First inspect the repository and installed environment. Then:

1. Summarize what exists and what can actually be built here.
2. Create/update the project docs listed above.
3. Select Phase 0 tasks that can be performed now.
4. Start implementing Phase 1 immediately when the environment supports it, or implement the smallest testable slice that is possible in this repository.
5. Run build/test commands and fix the failures caused by your changes.
6. Continue through phases as far as this session and available toolchain allow. Do not claim future/background work.
7. At the end, give a concise handoff with: current phase, concrete features implemented, key files, commands/tests and results, manual target-device checks still required, known limitations, and the single next engineering task.

If the repository already has a project structure, adapt to it instead of blindly using the sample layout below. If it is empty, start with this structure (adjust based on verified framework conventions):

```text
MyBuddy/
  apps/
    macos/MyBuddyMac/
    android/MyBuddyAndroid/
  services/
    connect-api/
  protocol/
  infrastructure/
  docs/
```

## FINAL GUIDING PRINCIPLE

Build MyBuddy as a secure, native, premium-quality remote companion—not an unsafe remote shell, not a fake dashboard, and not an AI wrapper that leaks secrets. Prioritize the real Mac-to-Vivo connection and control path, then layer files, clipboard, health, AI agents, voice, and notifications on the same verified architecture. Prefer clear boundaries, measurable performance, native UI quality and honest capability reporting over adding many unfinished features.

Start now by inspecting the repository and reporting only verified findings, then create the implementation documents and begin the first buildable phase.

---

# OFFICIAL REFERENCE LINKS TO VERIFY DURING IMPLEMENTATION

- Apple ScreenCaptureKit: https://developer.apple.com/documentation/screencapturekit
- Apple Core Graphics: https://developer.apple.com/documentation/coregraphics
- Apple Speech: https://developer.apple.com/documentation/speech
- Apple IOKit power-source keys: https://developer.apple.com/documentation/iokit/iopskeys_h
- Android NotificationListenerService: https://developer.android.com/reference/android/service/notification/NotificationListenerService
- Android foreground-service restrictions: https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start
- WebRTC peer connections: https://webrtc.org/getting-started/peer-connections
- Claude Code CLI documentation: https://code.claude.com/docs/en/cli-reference
- OpenAI Codex CLI: https://help.openai.com/en/articles/11096431
- Ollama API overview: https://github.com/ollama/ollama/blob/main/docs/api/introduction.mdx
- Ollama OpenAI-compatible API: https://github.com/ollama/ollama/blob/main/docs/api/openai-compatibility.mdx
