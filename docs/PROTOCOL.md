# MyBuddy Protocol — v1

Status: **Draft v1, implemented in part** (see `IMPLEMENTATION_LOG.md` for what is verified).
Machine-readable sources of truth live in `protocol/`:

| File | Purpose |
|---|---|
| `protocol/schema/envelope.v1.schema.json` | JSON Schema for the common envelope |
| `protocol/schema/events.v1.json` | Event catalog: direction, channel, capability, payload limits |
| `protocol/fixtures/valid/*.json`, `protocol/fixtures/invalid/*.json` | Golden messages every implementation must accept / reject |
| `protocol/vectors/mbh1-v1.json` | Cross-language crypto test vectors for the MBH1 secure channel |
| `protocol/tools/vectorgen/` | Go program that generates the vectors deterministically |

Swift (`apps/macos`), Kotlin (`apps/android`) and Go (`services/connect-api`) tests all load these
files. A change to the protocol is not done until all three test suites pass against the same files.

---

## 1. Layers

```
L3  App events        Envelope v1 JSON (this document, §3–§5)
L2  Secure channel    MBH1: mutual-auth handshake + AES-256-GCM frames (§6)  — end-to-end, phone <-> Mac
L1  Transport         a) LAN WebSocket to the Mac host (Bonjour _mybuddy._tcp)
                      b) Internet: WSS to MyBuddy Connect /v1/signal — opaque relay of L2 frames (§7)
                      c) WebRTC (DTLS-SRTP media, SCTP data channels) — set up via L3 signaling events
```

* The Connect service **never** sees L3 plaintext. It authenticates devices, checks that a pairing
  exists, rate-limits and relays opaque ciphertext. A compromised Connect service can drop or delay
  traffic but cannot read it or impersonate a paired device (it lacks the device private keys and
  the MBH1 session keys).
* WebRTC DTLS fingerprints travel inside `webrtc.offer`/`webrtc.answer` SDP over the MBH1 channel,
  so media/data channels are bound to the authenticated session.
* Video is a WebRTC media track. **Screen frames are never sent as images over WebSocket.**

## 2. Encodings

* JSON is UTF-8, no BOM. Field names are `lowerCamelCase`.
* Binary values in JSON are **base64url without padding** (RFC 4648 §5), called `b64u` below.
* Times are RFC 3339 UTC strings with millisecond precision (`2026-10-16T08:30:00.123Z`).
* Identity public keys: ECDSA P-256 **SubjectPublicKeyInfo DER** (`b64u`, 91 bytes decoded).
* Signatures: ECDSA P-256 with SHA-256, **ASN.1 DER** encoded (what CryptoKit `derRepresentation`,
  Android `SHA256withECDSA` and Go `ecdsa.SignASN1` produce).
* Ephemeral key-agreement public keys: P-256 **X9.63 uncompressed point** (65 bytes, `0x04‖X‖Y`).
* `deviceId` = lowercase hex of the first 16 bytes of `SHA-256(identity SPKI DER)` (32 chars).
  A device ID is an identifier, **never** an authorization token.
* `fingerprint` = `b64u(SHA-256(identity SPKI DER))` (43 chars). Used to pin a key out of band (QR).

## 3. Envelope v1

```json
{
  "version": 1,
  "type": "input.pointer",
  "sessionId": "s_4hV9xq0b2cKfP7aR",
  "sequence": 1042,
  "sentAt": "2026-10-16T08:30:00.123Z",
  "replyTo": 1041,
  "payload": { "x": 0.52, "y": 0.38, "displayId": "1", "action": "move" }
}
```

| Field | Type | Rules |
|---|---|---|
| `version` | integer | Must be `1`. Anything else → `error{code:"unsupported_version"}`, message dropped. |
| `type` | string | Must be in the v1 catalog. Unknown → `error{code:"unknown_type"}`, **never executed**. |
| `sessionId` | string | `^[A-Za-z0-9_-]{8,64}$`. Must match the current MBH1 session's id. Not a secret. |
| `sequence` | integer | `1 … 2^53−1`, strictly increasing per sender per session. Non-increasing → dropped (`replayed_sequence`). |
| `sentAt` | string | RFC 3339 UTC. Informational only (latency stats); never used for authorization. |
| `replyTo` | integer? | Optional: `sequence` of the request this message answers. |
| `payload` | object | Validated against the type's schema. Unknown payload fields are ignored (forward-compatible); known fields are validated strictly (type, range, length, enum). |

Size limits (entire serialized envelope): **control 64 KiB, input 1 KiB, file 128 KiB, signaling 48 KiB.**
Oversized messages are rejected before JSON parsing.

Decoder error codes (shared by Swift and Kotlin, exercised by `protocol/fixtures/manifest.json`):
`too_large`, `malformed_json`, `invalid_envelope`, `unsupported_version`, `unknown_type`,
`wrong_direction` (e.g. a Mac receiving a Mac→phone type), `invalid_payload`, `replayed_sequence`.

### Compatibility rules

1. Breaking changes require `version: 2`; peers negotiate by both advertising `protocolVersions` in
   `session.request` / `session.approved` and picking the highest common value.
2. Within v1, only **additive** changes are allowed: new optional payload fields, new enum values on
   informational fields, new event types.
3. A sender may only send an event type that the peer listed in `features` during session setup
   (except the core types marked *core* in the catalog). This keeps old peers from receiving types they
   would reject.
4. Receivers reject unknown event types and unknown values of **privileged** enum fields
   (e.g. `input.button.action`). They ignore unknown fields.

## 4. Channels and back-pressure

| Channel | Transport (LAN v1) | Transport (WebRTC, Phase 3+) | Ordering | Use |
|---|---|---|---|---|
| `control` | MBH1 frames | stays on MBH1 (a `mb-control` data channel is not used) | ordered | session, app/file commands, clipboard, AI, voice, health |
| `input` | MBH1 frames | **built:** `mb-input` (unordered, `maxRetransmits: 0`) for `input.pointer` + `input.scroll`; `mb-input-rel` (reliable, ordered) for `input.button`, `input.key`, `input.text` | see note | pointer, buttons, keys, text |
| `file` | MBH1 frames | planned: `mb-file` (reliable, ordered, `bufferedAmountLowThreshold` back-pressure) | ordered | `file.chunk` only |
| `signaling` | MBH1 frames | — | ordered | `webrtc.*` |
| media | — | video track (H.264 preferred) | — | screen stream |

* Pointer moves are **coalesced** by the sender to at most one in flight per frame interval (~16 ms)
  and dropped (not queued) under back-pressure. Button/key/text events are never dropped.
* Input data channels exist only while a screen stream runs; the Mac creates both before its offer and
  closes any channel the phone opens. Each message is a complete v1 envelope (UTF-8 JSON) with the MBH1
  `sessionId` and a **per-channel** sequence starting at 1; the Mac checks it with `DataChannelInputGate`
  (schema, per-channel type allowlist, session id, strictly increasing sequence — so a late lossy pointer move
  is simply dropped — and the rate limits below), then re-checks `input.control` for that session on **every**
  message. The DTLS association is bound to the session by the fingerprints in the MBH1-protected SDP. When
  no channel is open the phone sends the same events over MBH1, which applies identical rules.
* File chunks use a sliding window (default 8 chunks un-acked) so a transfer cannot starve input.
* Every request that expects a reply has a timeout (default 10 s; AI streams use idle timeouts).
* On session end every in-flight transfer, AI request, voice intent and input state is cancelled; the
  host releases all pressed keys/buttons (`stuck-key cleanup`).

## 5. Event catalog (v1)

Direction: `P→M` phone to Mac, `M→P` Mac to phone, `↔` both. Capability = permission the session must
hold for the event to be accepted (checked on the **Mac host**, the action authority).

### 5.1 Pairing / session (core)

| Type | Dir | Payload |
|---|---|---|
| `pairing.request` | P→M | `deviceName` (1–64), `platform` (`android`\|`macos`), `appVersion` (1–32) |
| `pairing.approved` | M→P | `hostDeviceId`, `hostName` (1–64), `grantedCapabilities` [] |
| `pairing.rejected` | M→P | `reason`: `user_rejected`\|`expired`\|`invalid_proof`\|`rate_limited`\|`window_closed` |
| `session.request` | P→M | `requestedCapabilities` [], `protocolVersions` [int], `features` [string] |
| `session.approved` | M→P | `grantedCapabilities` [], `protocolVersion`, `features` [], `heartbeatIntervalMs` (1000–60000), `sharedFolders`? [{`rootId`, `name`}] (only when `files.browse` is granted; never a path), `agentWorkspaces`? [{`workspaceId`, `name`}] and `agents`? [{`kind`: `claude_code`\|`codex`, `ready`}] (only when `ai.agent` is granted; never a path) |
| `session.rejected` | M→P | `reason`: `not_trusted`\|`revoked`\|`busy`\|`user_rejected`\|`host_locked` |
| `session.closed` | ↔ | `reason`: `user`\|`emergency_stop`\|`revoked`\|`timeout`\|`error`\|`host_sleep`\|`app_quit` |
| `host.heartbeat` | ↔ | `probe` (1–64 chars), `reply` (bool) — RTT = time from probe to reply on the sender. Both sides probe every `heartbeatIntervalMs` and answer the other's `reply: false` probes, so each shows its own ping |
| `host.status` | M→P | `hostName`, `osVersion`, `appVersion`, `screenSharing`, `inputControl`, `activeCapabilities` [] |
| `error` | ↔ | `code` (snake_case 1–64), `message` (≤ 512), `retryable` (bool) |

#### Internet enrolment (core) — CONNECTIVITY §3

| Type | Dir | Payload |
|---|---|---|
| `connect.offer` | M→P | `serverUrl` (8–256; `https://host[:port]`), `hostDeviceId` (32), `createdAt` (RFC 3339) — the Mac has internet access on and offers it to this phone (once per session, only while online on the server) |
| `connect.enroll` | P→M | `clientDeviceId` (32), `createdAt` (from the offer), `clientSignature` (b64u DER ≤ 80 bytes over `MBC1/pairing` §7.2) — sent only after the user taps *Allow*, after the phone registered its key with the server |
| `connect.enrolled` | M→P | `pairingId` (≤ 64), `serverUrl` — reply after the Mac checked the signature, co-signed and registered the pairing (`POST /v1/pairings`); failures answer `error` (`connect_not_offered`, `bad_signature`, `connect_failed`) |

### 5.2 Screen streaming (capability `screen.view`)

Control (`control` channel) — added in v1 as new event types; a Mac that implements them lists `screen` in
`session.approved.features`, and a phone only offers *View screen* when it sees that feature.

| Type | Dir | Payload |
|---|---|---|
| `screen.start` | P→M | `quality`? (`auto`\|`high`\|`balanced`\|`low`, default `auto`), `displayId`? (≤ 32), `maxFps`? (5–60) |
| `screen.update` | P→M | same fields, all optional — change quality, display or frame-rate cap while live |
| `screen.stop` | P→M | `reason`? (`user`\|`background`\|`error`) |
| `screen.state` | M→P | `state` (`starting`\|`awaiting_selection`\|`live`\|`stopped`\|`failed`), `reason`? (snake_case ≤ 64: `not_authorized`, `busy`, `no_display`, `capture_failed`, `capture_stopped`, `connection_failed`, `negotiation_failed`, `stopped_on_mac`, `emergency_stop`, `quality_changed`, `user`, `background`, …), `message`? (≤ 300, human text for reasons the phone doesn't know), `quality`?, `tier`? (`high`\|`balanced`\|`low`), `displayId`?, `width`?/`height`? (2–8192), `fps`? (1–60), `source`? (`display`\|`window`\|`application`\|`test_pattern`), `displays`? [{`displayId`, `name` (≤ 64), `width`, `height`, `main`}] ≤ 16 |

Signaling (`signaling` channel):

| Type | Dir | Payload |
|---|---|---|
| `webrtc.offer` | M→P | `sdp` (≤ 32 KiB) — the Mac host is the offerer (it owns the media); also sent again for an ICE restart |
| `webrtc.answer` | P→M | `sdp` (≤ 32 KiB) |
| `webrtc.ice` | ↔ | `candidate` (≤ 1 KiB), `sdpMid` (≤ 32)?, `sdpMLineIndex` (0–15)?, or `endOfCandidates: true` |

Flow: `screen.start` → Mac checks the capability (host) and Screen Recording permission (or a selection made
in the macOS picker), replies `screen.state{starting}` (`replyTo` = the request) or `screen.state{failed}`
→ Mac starts capture, creates the peer connection (send-only video, H.264 preferred), sends `webrtc.offer`
and trickles `webrtc.ice` → phone answers (receive-only) and trickles its candidates; candidates that arrive
before the description they belong to are buffered (≤ 64) → when the Mac's peer connection connects it
sends `screen.state{live, width, height, fps, tier, displays…}` → quality/display changes are pushed as
`screen.state{live, reason: quality_changed}`. Recovery: after 6 s *disconnected* or on *failed*, the Mac
restarts ICE with a new offer (at most twice), then gives up with `screen.state{failed, connection_failed}`.
`screen.stop`, `session.closed`, revocation or Emergency Stop end the stream; the Mac reports stops it
initiates (`stopped_on_mac`, `emergency_stop`). One stream at a time: a second phone gets `busy`.

Rules: the phone never sends media; the Mac never streams to a session that lacks `screen.view`; frames
never travel over WebSocket; the DTLS fingerprints inside the MBH1-protected SDP bind the media to the
authenticated session. Telemetry shown on both sides comes from `getStats()` (`outbound-rtp` /
`inbound-rtp`, the selected candidate pair, codec), never from estimates.

### 5.3 Input (`input` channel, capability `input.control`)

Coordinates are **normalized to the streamed frame** (`0.0 … 1.0`, top-left origin, after rotation is
undone by the phone). The host maps them to the global coordinate space of the display **being streamed to
that session** (the main display when it isn't viewing), clamped inside it. While a single window or app is
shared through the macOS picker, input is refused with `error{window_share_no_input}`. The phone's direct-touch
mode maps a tap through its fit/fill layout and zoom/pan transform (`VideoGeometry`); touches on letterbox bars
send nothing.

| Type | Dir | Payload |
|---|---|---|
| `input.pointer` | P→M | `x`,`y` ∈ [0,1], `displayId` (1–32), `action`: `move` |
| `input.button` | P→M | `button`: `left`\|`right`\|`middle`, `action`: `down`\|`up`\|`click`\|`doubleClick`, `x`,`y` ∈ [0,1], `displayId` |
| `input.scroll` | P→M | `dx`,`dy` ∈ [−2000, 2000], `unit`: `pixel`\|`line` |
| `input.key` | P→M | `code` (W3C `KeyboardEvent.code` from the allowlist in `events.v1.json`), `action`: `down`\|`up`\|`press`, `modifiers` ⊆ {`shift`,`control`,`option`,`command`} |
| `input.text` | P→M | `text` (1–256 Unicode scalars, no control characters except `\n`, `\t`) |

Host-side limits: 240 pointer events/s, 60 button/key events/s, 20 text events/s per session; excess
is dropped and audited once per second. Input is accepted only while `input.control` is granted **and**
the host shows the active-session indicator.

### 5.4 Apps and files

| Type | Dir | Capability | Payload |
|---|---|---|---|
| `host.app.list` | P→M | `apps.launch` | request: `query` (≤ 100)?, `limit` (1–200) |
| `host.app.list` | M→P | `apps.launch` | result: `apps` [{`bundleId`, `name`, `isRunning`}] |
| `host.app.open` | P→M | `apps.launch` | request: `bundleId` (reverse-DNS, ≤ 255) |
| `host.app.open` | M→P | `apps.launch` | result: `bundleId`, `status`: `opened`\|`not_found`\|`denied`\|`failed` |
| `host.file.list` | P→M | `files.browse` | request: `rootId`, `path` (relative, ≤ 1024) |
| `host.file.list` | M→P | `files.browse` | result: `rootId`, `path`, `entries` [{`name`, `kind`: `file`\|`folder`, `size`?, `modifiedAt`?}] |
| `host.file.open` | P→M | `files.browse` | request: `rootId`, `path` |
| `host.file.open` | M→P | `files.browse` | result: `rootId`, `path`, `status`: `opened`\|`not_found`\|`denied`\|`failed` |

`rootId` refers to a folder the user granted on the Mac. Paths are resolved by the host with
containment checks (§8). Absolute paths, `..` segments, NUL bytes and symlink escapes are rejected with
`error{code:"path_denied"}`.

### 5.5 File transfer (capability `files.transfer`)

Either side can send. The phone can also ask for a file inside a shared folder (needs `files.browse` too).

| Type | Dir | Payload |
|---|---|---|
| `file.request` | P→M | `requestId` (uuid), `rootId` (1–64), `path` (1–1024, no NUL) — "send me this shared file"; resolved with §8 containment, refused with `error{code:"path_denied"}` |
| `file.offer` | sender→receiver | `transferId` (uuid), `name` (1–255, no `/`, `\`, NUL), `size` (1 … 2 GiB), `sha256` (hex 64), `chunkSize` (16 KiB … 64 KiB), `mimeType`?, `requestId`? (echo of the `file.request` it answers) |
| `file.start` | receiver→sender | `transferId`, `fromChunk` (resume index, default 0) — sent only **after the user accepts** (or for an offer that echoes the receiver's own `requestId`) |
| `file.chunk` | sender→receiver | `transferId`, `index`, `data` (b64u, decoded length = `chunkSize` except last) |
| `file.ack` | receiver→sender | `transferId`, `index` (highest contiguous index written) |
| `file.pause` / `file.resume` | ↔ | `transferId` |
| `file.cancel` | ↔ | `transferId`, `reason`? |
| `file.complete` | receiver→sender | `transferId`, `sha256` (receiver-computed; must equal offer) |
| `file.error` | ↔ | `transferId`, `code`: `checksum_mismatch`\|`too_large`\|`disk_full`\|`denied`\|`timeout`\|`invalid_chunk`\|`cancelled` |

Flow: offer → (user accepts) `file.start` → chunks, each acknowledged → `file.complete` with the
receiver's digest. The sender keeps at most **8 un-acknowledged chunks** in flight (`SendWindow`, same
rule on both platforms); chunks are written strictly in order, duplicates of written chunks are ignored,
anything else out of order or of the wrong length fails the transfer (`invalid_chunk`).

- **Declining** is `file.error{code:"denied"}` before `file.start`; the sender shows "Declined".
- **Receivers** never expose partial data: the Mac writes `.mybuddy-<transferId>.part` in the destination
  (default `~/Downloads`), verifies SHA-256, renames atomically without overwriting (`name 2.ext`) and tags
  the file with the macOS quarantine attribute (agent "MyBuddy") so Gatekeeper treats it as a download.
  Android writes a *pending* MediaStore entry in `Downloads/MyBuddy` (invisible to other apps) and
  publishes it only after the checksum matches. Failure, cancel or session end deletes the partial file.
- **Mac policy**: "ask" (default — Accept/Decline in Files & Clipboard) or "save automatically".
  Android always asks for unsolicited offers; offers answering its own `file.request` start at once.
- **Timeouts**: an offer nobody answers expires after 5 minutes; a running transfer with no progress for
  60 s fails with `timeout` (a paused one doesn't). Session end stops every transfer of that session.
- **Limits**: 2 concurrent transfers per session, 2 GiB per file (configurable lower).
- **Android in the background**: Android freezes background apps and cuts their network within seconds,
  so while a transfer is moving the phone runs a `dataSync` foreground service with a progress
  notification; a file picked in the system picker waits up to 30 s for the link to come back.

File bytes travel only inside the end-to-end encrypted MBH1 session over a **direct** path — Wi-Fi,
Tailscale, or a direct (STUN) WebRTC connection. **No file bytes pass through a server**: when an
internet session is relayed through TURN, both apps turn file transfer off for that session and say why.

### 5.6 Clipboard (capability `clipboard.sync`)

| Type | Dir | Payload |
|---|---|---|
| `clipboard.offer` | ↔ | `revisionId` (uuid), `originDeviceId`, `contentHash` (sha256 hex of UTF-8 text), `size` (≤ 65536), `mime`: `text/plain` |
| `clipboard.request` | ↔ | `revisionId` |
| `clipboard.content` | ↔ | `revisionId`, `text` (≤ 64 KiB UTF-8; hash must match the offer) |
| `clipboard.applied` | ↔ | `revisionId` |
| `clipboard.paused` | ↔ | `paused` (bool) |

Loop prevention: a device never re-offers a revision whose `contentHash` it just applied from a peer
(see `ClipboardLoopGuard`). Concealed/transient pasteboard items (password managers) are never offered.

### 5.7 AI (capabilities `ai.chat`, `ai.agent`)

| Type | Dir | Payload |
|---|---|---|
| `ai.provider.status` | M→P | `mode`: `chat`\|`agent`, `providerId`, `providerKind`, `displayName`, `modelId`?, `privacyLabel`, `localOnly`, `availability`: `available`\|`unavailable`\|`not_configured`\|`not_authorized`, `detail`? |
| `ai.request` | P→M | `requestId` (uuid), `mode`, `messages` [{`role`: `user`\|`assistant`, `text`}] (total ≤ 32 KiB), `contextSources` [], `agent`? {`kind`: `claude_code`\|`codex`, `workspaceId`, `level`: `read_only`\|`edit_workspace`} (mode `agent`) |
| `ai.delta` | M→P | `requestId`, `text` |
| `ai.complete` | M→P | `requestId`, `stopReason`, `servedBy` (model id that actually answered), `usage`? {`inputTokens`,`outputTokens`} |
| `ai.error` | M→P | `requestId`, `code`, `message`, `retryable` |
| `ai.tool.proposed` | M→P | `requestId`, `toolCallId`, `tool`, `summary`, `risk`: `low`\|`medium`\|`high`, `argumentsRedacted` |
| `ai.tool.approval` | P→M | `requestId`, `toolCallId`, `decision`: `approve`\|`deny` |
| `ai.tool.result` | M→P | `requestId`, `toolCallId`, `status`: `succeeded`\|`failed`\|`denied`, `summary` |
| `ai.cancel` | P→M | `requestId` |

The phone never receives provider API keys. Requests run on the Mac host with the Mac's configured
provider; the phone UI must say so ("Runs on your Mac via <provider>").

**Coding agents from the phone (mode `agent`, also needs `ai.agent`).** The phone names an agent, one of the
folders the Mac's user shared for agents (`workspaceId` from `session.approved`; the phone never sends or sees a
path) and a level. The Mac runs the agent's official CLI exactly as for a Mac-started task (same flags: Claude Code
`--permission-mode plan|acceptEdits --restricted`, Codex `--sandbox read-only|workspace-write`; never a "skip
permissions" mode). `read_only` starts at once; `edit_workspace` shows an approval sheet on the Mac and nothing runs
until its user allows it (declined after 2 minutes). The reply is `ai.provider.status` (mode `agent`, `detail` while
waiting for approval); the agent's events stream back as `ai.delta` lines (home paths shortened, secret-looking
tokens redacted), then `ai.complete` (`servedBy` = the agent). `ai.cancel` stops the run. One agent runs at a time.

### 5.8 Voice (capability `voice.commands`)

| Type | Dir | Payload |
|---|---|---|
| `voice.started` | P→M | `utteranceId` (uuid), `source`: `phone`\|`mac` |
| `voice.transcript` | P→M | `utteranceId`, `text` (≤ 2000), `isFinal`, `locale` |
| `voice.intent.proposed` | M→P | `utteranceId`, `intentId`, `intent` (typed, see `VoiceIntent` in `events.v1.json`), `requiresApproval`, `risk` |
| `voice.intent.approved` | P→M | `utteranceId`, `intentId`, `decision`: `approve`\|`deny` |
| `voice.intent.result` | M→P | `utteranceId`, `intentId`, `status`: `succeeded`\|`failed`\|`denied`\|`needs_permission`, `spokenSummary` (≤ 500) |
| `voice.cancelled` | ↔ | `utteranceId` |

### 5.9 Health (capability `health.read`)

| Type | Dir | Payload |
|---|---|---|
| `health.snapshot.request` | P→M | `sections`? ⊆ {`battery`,`storage`,`memory`,`cpu`,`thermal`,`system`,`network`,`host`} |
| `health.snapshot.result` | M→P | `snapshot`: `HealthSnapshot` (schemaVersion 1; every metric carries `status`, `source`, `collectedAt`) |
| `health.report.exported` | M→P | `format`: `json`\|`markdown`, `redacted` (bool), `exportedAt` |

### 5.10 Notifications (capability `notifications.mirror`)

| Type | Dir | Payload |
|---|---|---|
| `notification.posted` | ↔ | `notificationId` (opaque, 1–128), `appPackage` (1–255), `appLabel` (1–128), `title`? (≤ 256), `text`? (≤ 1024), `postedAt`, `redaction`: `none`\|`partial`\|`title_only`\|`content_hidden`, `category`? (≤ 32) |
| `notification.removed` | ↔ | `notificationId` |

**Phone → Mac (mirroring).** From Android's `NotificationListenerService`, which the user enables in system
settings; the phone also has its own master switch (off by default), per-app filters and a preview policy:
*Hidden* (app name only → `content_hidden`, no title/text), *Title only* (`title_only`), *Title and text*
(`none`, or `partial` when the phone masked something that looks like a one-time code, key or card number).
Ongoing, silent-group-summary and MyBuddy's own notifications are never sent; nothing is sent while the phone is
in Do Not Disturb (default) or not connected — notifications are never queued or stored for later. The
`notificationId` is a salted hash, not Android's key.

**Mac → phone.** Only MyBuddy's own alerts (battery low, the Mac going to sleep): macOS has no public API to
read other apps' notifications, so MyBuddy doesn't claim to mirror them.

Notifications are never sent to an AI provider.

### 5.11 Shared notes (capability `notes.sync`)

| Type | Dir | Payload |
|---|---|---|
| `notes.index` | ↔ | `notes` [{`id` (uuid), `updatedAt`, `deleted`}] (≤ 500, newest first) |
| `notes.put` | ↔ | `id` (uuid), `text` (≤ 24 KiB UTF-8), `updatedAt` (ISO-8601 UTC, milliseconds), `deleted` (bool) |

Notes live on the Mac (`Application Support/MyBuddy/notes.json`) and the phone (app storage) only — never on a
server. At session start both sides send `notes.index`; each answers with `notes.put` for every live note the other
lacks and every note newer on its side. Local edits go out as `notes.put` after a short pause. Merge is
last-writer-wins: newer `updatedAt` wins; at the same instant a deletion wins, then the larger text by UTF-8 bytes
(so both sides keep the same copy); a device whose copy wins sends it back. An edit's time is
`max(now, previous + 1 ms)`, so editing a note always beats the version it replaced even when the other device's
clock runs ahead. A deletion is a tombstone (empty text) kept 30 days. Shared vectors:
`protocol/vectors/notes-merge-v1.json` (both test suites). Note text is never logged.

## 6. MBH1 secure channel

Purpose: mutual authentication between a phone and a Mac, forward-secret session keys, and
pairing-secret proof — over any reliable ordered byte transport (LAN WebSocket or the Connect relay).

### 6.1 Pairing QR

The Mac shows a QR code only while the user has the pairing window open (default 120 s, single use):

```
mybuddy://pair?v=1&h=<host:port>[,<host:port>…]&fp=<host identity fingerprint>&s=<pairing secret b64u, 32 bytes>&x=<expiry unix seconds>&n=<display name, url-encoded, ≤ 32>
```

The secret is generated with a CSPRNG, kept only in memory on the Mac, and invalidated after one
successful proof, after 5 failed proofs, on expiry, or when the window closes (`PairingWindow`). A
failed proof reveals nothing about the 256-bit secret (it is an HMAC over a fresh transcript), so a few
retries are allowed for flaky networks. The phone pins `fp`.

`h` lists only local-network addresses: loopback, RFC 1918, CGNAT `100.64/10` (Tailscale), link-local
`169.254/16` and `fe80::/10`, IPv6 ULA `fc00::/7`, or `.local` names. The Mac advertises nothing else,
and the phone rejects an invitation containing any other address (Swift `EndpointValidator.classify`,
Kotlin `PairingInvitation.isLanHost` — same rules, same tests). The Mac orders `h` best first: the
default-route interface, other `en*`, then bridges; with *Allow connections over Tailscale* on and
Tailscale actually routing, its tailnet IPv4 is appended (still within the 4-address limit). Reaching a Mac
from outside the LAN is the job of Tailscale (`CONNECTIVITY.md` §2) or MyBuddy Connect (§7), never a public
address in a QR code.

Other address sources on the phone (`CONNECTIVITY.md` §5): Bonjour discovery (`_mybuddy._tcp`, TXT
`v=1`, `fp` = first 8 characters of the host fingerprint; candidate only — the handshake pins the full key)
and *Add Tailscale address* (tailnet literals `100.64.0.0/10` / `fd7a:115c:a1e0::/48`, or a `*.ts.net`
MagicDNS name that must resolve only into those ranges; the resolved IP is dialled). The phone dials Wi-Fi
addresses first and starts each next candidate 600 ms later (Tailscale last); the first to complete the
WebSocket upgrade wins and the others are closed.

### 6.2 Handshake messages (JSON text frames)

```
1. P→M  {"type":"hs.hello","protocol":1,"mode":"pair"|"resume","clientEphemeral":b64u(65),"clientNonce":b64u(32)}
2. M→P  {"type":"hs.host","hostEphemeral":b64u(65),"hostNonce":b64u(32),"hostIdentityKey":b64u(SPKI),"signature":b64u(DER)}
3. P→M  {"type":"hs.client","clientIdentityKey":b64u(SPKI),"clientName":str,"platform":str,"signature":b64u(DER),"pairingProof":b64u(32)?}
```

`lp(x)` = 4-byte big-endian length ‖ bytes. Labels are ASCII.

```
TH1        = SHA256("MBH1/th1" ‖ lp(mode) ‖ lp(clientEphemeral) ‖ lp(clientNonce) ‖ lp(hostEphemeral) ‖ lp(hostNonce) ‖ lp(hostIdentityKey))
hostSig    = ECDSA-P256-SHA256(hostIdentityPriv,  "MBH1/host-sig"   ‖ TH1)
TH2        = SHA256("MBH1/th2" ‖ TH1 ‖ lp(clientIdentityKey) ‖ lp(utf8(clientName)) ‖ lp(utf8(platform)))
clientSig  = ECDSA-P256-SHA256(clientIdentityPriv, "MBH1/client-sig" ‖ TH2)
proof      = HMAC-SHA256(key = pairingSecret, "MBH1/pair-proof" ‖ TH2)          (pair mode only)
shared     = ECDH-P256(ephemeral private, peer ephemeral public)                   (32-byte x-coordinate)
okm        = HKDF-SHA256(ikm = shared, salt = TH2, info = "MBH1/keys", L = 64)
keyC2H     = okm[0..32), keyH2C = okm[32..64)
sas        = HKDF-SHA256(ikm = shared, salt = TH2, info = "MBH1/sas",  L = 4) → u32be mod 1 000 000 → 6 digits, zero-padded
sessionId  = "s_" ‖ b64u(HKDF-SHA256(ikm = shared, salt = TH2, info = "MBH1/session-id", L = 12))
```

Verification:
* Phone: `b64u(SHA256(hostIdentityKey)) == pinned fingerprint` (QR for pair mode, trust store for
  resume) **and** `hostSig` verifies. Otherwise abort, show "This isn't your Mac".
* Mac (pair mode): pairing window open and unexpired; `proof` matches the current secret (constant-time
  compare); `clientSig` verifies. Then the Mac shows an approval sheet with the phone's name, platform
  and the 6-digit `sas`; the phone shows the same code. Only an explicit user "Approve" trusts the key.
* Mac (resume mode): `clientIdentityKey` is in the trust store, not revoked; `clientSig` verifies.

### 6.3 Frames

After message 3 both sides switch to binary frames:

```
frame      = counter (u64 big-endian, 8 bytes) ‖ AES-256-GCM(key, nonce, aad, plaintext) (ciphertext ‖ 16-byte tag)
nonce      = 0x00000000 ‖ counter (8 bytes)                          — 12 bytes
aad        = "MBH1/frame" ‖ direction (0x01 phone→Mac, 0x02 Mac→phone) ‖ counter (8 bytes)
plaintext  = UTF-8 Envelope v1 JSON
```

Counters start at 0 per direction and must be exactly the next expected value (the transport is
reliable and ordered); any gap, replay, or authentication failure closes the session. Max frame 192 KiB.
Keys are never reused across sessions (fresh ephemerals per handshake). Handshake timeout 10 s; the Mac
allows at most 4 concurrent handshakes and rate-limits pair-mode attempts (5 per window).

## 7. MyBuddy Connect service API (Go)

Base: `https://<your-domain>` behind a TLS reverse proxy. The service listens on loopback by default.

### 7.1 Device authentication

| Method & path | Auth | Body → Response |
|---|---|---|
| `POST /v1/devices` | none (proof of key) | `{publicKey, platform, proof}` → `201 {deviceId}`; `proof` = DER sig over `"MBC1/register" ‖ lp(publicKey DER) ‖ lp(platform)` |
| `POST /v1/auth/challenge` | none | `{deviceId}` → `{challengeId, nonce, expiresAt}` (60 s, single use) |
| `POST /v1/auth/token` | none | `{challengeId, deviceId, signature}` → `{token, expiresAt}` (15 min); sig over `"MBC1/auth" ‖ lp(challengeId) ‖ lp(nonce bytes) ‖ lp(deviceId)` |
| `GET /v1/me` | bearer | → `{deviceId, platform, pairings:[…]}` |

Tokens are 32 random bytes (`b64u`), stored only as SHA-256 hashes, sent as `Authorization: Bearer`.

### 7.2 Pairing registry

| Method & path | Auth | Body → Response |
|---|---|---|
| `POST /v1/pairings` | bearer (host) | `{hostDeviceId, clientDeviceId, createdAt, hostSignature, clientSignature}` → `201 {pairingId}`. Both sign `"MBC1/pairing" ‖ lp(hostDeviceId) ‖ lp(clientDeviceId) ‖ lp(createdAt)`. The caller must be the host. Both devices must be registered. |
| `GET /v1/pairings` | bearer | → `{pairings:[{pairingId, hostDeviceId, clientDeviceId, createdAt, revokedAt?}]}` |
| `DELETE /v1/pairings/{id}` | bearer (either party) | → `204`; peers are notified (`pairing.revoked`) and relay is cut immediately |

Pairing itself happens **on the LAN** with the QR + MBH1 + host approval. Registering it with Connect
(after both devices consent) only enables internet relay and TURN credentials.

### 7.3 Signaling relay — `GET /v1/signal` (WebSocket, bearer)

Outer messages (JSON text, ≤ 96 KiB, allowlist enforced server-side):

| Client → service | Service → client |
|---|---|
| `{"type":"relay","to":deviceId,"id":msgId,"data":b64u}` | `{"type":"relay","from":deviceId,"id":msgId,"data":b64u}` |
| `{"type":"presence"}` | `{"type":"presence","peers":[{"deviceId","online"}]}` |
| `{"type":"ping"}` | `{"type":"pong"}` |
| — | `{"type":"pairing.revoked","pairingId","peerDeviceId"}` |
| — | `{"type":"error","code","message"}` |

Relay is allowed only between devices with an active, non-revoked pairing. 50 messages/s token bucket per
connection; 3 protocol violations close the socket. Unknown outer types are rejected. The server never parses
`data`. The apps put exactly one thing in it — a **rendezvous message** (base64url of UTF-8 JSON, ≤ 60 KiB) that
introduces a WebRTC connection:

| Field | Meaning |
|---|---|
| `v` | 1 |
| `kind` | `offer` (phone → Mac) · `answer` (Mac → phone) · `ice` (both) · `bye` (both) |
| `rid` | rendezvous id, `r_` + 8–64 base64url chars, chosen by the phone per attempt |
| `from`, `to` | device ids (32 hex) — must match the relay's `from` and the receiver |
| `at`, `sdp`, `sig` | offer/answer only: RFC 3339 time, SDP (≤ 32 KiB), DER signature by the sender's device key over `MBC1/rtc ‖ lp(kind) ‖ lp(rid) ‖ lp(from) ‖ lp(to) ‖ lp(at) ‖ lp(sdp)` (vectors: `connect.rtc*`) |
| `candidate`, `sdpMid`, `sdpMLineIndex` | ice only (unsigned; bound to `rid`) |
| `reason` | bye only (≤ 64) |

Rules: the Mac answers only offers whose `from` is a trusted, non-revoked phone, whose signature verifies with
that phone's key, whose `at` is within ±2 minutes, and whose `(from, rid)` it hasn't seen (replay guard), and
only while *Allow connections over the internet* is on. The phone accepts only an answer signed by the Mac key
it pinned at pairing. Signed SDPs mean a compromised server can't substitute DTLS fingerprints.

After ICE connects, the phone's reliable, ordered data channel **`mb-session`** carries the usual MBH1 resume
handshake (text messages) and frames (binary) — exactly what the LAN WebSocket carries. Pair-mode handshakes are
refused on internet transports (pairing needs the QR on the local network). Both apps read the selected ICE
candidate pair: a `relay` candidate on either end makes the session *relayed* (file transfer then off, §5.5).
Screen video uses its own peer connection, negotiated inside MBH1 (§5.2), with the same STUN/TURN servers.

### 7.4 TURN credentials

`GET /v1/turn-credentials` (bearer, device must have ≥ 1 active pairing) →
`{urls:[…], username:"<expiry>:<deviceId>", credential:"<b64 HMAC-SHA1>", ttlSeconds}` following the
coturn `use-auth-secret` REST convention. The shared secret never leaves the server. TTL default 12 h
(`MYBUDDY_TURN_TTL_SECONDS`, 60 s – 24 h): coturn checks the expiry on every allocation refresh, so a relayed
session ends when its credentials do and the apps reconnect with fresh ones. Shorter TTLs bound how long a
leaked credential can use the relay (coturn's `user-quota`/`max-bps` limit it meanwhile).

### 7.5 Errors

JSON `{ "error": { "code": "snake_case", "message": "…" } }` with conventional HTTP status codes.
Messages never echo tokens, signatures or keys.

### 7.6 Health

`GET /healthz` → `{"status":"ok"}`; `GET /readyz` → `200` when the store is reachable.

## 8. Path containment (files)

Host resolves `(rootId, relativePath)` as: reject absolute paths, empty segments, `.`/`..`, NUL, and
paths longer than 1024 bytes → join with the granted root → resolve symlinks (`realpath`) → require the
resolved path to equal the resolved root or start with `resolvedRoot + "/"`. The check is repeated at
open time (TOCTOU-minimizing; open uses the resolved URL).
