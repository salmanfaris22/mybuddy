# MyBuddy Master Plan

Living document. Status values: **Not started · In progress · Built (unverified on hardware) ·
Verified · Blocked**. "Verified" always names the check that verified it. See `IMPLEMENTATION_LOG.md`
for command output.

## Current-state summary (Phase 0 reconnaissance, 2026-10-16)

* Repository: empty except the master prompt; initialized as a Git repo (`main`, no commits made).
* Mac toolchain: Swift 6.3.3 Command Line Tools, **no Xcode** → the Mac app is a SwiftPM package
  bundled into an ad-hoc-signed `.app` by script. Swift Testing works with explicit CLT flags.
* Android toolchain: SDK + NDK + API 37 platform present, JDK 21 (Homebrew keg), no Gradle/Android
  Studio → Gradle Wrapper bootstrapped from the verified official distribution.
* Backend: Go 1.26.2 and PostgreSQL 18 present; Docker absent.
* Agents: Claude Code 2.1.301 and Codex 0.160.0 installed and signed in; Ollama not installed.
* Hardware: no Android device attached via adb this session → all phone-side hardware checks are
  "not run — requires target device".
* Session 2 (same day): Android app built and verified on the Android 16 emulator against the real
  Swift host stack (live pairing, SAS match, resume, forget/re-pair, live health); deployment files
  and repository tooling written. Still no commits — committing is left to you.
* Session 3 (same day): Phase 3 screen streaming built on both sides with libwebrtc M150 and verified
  end-to-end on the emulator with a labelled test pattern; same-network reconnection hardened (Bonjour
  discovery, network-change and foreground retries, primary-interface address order); Tailscale added as a
  second route with icons/status on both apps (`CONNECTIVITY.md`). Tailscale was installed on the Mac
  during the session but is stopped, so no real tailnet run yet. iOS requested — blocked here (no Xcode).
* Session 4 (2026-10-16/17): Phase 6 built on both sides and verified end-to-end on the emulator against the
  real Swift transfer stack — shared-folder download, phone→Mac upload through the system picker, Mac→phone
  offers with Save/Decline, pause/resume/cancel both ways (80 MB), SHA-256 checked on both ends, clipboard in
  all three modes. Found and fixed: the earlier "Mac wire flow built" claim was wrong (only the receiver core
  existed — the flow is now built); Android froze the app during the file picker and long transfers (now a
  `dataSync` foreground service while a transfer moves, and the picked file waits for the reconnect); idle
  background reconnect churn (now held until the app returns). Then Phase 11 (internet mode through MyBuddy
  Connect: signed WebRTC rendezvous, MBH1 over a data channel, direct and TURN-relayed, verified on the emulator
  against a local server and a development relay) and Phase 12 (notification mirroring with consent, filters and
  redaction; Mac alerts; release signing/notarization guidance; R8 release build fixed and smoke-tested; manual
  test guide and release checklist).

## Phase matrix

| Phase | Scope | Status (session 4) | Verification |
|---|---|---|---|
| 0 | Recon, docs, dependency decisions, threat model | Verified | Recon commands + registry queries in IMPLEMENTATION_LOG |
| 1 | Design system + app shells | Mac: Built + visually verified · Android: Built + verified on emulator (API 36), every screen reviewed, 11 layout/honesty bugs fixed | Mac: 0 warnings, 13 snapshots · Android: 0 Kotlin warnings, lint 0 errors (2 known notices), emulator screenshots |
| 2 | Identity, QR pairing, MBH1, approval, trust, Connect API, revocation | Verified (automated + live emulator ↔ Swift host); on a real Vivo X300: not run. Session 3: Bonjour/NSD rediscovery, foreground + network-change retries, primary-interface address order, seal+send ordering fix | Swift↔Go↔Kotlin vectors; loopback E2E; emulator SAS matched 6× across sessions; background → idle timeout → automatic reconnect verified |
| 3 | ScreenCaptureKit + WebRTC streaming | **Built; WebRTC path verified** — Mac: capture service, picker, H.264 VideoToolbox sender, adaptive tiers, ICE restart, stats, preview UI · Android: receiver, TextureView renderer with zoom/pan, fit/fill, full screen, quality/display controls, honest states, background pause/resume. Real screen capture (Screen Recording) and the Vivo X300: not run | Mac live loopback test (H.264 hardware encode + decode, quality change, stop, busy, refusal); emulator E2E with the interop host's labelled test pattern (1280×800 sent at 27–30 fps; emulator decodes 6–15 fps on its software GPU), low tier 960×600@15 received at 15 fps; hardware H7/H7b pending |
| 4 | Remote input, mapping, emergency stop | **Built; transport verified** — input over WebRTC data channels (`mb-input` lossy, `mb-input-rel` reliable) with MBH1 fallback, `DataChannelInputGate` + per-message grant check, input mapped to the streamed display (refused for single-window shares), release when channels close · Android: direct-touch Control mode on the video (tap/double/long-press/drag/two-finger scroll through `VideoGeometry`), every stream starts in View mode, touchpad/keys over the data channel. Real CGEvent injection on hardware not run (needs Accessibility; tests never post events) | Swift gate + live data-channel tests; Kotlin geometry tests; emulator E2E with `--input log`: tap at center → `x=0.500 y=0.499 via data channel`, corner/long-press exact, fallback to control channel after stop; hardware H8/H9 pending |
| 5 | App launcher + safe folder access | Mac: Verified (path guard, symlink escape, app catalog) · Android: shared-folder browser verified on the emulator (browse → open/download dialog) | Swift tests; emulator E2E (session 4) |
| 6 | Clipboard + file transfer | **Built; verified on the emulator** — Mac `TransferService` (both directions, ask/auto-save, quarantine, watchdogs, 2 per session) + Files & Clipboard transfers panel · Android `TransferManager` (SAF read, pending MediaStore writes, `file.request` downloads), clipboard Off/Ask/Automatic with secret detection and loop guard, transfer foreground service. Vivo X300: not run | Swift `TransferServiceTests` (E2E, corruption, decline, pause/resume, limits) + Kotlin `TransferCoreTest`; emulator E2E with the interop host `--files` (checksums matched on both ends) |
| 7 | Mac health + report | Verified on this Mac and end-to-end on the emulator (this Mac's live snapshot rendered on the phone) | Swift tests incl. live collection; emulator screenshots |
| 8 | AI chat providers + Local Only | Mac: built + verified against scripted HTTP; no live provider call (no keys supplied) · Android: chat UI built, gated on `ai.chat` | Swift tests |
| 9 | Claude Code / Codex adapters | Detection verified live; task launch built, not run (would spend your quota) | Swift tests + live detection |
| 10 | MyBuddy Voice | Mac: intent router verified · Android: push-to-talk UI built, gated on `voice.commands`; not run with a microphone | Swift tests; emulator (off-state) |
| 11 | Internet mode | **Built; verified on the emulator against a local server** — Tailscale route (both apps; no real tailnet run yet) · MyBuddy Connect: Mac `ConnectClient`/`ConnectSignal`/`InternetHost` (signed answers, `adopt` over the `mb-session` data channel, route watcher), Settings → Internet panel, enrolment with consent on the phone · Android `ConnectClient`/`InternetDialer`/`RtcPipe`, internet fallback after Wi-Fi/Tailscale, relayed sessions disable file transfer · `services/devturn` for local relay tests · TURN TTL default 12 h. Public deployment, mobile data and a real NAT: not run | Swift `ConnectTests` + `InternetSessionTests`, Kotlin `ConnectTest` (shared vectors incl. `MBC1/rtc`); emulator E2E (TEST_PLAN §3.1 step 9): direct + forced relay, video/input over both, transfer refusal, revocation, Mac offline, server down |
| — | iOS controller (requested in session 3) | **Blocked here**: no Xcode, Command Line Tools have no iOS SDK; plan in `CONNECTIVITY.md` §6 | — |
| 12 | Notifications, release readiness | **Built; verified on the emulator** — Android `MirrorListener` + `NotificationMirror` (consent in Android settings, master switch off by default, preview policy, masking, DND pause, app filters, background delivery), Mac Notifications page (memory only, optional macOS banners — not run), Mac alerts to the phone (battery low, sleep) · release: Developer ID/notarization scripts + entitlements (no certificate here — not run), Android release signing + R8 keep rules (found `org.jni_zero` crash; fixed; release APK smoke-tested) · `RELEASE.md`, `MANUAL_TEST_GUIDE.md`, `RELEASE_CHECKLIST.md` | Kotlin `NotificationRulesTest`, Swift `AlertsTests`; emulator E2E (TEST_PLAN §3.1 step 10); release APK on the emulator; full regression (RELEASE_CHECKLIST §1) |

**Single next engineering task:** run `docs/MANUAL_TEST_GUIDE.md` on the MacBook Air M1 and the Vivo X300 with
the current builds — pairing by camera, real screen capture (Screen Recording) and control (Accessibility), files,
clipboard, notifications, Tailscale and (after deploying `infrastructure/`) internet mode — record the results in
`TEST_PLAN.md` §5 and fix what the real devices reveal. Everything is built; nothing has run on the Vivo yet.

## First vertical slice

**"Pair and see real Mac health on the phone."** Mac shows a QR built from its real Keychain identity →
phone scans → MBH1 handshake → Mac approval sheet with matching 6-digit code → trusted device stored →
phone requests `health.snapshot.request` → Mac answers with real IOKit/Mach data. Every piece of this
slice can be unit/integration tested on this machine except the camera scan and the physical phone,
which go on the hardware checklist.

## Risks

| ID | Risk | Impact | Mitigation |
|---|---|---|---|
| R1 | No Xcode: no `.xcodeproj`, no Xcode-managed signing/entitlements, no XCTest | Medium | SwiftPM + scripted bundle; Swift Testing; document Xcode path for release signing |
| R2 | Ad-hoc signed dev builds lose TCC grants on every rebuild | Medium (dev friction) | Stable bundle id, document re-granting; Developer ID for release |
| R3 | MBH1 is a custom composition of standard primitives, not externally reviewed | High (for public release) | Cross-language vectors, transcript binding, strict counters; independent review or migrate to Noise before release |
| R4 | WebRTC binary frameworks are large and evolve quickly | Medium | Pinned M150 on both platforms (SwiftPM checksum, Gradle version); only `MyBuddyMedia` / `ScreenReceiver` touch libwebrtc. Seen in M150: the ObjC log-level setter no longer limits stderr output; macOS lacks `LKRTCMTLNSVideoView` |
| R10 | Tailscale changes or isn't running | Low | Detection checks real routing, not just interface addresses; Wi-Fi keeps working without it; UI states it plainly |
| R11 | TURN REST credentials can't be renewed inside a running allocation | Low | Default TTL 12 h; a relayed session older than that drops and reconnects automatically; documented (PROTOCOL §7.4) |
| R5 | Vivo OriginOS background restrictions may kill the Android app/service | Medium | Foreground service only during an active session; manual battery-optimization guidance; hardware test |
| R6 | Battery health/cycle data on Apple Silicon only via `system_profiler` (no documented IOPS keys for cycles) | Low | Label source; mark unavailable on failure |
| R7 | Accessibility/Screen Recording permissions can be revoked at any time | Medium | Check `AXIsProcessTrusted` / capture authorization before each session; surface `notAuthorized` |
| R8 | Coding-agent CLIs change flags between versions | Medium | Detect version; adapters isolate flags; tests use recorded event fixtures; fallback to "Open in Terminal" |
| R9 | Single developer machine, no physical phone in this session | High (verification gap) | Hardware checklist with exact steps; emulator for UI where possible |

## Dependency/license summary

See `docs/research/DEPENDENCIES.md` (all Apache-2.0 / MIT / BSD / ISC / EPL-1.0 for JUnit test-only).
