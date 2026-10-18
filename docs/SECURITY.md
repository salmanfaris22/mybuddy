# MyBuddy Security & Privacy Model

Scope: MyBuddy for Mac (host, action authority), MyBuddy for Android (controller), MyBuddy Connect
(Go signaling/registry service + coturn). Companion documents: `PROTOCOL.md` (wire formats, MBH1),
`ARCHITECTURE.md` (components).

## 1. Principles

1. **The Mac is the action authority.** Every privileged action (input, app/file open, transfers,
   AI tool calls, voice intents) is authorized on the Mac against the session's capability grants.
   The phone can request; it can never decide.
2. **Explicit, visible, revocable.** Pairing requires a QR scan *and* host approval with a matching
   6-digit code. An active session always shows an on-screen indicator on the Mac. Emergency Stop and
   revocation take effect immediately and locally, without the network.
3. **Least privilege by capability.** Viewing, controlling, files, clipboard, notifications,
   microphone, AI chat, AI agents, AI screen analysis and unattended access are separate grants.
   Unattended access is **not offered in v1**.
4. **End-to-end between devices.** The Connect service relays ciphertext only.
5. **Nothing leaves the device by default.** No telemetry. No screen frames, audio, clipboard,
   files, notifications, transcripts, health reports or AI conversations are stored on the server.
6. **No arbitrary execution.** There is no shell endpoint. AI- or voice-generated text never becomes a
   shell command. Actions go through typed, allowlisted intents with schema validation.
7. **Honest capability reporting.** Unavailable data is reported as unavailable, with a reason.

## 2. Assets

| Asset | Where | Protection |
|---|---|---|
| Device identity private keys | Mac Keychain / Android Keystore (hardware-backed when available) | Non-exportable where the platform allows; never logged or transmitted |
| MBH1 session keys | Process memory only | Ephemeral ECDH per session; zeroed on close where the language permits |
| Pairing secret | Mac memory only, ≤ 120 s | Single use; proven via HMAC, never sent |
| Trusted device list | Mac (Keychain + app support file), Android (DataStore + Keystore) | Revocable; integrity via OS sandbox |
| AI provider API keys | Mac Keychain only | Never sent to Android, never in logs, URLs, argv or crash reports |
| Coding-agent credentials | Owned by the official CLI (Claude Code / Codex) | MyBuddy never reads, copies or parses them; only runs the official status command and keeps the boolean result |
| Screen content, input, files, clipboard | In transit only | MBH1 / WebRTC DTLS-SRTP; no server storage |
| Health history, activity log, chat history | Local only | Configurable retention, "Delete local history" |
| Connect bearer tokens | Device memory; server stores SHA-256 only | 15 min lifetime; bound to device key via challenge signature |
| TURN shared secret | Server secret file (`MYBUDDY_TURN_SECRET_FILE` / coturn config), never in argv or the repo | Short-lived HMAC credentials issued per device |

## 3. Adversaries and threats

| # | Threat | Mitigation | Status |
|---|---|---|---|
| T1 | **Stolen/lost phone** used to control the Mac | Host must approve each new pairing; sessions require trusted key **and** (configurable) host confirmation; revoke from Mac in one click; Android key requires device unlock (`setUserAuthenticationRequired` optional) | Revocation + trust store implemented and tested (Mac); phone key in Android Keystore (StrongBox → TEE fallback; the emulator reports software); user-auth-bound key not implemented yet |
| T2 | **Malicious device on the LAN** connects to the host listener | Pair-mode accepted only while the pairing window is open; HMAC proof of the QR secret; resume-mode requires a trusted key signature; 4 concurrent handshakes max; per-window attempt limit | MBH1 implemented + tested (Swift/Kotlin/Go vectors, live emulator ↔ Mac host); pairing QR may only name LAN addresses (enforced identically on Mac and phone) |
| T3 | **MITM on LAN or relay** | Phone pins host key fingerprint from the QR; host verifies client key; transcript-bound signatures; SAS code comparison during pairing | Implemented in MBH1 |
| T4 | **Session replay / reordering** | Fresh ephemerals per session; strict per-direction frame counters; envelope `sequence` strictly increasing; nonces in auth challenges single-use | Implemented + tested |
| T5 | **Compromised Connect service** | It only relays signed WebRTC rendezvous messages (offer/answer signed by the device keys over `MBC1/rtc`, ±2 min, replay guard), so it can't swap DTLS fingerprints; the session itself is MBH1 inside the data channel with both keys pinned again; cannot pair (pairing needs the QR on the LAN + approval; pair mode is refused over the internet) or register a pairing alone (both device signatures required); no file bytes ever go through it or its TURN relay (relayed sessions turn transfers off); worst case = denial of service and metadata (who talks to whom, when, IPs) | Implemented + tested: Go signature checks; Swift/Kotlin statement vectors and tamper/stale/wrong-key tests; emulator E2E incl. forced TURN and revocation |
| T22 | **Internet exposure of the Mac** | Off by default; the Mac answers only signed offers from phones it trusts and hasn't revoked, only while *Allow connections over the internet* is on (turning it off ends internet sessions at once); phones enrol only after the user agrees on the phone; the Mac never opens a listening port to the internet (WebRTC/ICE only, outbound to the server); TURN credentials are per device, HMAC-derived, expiring (default 12 h; coturn quotas and denied private peer ranges); the server address must be `https://` (plain http only on loopback, and on the emulator in debug builds) | Implemented + tested (adopt/refusal unit tests; emulator E2E against a local server + dev relay); not yet against a public deployment (I1–I4) |
| T6 | **Malicious file paths** (`../`, absolute, symlink escape, NUL) | `PathGuard`: lexical validation + realpath containment + re-check at open; transfer names sanitized; temp file + atomic rename | Implemented + tested (Swift); Kotlin `FileNameRules` + `TransferCoreTest`; `file.request` resolved through the same guard (emulator E2E session 4) |
| T7 | **Unsafe AI-generated tool calls** | Models can only propose typed tools; MyBuddy policy classifies risk; medium/high risk require explicit approval; no shell tool; coding agents run in a user-selected workspace with their own sandbox/approval modes (read-only by default) | Implemented for voice intents and agent launch policy |
| T8 | **Provider key leak** | Keychain storage; `ProviderConfig` holds only a `SecretReference`; `Redactor` scrubs `sk-…`, bearer tokens, `x-api-key` from logs/errors; keys never in argv | Implemented + tested |
| T9 | **Accidental capture of sensitive content** | Streams start only when a phone holding `screen.view` asks; Screen Recording permission is checked first (never prompted remotely — the Mac user grants it with *Allow…*); the macOS picker can limit sharing to one window/app; the Mac shows a live preview of exactly what is sent, a "Live · *phone* is viewing" pill, Stop and Emergency Stop; macOS shows its own recording indicator; the phone stops receiving when it leaves the Remote tab or goes to the background; one viewer at a time; AI screen analysis is a separate capability, off by default; concealed clipboard types skipped | Streaming implemented: capture/permission/stop paths built; WebRTC pipeline E2E-tested (in-process loopback + Android emulator with a labelled test pattern); real ScreenCaptureKit capture and the picker not exercised here (Screen Recording is not granted to this test environment) — hardware checks H7/H8; clipboard rule implemented + tested |
| T10 | **SSRF / exfiltration via custom AI endpoints** | `EndpointValidator`: http(s) only; loopback default for Ollama; private/LAN hosts require explicit trust; public hosts require HTTPS + explicit trust; no redirects across hosts; Local-Only mode blocks all non-loopback AI traffic | Implemented + tested |
| T11 | **Ollama exposed publicly** | MyBuddy only talks to `127.0.0.1:11434` by default and warns if the configured host is not loopback; phone requests are proxied by the authenticated Mac host | Implemented |
| T12 | **Input injection while the user is away** | No unattended mode in v1; input requires active session indicator; Emergency Stop global shortcut + menu item; stuck-key cleanup on disconnect and when the input data channels close; the phone's Control mode is opt-in per stream (every stream starts in View mode) | Emergency stop implemented + E2E-tested over LAN; stuck-key cleanup built (release on channel close covered by a live test), hardware check H9 pending |
| T19 | **Forged or replayed input over WebRTC data channels** | Only Mac-created channels are used; every message passes `DataChannelInputGate` (envelope schema, input types only and only on their own channel, session id, per-channel increasing sequence, rate limits) and a per-message `input.control` grant check; DTLS is bound to the MBH1 session through the SDP fingerprints | Implemented + tested (Swift gate unit tests; live loopback test: valid input delivered, wrong channel / non-input / revoked grant refused, release on stop; emulator E2E with a log-only host) |
| T20 | **Hostile or broken file transfers** (oversized/garbled offers, corrupted chunks, files that pose as harmless, partial files left behind) | Offers validated (name rules, 2 GiB cap, chunk size 16–64 KiB, hex digest); nothing is written until the user accepts (only the phone's own `file.request` is auto-accepted, by `requestId`); strict in-order chunks of exact length; SHA-256 must match before a file becomes visible (Mac temp file + atomic no-overwrite rename; Android pending MediaStore entry); received Mac files carry the quarantine attribute so Gatekeeper checks them on first open; partial files deleted on failure/cancel/session end; 2 transfers per session, 60 s stall / 5 min acceptance timeouts | Implemented + tested (Swift `TransferServiceTests`, Kotlin `TransferCoreTest`; emulator E2E incl. cancel cleanup on both sides) |
| T21 | **Clipboard leaks** (secrets synced automatically, ping-pong loops, clipboard text in logs) | Off / Ask / Automatic per device; Automatic never applies text that looks like a private key, API token or Luhn-valid card number (asks instead, preview hidden; Android marks it `EXTRA_IS_SENSITIVE`); concealed/transient Mac pasteboard items never offered; content hash checked against the offer; loop guard never re-offers text just received; the phone reads its clipboard only on an explicit tap; logs hold lengths, never text | Implemented + tested (Swift + Kotlin rules, emulator E2E of all modes against a log-only fake clipboard) |
| T23 | **Notification content leaking** (messages, one-time codes, previews on a shared Mac screen) | Three separate yeses: Android notification access (user-enabled in system settings — never by the app), the phone's master switch (off by default) and the Mac's per-device "Mirror notifications"; preview default *app name only*; one-time codes, keys and card numbers masked even with full previews; ongoing/silent/group-summary/MyBuddy notifications never sent; per-app blocking; paused during Do Not Disturb; nothing queued while disconnected; the Mac keeps them in memory only (no disk, no activity-log content, never sent to an AI provider); ids are salted hashes, not Android keys; macOS banners only if the user turns them on | Implemented + tested (Kotlin `NotificationRulesTest`; emulator E2E against a log-only host: preview levels, masking, removal, DND, app filter, background delivery, no echo of MyBuddy's own notifications) |
| T13 | **Resource exhaustion** | Size limits per channel, rate limits, transfer concurrency caps, bounded buffers, handshake timeouts, server token buckets | Limits implemented in codecs/server |
| T14 | **Coding agent escapes workspace** | Agent launched with `cwd` = approved workspace; Claude Code `--permission-mode plan` (read-only) or Codex `--sandbox read-only` by default; elevated modes need explicit approval per task; never `--dangerously-skip-permissions` / `--dangerously-bypass-approvals-and-sandbox` (enforced by an argument denylist + test) | Implemented + tested |
| T15 | **Secrets in diagnostics** | CLI auth status parsed to `loggedIn` + auth method only; e-mail/org fields discarded; Codex status line truncated before key fragment | Implemented + tested |
| T16 | **Tailscale route abused** (another tailnet device, a spoofed `ts.net` name, CGNAT confusion) | Tailnet membership grants nothing: MBH1 pairing/trust is still required and capabilities are per device; the Mac can refuse all tailnet connections (*Allow connections over Tailscale* off → refused before the handshake, live tailnet sessions closed); Tailscale counts as up only when traffic to the tailnet really leaves through the tunnel; MagicDNS names are resolved on the phone and must map only into `100.64.0.0/10` / `fd7a:115c:a1e0::/48` (blocks Funnel/public IPs); MyBuddy never uses Funnel/Serve; recommended tailnet access rule limits port 47811 to your devices | Implemented + tested (Swift `TailnetTests`, `TailscaleStatusTests`, live tailnet listener test that skips when Tailscale isn't routing; Kotlin `TailnetTest`); not exercised across two real tailnet devices yet (T1–T4 in TEST_PLAN) |
| T17 | **Bonjour spoofing** (a LAN device advertises `_mybuddy._tcp` with the right `fp` prefix) | Discovery only proposes an address; the MBH1 handshake pins the full host key, so a spoofer is rejected ("This isn't the Mac that showed the code"); discovered addresses must be local-network addresses | Implemented; matching unit-tested (`DiscoveryTest`); live discovery is a hardware check (the emulator's NAT blocks mDNS) |
| T18 | **Frame reordering across threads** (ICE callbacks vs. other senders) | Sealing (sequence assignment) and enqueueing a frame happen under one lock on both platforms, so wire order always equals sequence order — the receiver's replay guard would otherwise drop frames or close the session | Fixed this session (Mac `HostConnection.send`, Android `MacLink.sendRaw/request`) |

## 4. Capability model

`screen.view`, `input.control`, `apps.launch`, `files.browse`, `files.transfer`, `clipboard.sync`,
`notifications.mirror`, `voice.commands`, `ai.chat`, `ai.agent`, `ai.screen_analysis`, `health.read`.
(`unattended` exists in the enum only so it can be explicitly refused.)

* Grants are per trusted device, stored on the Mac, editable in Settings → Devices.
* Defaults for a newly paired phone: `screen.view`, `health.read`, `ai.chat`, `voice.commands`,
  `clipboard.sync` (mode *Ask every time*). `input.control`, `files.*`, `apps.launch`, `ai.agent` and
  `ai.screen_analysis` are **off until the user enables them** on the Mac.
* Risky actions (deleting files, agent write modes, installing packages, pushing code, opening
  non-allowlisted apps) require an approval card on the Mac **even if** the capability is granted.

## 5. Cryptography summary

* Identity: ECDSA P-256 / SHA-256 (Secure Enclave–compatible on Mac, StrongBox/TEE on Android).
* Key agreement: ephemeral ECDH P-256; HKDF-SHA256; AES-256-GCM with counter nonces and direction-bound AAD.
* Pairing proof: HMAC-SHA256 with a 256-bit single-use secret.
* Server auth: challenge–response signatures → short-lived opaque bearer tokens (hashed at rest).
* TURN: coturn REST API credentials (HMAC-SHA1 per coturn spec), 10-minute TTL.
* MBH1 is a SIGMA-style construction built from standard primitives. It is **not externally reviewed**.
  Before any public release it needs an independent review or replacement with Noise (`XX`/`IK`) via
  a vetted library. This is tracked as risk R3 in `MASTER_PLAN.md`.

## 6. Logging and telemetry

* No telemetry, analytics or crash upload. If ever added: opt-in, documented, scrubbed.
* `Redactor` is applied to every log line and every user-visible error that may contain upstream text.
* libwebrtc (M150, LiveKit build) writes info-level diagnostics to stderr regardless of the requested level
  (its one-time internal logging config ignores the legacy setter); lines include connection details with
  partly masked addresses. A Finder-launched app's stderr is not persisted; the interop host and tests send
  it to a separate file. Nothing is uploaded.
* Activity log stores event type, timestamp, device display name and a privacy-safe summary
  (e.g. "Opened Xcode", "Received report.pdf (2.1 MB)") — never clipboard text, file contents,
  transcripts or prompts. Retention default 30 days; one-click delete.

## 7. Platform permissions (never bypassed)

| Platform | Permission | Used for |
|---|---|---|
| macOS | Screen Recording (System Settings; requested only from *Remote Desktop → Allow…*) — or a one-off selection in the ScreenCaptureKit picker | Remote desktop stream |
| macOS | Accessibility | Injecting remote mouse/keyboard events |
| macOS | Microphone + Speech Recognition | MyBuddy Voice on Mac |
| macOS | Local Network | LAN listener / Bonjour |
| macOS | User-selected folders (security-scoped bookmarks) | File browser |
| macOS | Notifications (asked only when *Also show them as macOS notifications* is turned on) | Showing mirrored phone notifications as macOS banners |
| Android | Camera (runtime prompt) | Scanning the pairing QR |
| Android | Microphone (runtime prompt, foreground only, push-to-talk) | MyBuddy Voice |
| Android | INTERNET, ACCESS_NETWORK_STATE | LAN WebSocket to the Mac |
| Android | ACCESS_LOCAL_NETWORK (Android 17, required once targetSdk is 37; app targets 36 today) | LAN access to the Mac |
| Android | Notification listener (system settings — the user enables MyBuddy under notification access; sideloaded installs may need "Allow restricted settings") | Notification mirroring to the Mac (off by default) |
| Android | POST_NOTIFICATIONS (runtime prompt, asked in context — Files screen once a transfer exists, or Settings → Notifications for alerts from the Mac — never at launch) | Transfer progress notification; MyBuddy alerts from the Mac |
| Android | FOREGROUND_SERVICE + FOREGROUND_SERVICE_DATA_SYNC | Keeping a moving file transfer (and the link) alive in the background; started only from a user action, stopped when nothing moves |
| Android | Network Service Discovery (no permission needed at targetSdk 36) | Finding the paired Mac again after its IP changes (`_mybuddy._tcp`) |
| Android | Package visibility for `com.tailscale.ipn` (`<queries>`) | Showing whether Tailscale is installed; opening it |

## 8. Known limitations and open risks

* Ad-hoc–signed development builds of the Mac app lose TCC grants (Screen Recording, Accessibility)
  whenever the binary changes. Release builds need a Developer ID certificate + notarization.
* macOS does not allow capturing secure input fields, the login window, or FileVault pre-boot; MyBuddy
  cannot control a sleeping, powered-off, or logged-out Mac.
* Android may restrict background clipboard reads (Android 10+): the phone only reads the clipboard in
  the foreground or on explicit user action.
* Android freezes background apps within seconds and cuts their network; outside a moving transfer the phone's
  link to the Mac pauses ("Paused in the background") and resumes when MyBuddy is opened again.
* Metadata (device pairs, online times, IPs) is visible to the Connect operator and the TURN relay.
* A relayed internet session can't renew its TURN credentials inside the running allocation; it ends when they
  expire (default 12 h) and the phone reconnects automatically with fresh ones.
