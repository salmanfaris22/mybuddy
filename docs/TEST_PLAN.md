# MyBuddy Test Plan

Rule: failing tests are never skipped or weakened to get a green build. Tests that need hardware or
a missing tool are marked **"not run — requires …"** with exact manual steps.

## 1. Commands

| Area | Command (from repo root) | Notes |
|---|---|---|
| Everything available | `make test` | Protocol check + Go + Swift + Android unit tests |
| Protocol | `make protocol-check` | MBH1 vectors regenerate byte-identically; fixtures regenerate unchanged |
| Mac unit/integration | `make test-mac` (`apps/macos/MyBuddyMac/scripts/test.sh`) | Swift Testing via CLT flags; Keychain tests need an unlocked login session |
| Mac build + bundle | `make build-mac-app` | `apps/macos/MyBuddyMac/build/MyBuddy.app` (release, ad-hoc signed) |
| Mac UI snapshots | `apps/macos/MyBuddyMac/build/MyBuddy.app/Contents/MacOS/MyBuddy --snapshot <dir>` | Renders 13 screens in Preview mode to PNG (offscreen, no permissions, no listener), incl. Settings → Connections |
| Live WebRTC (Mac) | part of `make test-mac` (`ScreenShareLoopbackTests`) | Real `ScreenShareController` → VideoToolbox H.264 → loopback → a libwebrtc test receiver; no permission prompts (test pattern, no microphone) |
| Android unit | `make test-android` | JVM tests (JDK 21 found automatically) |
| Android build + lint | `make build-android lint-android` | APK in `app/build/outputs/apk/debug/` |
| Go | `make test-go` | gofmt, vet, `go test -race` |
| Go + PostgreSQL | `make test-go-postgres` | Throw-away cluster on a Unix socket (`scripts/pg-test.sh`); never touches an existing server |
| Secret scan | `make secret-scan` | Reports file:line only; fails on credential-shaped strings or secret-bearing files |
| Android ↔ Mac live | see §3.1 | Emulator + loopback interop host; approval typed by a human |

## 2. Unit tests (per module)

| Module | Cases |
|---|---|
| Envelope codec (Swift, Kotlin, Go-fixtures) | every `fixtures/valid` decodes; every `fixtures/invalid` rejected with the expected code; size limits; unknown type/version; sequence replay |
| MBH1 (Swift, Kotlin, Go) | vectors: TH1/TH2, ECDH, HKDF keys, SAS, session id, frame encryption; signature verification across languages; tampered signature/proof/fingerprint rejected; counter replay/gap rejected |
| Pairing | QR URL round trip; expiry; single use; wrong secret; window closed; SAS displayed |
| Trust store | add/revoke/list; revoked key refused on resume |
| Connection state machine | legal transitions only; backoff bounds + jitter range; max attempts → `failed` |
| Path guard | `..`, absolute, NUL, empty segment, symlink escape (real temp dirs), symlink inside root allowed, long paths |
| Transfer | chunking boundaries; reassembly; out-of-order/duplicate chunk; checksum mismatch; oversize; cancel deletes temp; atomic rename; `SendWindow` (8 in flight, resume index; same rule in Kotlin); `TransferService` E2E between two services: verified + quarantined delivery, ask → accept / decline (sender sees "declined"), corrupted chunk → no file left, pause/resume/cancel and the 2-per-session limit, unsafe offers refused; Kotlin `ChunkAssembler` order/length/corruption and offer fixtures incl. the `requestId` echo |
| Clipboard | revision ordering; hash mismatch; loop guard; concealed types skipped; size cap; Off/Ask/Auto policy; secret detection (private keys, API tokens, Luhn-valid card numbers — Swift + Kotlin) |
| Health | metric status/provenance; capacity % only with compatible values; never derives health from charge %; report JSON schema version; Markdown redaction (username/home path/serial) |
| AI providers | SSE parser (multi-line data, comments, `event:` field, CRLF); NDJSON parser (mid-stream error); Anthropic/OpenAI/Ollama request shapes; error mapping (401/404/429/529); refusal; model list parsing; capability gating |
| AI policy | Local Only blocks cloud providers **before** any request (spy transport sees zero calls); endpoint validator (scheme, loopback, private, public+https, credentials in URL rejected); secrets never in `ProviderConfig` encoding; redactor |
| Agents | executable discovery; version parsing; auth status parsing drops e-mail/org; argument builder never emits dangerous flags; stream-json/JSONL event parsing from recorded fixtures; cancellation |
| Voice | intent parser for each allowlisted phrase; ambiguous → clarification; unknown → no action; dangerous ("delete", "rm", "format", "sudo", "shell") → rejected; approval required for medium/high risk |
| Coordinates (Phase 4) | normalized → display points for scaled/Retina/multi-display/rotated frames; clamping; phone `VideoGeometry` (fit letterbox bars ignored, fill center-crop, zoom/pan undone) |
| Input data channels (Phase 4) | `DataChannelInputGate`: input only, each type only on its channel, session id, per-channel replay, malformed/out-of-range refused, rate limit; live loopback: pointer + click delivered, key on the lossy channel and non-input refused, revoked grant stops delivery, release on stop |
| Screen streaming | tier boxes (2560×1600 → 1280×800 / 960×600 / 1920×1200), never upscale, even sizes, fps cap; `screen.state` payload valid on the wire and clamped; adaptive quality (4 s down, 20 s up only when the bandwidth estimate fits, 10 s hold, fixed quality never moves); webrtc-stats parsing (fps, bitrate over the real interval, codec, hardware flag, RTT, direct/relayed/unknown path, counter reset); Kotlin `screen.state` parsing from the shared fixtures, reason texts, candidate buffer bound; Mac live loopback: H.264 negotiated + decoded, quality change resizes frames, stop, `busy`, permission refusal |
| Connectivity | QR address order (primary interface first, bridges last, private IPv4 only); Bonjour match (fingerprint prefix, LAN-only, IPv6 link-local skipped, working address remembered); Tailscale ranges `100.64.0.0/10` + `fd7a:115c:a1e0::/48`, MagicDNS syntax, user-entry normalization, route classification (Swift + Kotlin mirror); Tailscale status = routed through the tunnel, not just an interface address; live tailnet listener: labelled `viaTailnet`, refused + session closed when turned off (skips unless Tailscale routes) |
| Internet mode (Phase 11) | Connect statements byte-identical to the Go server (register/auth/pairing/`MBC1/rtc`, Swift + Kotlin against the shared vectors); vector offer verifies and is refused when stale (> 2 min), for another recipient, by another key, or with a tampered fingerprint; signed answers round-trip between the platforms' JSON encodings; malformed rendezvous (unsigned offer, unknown kind/field, bad ids) rejected; replay guard; server address rules (https only, plain http only for loopback/emulator in debug); ICE route from stats (relay on either end = relayed); Mac `LANHostServer.adopt`: refused while internet access is off, resume session labelled `internetDirect` → `internetRelayed` on a route change, closed when internet access is turned off, pair mode refused even with a valid code, untrusted phones refused |
| Notifications (Phase 12) | Kotlin `NotificationRules`: own/ongoing/persistent/group-summary/system-category/blocked/empty never mirrored; preview policy (app only → `content_hidden`, title → `title_only`, full → `none`); one-time codes masked only with a code context (`partial`), cards and keys masked; ids salted, stable, opaque; Swift `BatteryAlertPolicy` (once per discharge, re-arm on charging or ≥ 25 %, unknown readings never alert) |
| Go service | register (bad proof, bad key, duplicate); challenge single-use/expiry; token issue/expiry/hash-at-rest; pairing requires both signatures + host caller; revoke by either party; relay only between paired peers; unknown outer type; size + rate limits; TURN credential format; `/healthz` |

## 3. Integration tests

* Swift: MBH1 client ↔ host over an in-memory duplex and over a real loopback `LANHostServer`
  (pair → approve → resume → revoke → refused).
* Go: HTTP API end-to-end with `httptest.Server`; two WebSocket clients relaying through `/v1/signal`;
  revocation cuts an open relay; PostgreSQL store contract test (same suite as memory store).
* Android: JVM test of the MBH1 client against the shared vectors; codec against shared fixtures.

### 3.1 Android ↔ Mac live interop (emulator, no phone needed)

1. `make build-android` and boot an emulator (a shared AVD can be booted with
   `emulator -avd <name> -read-only -no-snapshot` so it is not modified); `adb install -r` the APK.
2. `make interop-host` — starts `MyBuddyInteropHost`: the real `LANHostServer` bound to 127.0.0.1 only,
   a throw-away identity, health.read only, and prints `INVITATION mybuddy://pair?…` advertising
   `10.0.2.2` (the emulator's alias for the Mac's loopback).
3. On the emulator: Pair → paste the link (`adb shell input text` truncates long strings — type it in
   chunks) → Pair. Compare the 6-digit code on the phone with the host's `APPROVAL … code=` line and
   type `y` only if they match.
4. Expect: Home shows "Connected · Wi-Fi" and this Mac's live health; force-stop + relaunch resumes;
   stopping the host shows bounded reconnect attempts; Settings → Forget → re-pair works.
5. Screen streaming: run the host with `--screen test-pattern` (grants `screen.view` too and streams a clearly
   labelled synthetic picture through the real WebRTC pipeline). Remote → View screen: the phone shows the
   "MyBuddy TEST PATTERN" picture with Live, fps/bitrate/codec, path and decoder; Low → 960×600 @ 15 fps;
   full screen + Back; Stop viewing; Home button → the host logs `stopped by the phone (background)`; return →
   reconnects and resumes; leaving the tab → `(user)`; killing the host → the picture disappears at once.
   The host prints `STATS sent …` every 5 s (send fps, bitrate, encoder, quality limitation).
6. Tailscale (needs Tailscale running on the Mac): `MyBuddyInteropHost --tailnet [--screen test-pattern]`
   listens on the Mac's tailnet address and advertises it.
7. Remote input (Phase 4): add `--input log` (grants `input.control`; every event is printed, **never
   injected**). While viewing, switch the video to Control: a tap at the middle logs
   `input.button left click x=0.500 y=0.499 via data channel`, a long-press a right click, a drag pointer
   moves; touchpad, Click and typed text also arrive `via data channel`; after Stop viewing they arrive
   `via control channel`.
8. Files and clipboard (Phase 6): add `--files <dir>` (grants `files.browse`, `files.transfer`,
   `clipboard.sync`; shares `<dir>`, saves uploads into `<dir>/incoming` automatically — test host only — and uses
   a **fake clipboard** that logs length + hash prefix, never the real Mac clipboard). Push a file to the emulator
   (`adb push x /sdcard/Download/`). Then: Files → tap the shared folder → a file → Download (lands in
   `Downloads/MyBuddy`, card says "SHA-256 verified"); Send a file to your Mac → system picker → the file (lands in
   `<dir>/incoming` with the quarantine attribute); type `send <path>` on the host → Save to phone / Decline;
   with an 80 MB file: Pause holds the percentage, Resume completes, Cancel leaves no partial file on either side,
   and pressing Home mid-transfer keeps it going (foreground service) to completion. Clipboard: `clip <text>` →
   Ask shows the text with Copy here; Automatic applies it, but text that looks like a key arrives hidden and
   asks; Off answers `clipboard.paused`; typed text on the phone reaches the host with a matching hash.
   Compare checksums with `shasum -a 256` and `adb shell sha256sum`.
9. Internet mode (Phase 11) without any public server: run `connect-api` locally
   (`MYBUDDY_LISTEN=127.0.0.1:8787 MYBUDDY_TURN_SECRET_FILE=<file> MYBUDDY_TURN_URLS="turn:10.0.2.2:3478?transport=udp"`)
   and the development relay (`services/devturn`: `MYBUDDY_TURN_SECRET_FILE=<same file> devturn -listen
   127.0.0.1:3478 -relay-ip <this Mac's LAN IP>`), then the host with `--connect http://127.0.0.1:8787
   --connect-advertise http://10.0.2.2:8787`. Pair; the phone shows *Internet access offered* → Allow (host:
   `CONNECT enrolled`). Type `lan off`: the phone reconnects over the internet ("Connected · Internet"; host
   `route=internetDirect`); health, View screen and Control work. Settings → Connections → *Force TURN relay
   (testing)* (debug builds) → Disconnect → Connect: "Connected · Internet (relayed)", host `route=internetRelayed`,
   video path "Relayed (TURN) · relay ↔ host", Files shows that transfers need a direct connection and both
   directions are refused. *Remove internet access* ends the internet session (server notifies the Mac). Killing
   the host: 8 bounded retries, then "Your Mac isn't online…". With `connect-api` stopped, Wi-Fi pairing and
   sessions still work.
10. Notifications (Phase 12): host with `--notifications` (grants `notifications.mirror`, prints what arrives;
   `alert <text>` sends a Mac alert). Phone: Settings → Notifications on your Mac → Open Android settings → allow
   in Android's dialog → switch mirroring on. Post with `adb shell "cmd notification post -t '<title>' <tag> '<text>'"`
   (quote inside the remote shell): default → host `redaction=content_hidden` with no title/text; *Title and
   text* → full text, and a "verification code is 482913" text arrives as `••••••` (`partial`); *Title only* →
   title only; `cmd notification snooze` on a mirrored key (quoted) → host `removed`; `cmd notification set_dnd on`
   → nothing sent, panel says "Paused while Do Not Disturb is on"; blocking the app in the list → nothing sent;
   Home + 40 s in the background → still connected (procState 5 while the listener is bound) and notifications
   arrive; `alert …` → a MyBuddy notification on the phone (after allowing notifications) and no echo back.
Last run: 2026-10-17 (session 4): steps 1–5 and 7–10 passed (all checksums matched); step 6 not run (Tailscale
installed but stopped on this Mac). The emulator decodes 1280×800 at 6–15 fps on its software GPU while the
Mac sends 27–30 fps.

## 4. Static checks

Swift: compiler warnings reviewed (`swift build` clean). Android: `lintDebug`. Go: `gofmt`, `go vet`.
Secret scan: `scripts/secret-scan.sh` (grep for key patterns; no real keys committed).

## 5. Manual hardware checklist (Mac M1 + Vivo X300)

Each item: **Status** = not run / pass / fail, with date and build. As of 2026-10-16 **every item is
"not run" on the Vivo X300** (no device attached). Emulator equivalents passed for H2 (manual link
instead of camera) and H6; H3–H5 have no emulator run yet. The Mac's pairing entry point is
**Pair a phone** (Overview, Remote Desktop, Settings, or ⌘K).

| # | Check | Steps | Expected |
|---|---|---|---|
| H1 | Install APK | `adb install -r app-debug.apk` on the Vivo (USB debugging on) | App launches to Home "Not paired" |
| H2 | QR pairing | Mac: Overview → Pair a phone. Phone: Scan pairing code | Phone + Mac show the same 6-digit code; approve on Mac → both show Paired |
| H3 | Wrong code path | Reject on Mac | Phone shows "Pairing declined"; no trust stored |
| H4 | Expired QR | Wait > 120 s, then scan | Phone: "This code expired"; Mac unchanged |
| H5 | Unknown device refused | Revoke the phone on Mac, reconnect from phone | Mac refuses (`session.rejected: revoked`), phone shows "Not trusted" |
| H6 | Health on phone | Phone Home after pairing | Battery % and charging state match the Mac menu bar |
| H7 | Screen stream (real capture) | Mac: Remote Desktop → Screen Recording → Allow… (system prompt), relaunch if macOS asks. Phone: Remote → View screen | Phone shows the Mac's real screen with Live + measured fps/bitrate/RTT, path "Direct", decoder hardware; Mac Remote Desktop shows the same picture as a preview, "Live · Vivo X300 is viewing", and macOS shows its recording indicator; quality chips and Fill/Fit/full screen work; pinch-zoom/pan/double-tap reset (not automatable on the emulator) |
| H7b | Screen permission missing / picker | Remove MyBuddy from Screen Recording, then View screen; then on the Mac use *Choose What to Share…* and pick one window | First: phone says the Mac hasn't allowed screen recording (no prompt pops up on an unattended Mac); second: the stream shows only that window (unverified whether macOS requires Screen Recording in addition to the picker) |
| H8 | Input | Mac: enable "Control mouse & keyboard" for the phone and allow Accessibility. Phone: View screen → Control → tap, double-tap, long-press, drag, two-finger scroll, touchpad, type | Clicks land exactly under the finger on the streamed display; "Input route: WebRTC data channel"; Emergency Stop halts immediately |
| H9 | Stuck keys | Hold a modifier on phone, kill Wi-Fi | Mac releases all keys within heartbeat timeout |
| H10 | Vivo background | Lock phone during session 5 min | Session suspends/reconnects per state machine; no silent failure |
| H11 | Voice | Phone: hold orb, say "show my Mac battery health" | Caption shows transcript; result spoken; no action without approval for risky intents |
| H12 | TURN | Phone on mobile data, Mac on Wi-Fi, *Force TURN relay* (debug build) | Stream works; path shows "Relayed"; Files says transfers need a direct connection |
| I1 | Deploy Connect | `infrastructure/README.md` on a VPS with a DNS name; `https://<name>/healthz` | `{"status":"ok"}` over TLS; coturn reachable on 3478/udp+tcp |
| I2 | Enrol | Mac: Settings → Connections → Internet → server address → Turn On; phone connected on Wi-Fi | Mac "Online · <name>"; phone shows *Internet access offered* → Allow → Mac lists the phone as "Internet access on" |
| I3 | Away from home | Phone on mobile data (Wi-Fi off), Tailscale off | "Connected · Internet" within ~10 s; health, View screen, Control work; Mac inspector Route "Internet · direct" or "· relayed (TURN)" |
| I4 | Revoke / offline | Mac: Remove Internet Access (or quit MyBuddy) | Phone's internet session ends; reconnect attempts end with a clear reason; Wi-Fi still works at home |
| H13 | Permissions | Revoke Screen Recording / Accessibility in System Settings | Mac shows `notAuthorized` with fix action; no crash |
| H14 | New Mac IP (discovery) | Pair, then give the Mac a new DHCP address (renew lease / other network), reopen the phone app | Reconnects without re-pairing; Settings → Connections shows the new Wi-Fi address first |
| F1 | Download from a shared folder | Mac: Files & Clipboard → Grant Folder Access; allow "Browse shared folders" + "Send & receive files" for the phone. Phone: Files → folder → file → Download | File in Downloads/MyBuddy, opens with Open; same SHA-256 as on the Mac |
| F2 | Phone → Mac | Phone: Send a file to your Mac (a photo) | Mac shows Accept/Decline (or saves automatically if chosen); file in ~/Downloads; Finder "downloaded from" quarantine prompt on first open |
| F3 | Mac → phone | Mac: Send File to Phone… | Phone shows Save to phone / Decline; Decline shows "Declined on the phone" on the Mac |
| F4 | Big file + Vivo background | 1 GB file; press Home and lock the phone mid-transfer | Progress notification (after allowing notifications); transfer completes; check Vivo battery settings don't kill it |
| F5 | Clipboard | Each mode on the phone; copy on the Mac; Send this phone's clipboard; copy a password from a password manager on the Mac | Off/Ask/Automatic behave as labelled; concealed items never sync; key-like text always asks |
| N1 | Mirroring on | Mac: allow *Mirror notifications*; phone: Android notification access + switch on; receive a message | Mac Notifications page shows the app name only (default); nothing stored on disk |
| N2 | Preview, codes, DND, filters | *Title and text*; SMS one-time code; Do Not Disturb; block one app | Code masked on the Mac; nothing during DND; blocked app silent |
| N3 | Mac alerts + background | Mac battery < 15 % / sleep; lock the phone 10 min with mirroring on | Phone gets "Mac battery low" / "going to sleep"; mirrored notifications still arrive (check OriginOS battery settings) |
| T1 | Tailscale pairing | Tailscale on both, same tailnet; Mac Settings → Connections shows "Ready · 100.x.y.z"; pair | QR carries the tailnet address; phone stores it |
| T2 | Away from home | Phone on mobile data with Tailscale on; open MyBuddy | "Connected · Tailscale"; health loads; View screen works (path "Tailscale" on the Mac) |
| T3 | Add Tailscale address | Phone already paired: Settings → Connections → Add address → the Mac's 100.x or `…ts.net` name | Saved; connects over Tailscale when Wi-Fi is unavailable; a public IP or other name is refused |
| T4 | Tailscale off on the Mac | Turn off *Allow connections over Tailscale* during a tailnet session | Session ends at once; reconnect over the tailnet is refused (Activity: "Refused a connection over Tailscale"); Wi-Fi still works |

**Real-device round 2 (2026-10-18, after the first Vivo X300 run).** Each row: status / date / build.

| # | Check | Steps | Expected |
|---|---|---|---|
| R1 | Start speed, no stuck start | Phone: Remote → View screen, Stop, repeat ×5 | Live within a few seconds every time; never stuck on "Connecting video…" (the stage shows "Network check: …"; after 12 s without a picture it retries once, then fails with a reason) |
| R2 | Latency figures | Live stream → Stream panel | "Latency" shows buffer/decode/freezes; note the values with Auto and with Smooth 60 |
| R3 | Layout | Normal (portrait) view | Live, mode chips and Full screen sit *below* the picture; nothing covers the Mac's menu bar |
| R4 | Keyboard stays visible | Portrait: tap the Keyboard field | The field and keys stay above the phone keyboard; Home / End / PgUp / PgDn / Del / ⌘Tab act on the Mac |
| R5 | Full-screen trackpad | Full screen (opens landscape, Trackpad) | Drag moves the big pointer; tap = click; double-tap = double-click; rest then drag = drag (buzz); two-finger tap = right-click; two fingers scroll; pinch zooms the view; bar hides after 5 s, ▲ brings it back |
| R6 | Three-finger swipes | Trackpad or Touch: 3 fingers left/right/up/down | Mac switches Space / opens Mission Control / app windows |
| R7 | Live typing | Full screen → Keyboard; type, correct a word, Backspace on empty, Send | Text appears on the Mac as typed; Backspace on an empty field still deletes on the Mac; Send = Return |
| R8 | Ping both sides | Connected | Phone: "Ping N ms"; Mac sidebar "Connected · Wi-Fi · N ms", inspector "Ping", Remote Desktop latency |
| R9 | Stay Awake | Mac: Settings → This Mac → Stay Awake on; leave the Mac idle with the phone connected | Sidebar "Staying awake"; display doesn't sleep; `pmset -g assertions` lists MyBuddy; released on disconnect |
| R10 | Phone auto-save | Phone: Files → "Save files from your Mac automatically" on; Mac: Send File to Phone… | Saved to Downloads/MyBuddy with no Save/Decline card |
| R11 | Shared notes | Mac: Settings → Devices → Shared notes on. Write a note on each side; edit one while the phone is offline, reconnect; delete one | Each appears on the other side within a second; offline edits merge; deletion reaches both |
| R12 | Ollama from the phone | Mac: AI Studio → Ollama (llama3.2:3b); phone: AI → Chat | Answer streams; "Runs on your Mac via Ollama" |
| R13 | API keys | Mac: Settings → AI providers → paste Anthropic/OpenAI key → select; phone chat | Answer from the chosen provider; the phone never shows a key |
| R14 | Coding agent read-only | Mac: Devices → Coding agents on; AI Studio → From your phone → Add folder. Phone: AI → Coding agent → Claude Code, folder, Read-only | Output streams to the phone; the Mac's Run panel shows the same run |
| R15 | Coding agent edits | Same with "May edit files" | Mac shows "Let Claude Code edit files?"; Decline → phone says so; Allow → run starts; Stop on the phone cancels it |
| R16 | Home folder | Mac: Files & Clipboard → Share Home Folder → confirm; phone: Files | Home listed (no Library, no hidden items); Documents/Desktop/Downloads open after the macOS prompts |
| R17 | Tailscale from the phone | Tailscale on the Vivo (same account); phone Wi-Fi off | "Connected · Tailscale"; stream and notes work |
