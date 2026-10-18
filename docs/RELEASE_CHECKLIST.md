# Release checklist

Phase 12 exit criterion: what is **verified**, what is **built but unverified on real hardware**, and what is
**platform-limited** — without overclaiming. "Emulator E2E" means the Android 16 emulator talking to the real Swift
host code on this M1 Mac (`TEST_PLAN.md` §3.1). The Vivo X300 has run pairing, health and a live stream (session 5,
2026-10-17); the session-5 features below are built and unit-tested but not yet re-run on it. State as of
2026-10-18 (session 5).

## 1. Automated checks (run before every release)

| Check | Command | Last result |
|---|---|---|
| Protocol vectors + fixtures | `make protocol-check` | vectors match; 59 valid / 47 invalid fixtures current |
| Go service | `make test-go` (gofmt, vet, race tests) | pass |
| Go Postgres store | `make test-go-postgres` (throw-away cluster) | pass |
| Dev relay | `go -C services/devturn vet ./... && go -C services/devturn test ./...` | pass |
| Swift | `make test-mac` | 167 tests / 32 suites pass, 0 warnings |
| Android unit | `make test-android` | 68 tests pass |
| Android lint | `make lint-android` | 0 errors; notices: deliberate targetSdk 36, newer AGP available |
| Builds | `make build-mac-app`, `make build-android`, `./gradlew assembleRelease` | all build; release APK smoke-tested (pair, health, H.264 video) |
| Secrets | `make secret-scan` | OK (333 files) |
| Licenses | `docs/research/DEPENDENCIES.md` | all Apache-2.0 / MIT / BSD / ISC (JUnit EPL-1.0, tests only); WebRTC license bundled in the Mac app |

## 2. Features

| Feature | Status | Evidence / what's missing |
|---|---|---|
| QR pairing, 6-digit match, approval, resume, revoke | **Verified** on emulator + unit/vector tests; **paired on the Vivo X300** | Revoke/expiry on the Vivo not run (H3–H5) |
| Mac health on the phone | **Verified** (this Mac's live data) | — |
| Screen streaming (WebRTC H.264) | **Verified on the Vivo X300** (real capture, hardware decoder) | Session-5 changes (start fix, Smooth, low-latency playout) not re-run (R1, R2) |
| Full-screen trackpad, live keyboard, 3-finger swipes | **Built; unit-tested** (trackpad maths, typing diff) | Not run on the Vivo (R5–R7) |
| Ping on both sides, Stay Awake, phone auto-save | **Built; tested** (Swift/Android) | Not run on the devices (R8–R10) |
| Shared notes | **Built; merge rules tested on both platforms from shared vectors** | Not run on the devices (R11) |
| Coding agents from the phone | **Built; tested** (wire mapping, approval flow compiled) | Not run (would use your Claude/Codex quota) (R14, R15) |
| Ollama (local AI) | **Installed and answering** on this Mac (llama3.2:3b, loopback only) | Phone chat through it not run (R12) |
| Home-folder sharing | **Built; tested** with a fake home (Library + hidden items private) | Not run on the devices (R16) |
| Remote input (data channels, touch control) | **Built; transport verified** (input logged, never injected in tests) | Real CGEvent injection needs Accessibility (H8, H9) |
| Same-Wi-Fi reconnect + Bonjour rediscovery | **Built; verified on emulator** | Real DHCP change (H14) |
| Tailscale route | **Built; unit-tested** | No real tailnet run — Tailscale on this Mac is installed but signed out (T1–T4) |
| File transfer both ways, shared-folder download | **Verified on emulator** (checksums matched, pause/resume/cancel, background keep-alive) | Vivo X300 + 1 GB file + OriginOS battery behaviour (F1–F4) |
| Clipboard Off / Ask / Automatic | **Verified on emulator** against a log-only fake clipboard | Real Mac pasteboard + password managers (F5) |
| Internet mode (MyBuddy Connect) | **Built; verified on emulator** against a local server + dev TURN (direct, relayed, revocation, offline, server down) | Public deployment, mobile data, real NAT (I1–I4, H12) |
| Notification mirroring phone → Mac | **Built; verified on emulator** (Android consent dialog, previews, masking, DND, filters, removal, background) | Real messaging apps, OriginOS "restricted settings" and battery limits (N1–N3); macOS banners not run (needs the Mac's notification permission) |
| Mac alerts → phone (battery low, sleep) | **Built; transport verified** (test host alert shown as a phone notification) | Real low battery / sleep on this Mac (N3) |
| AI chat providers + Local Only | **Built; verified against scripted HTTP**; Ollama answers locally | No cloud provider call (no key supplied yet) |
| Claude Code / Codex adapters | Detection **verified**; task launch built, **not run** (would use your quota) | — |
| MyBuddy Voice (push-to-talk) | Mac intent router **verified**; phone UI built | Not run with a microphone (H11) |
| Mac release signing / notarization | Scripts + entitlements **built**; guards verified | No Developer ID certificate here — not run end to end (`RELEASE.md` §1) |
| Android release signing | **Verified** (R8 release build, locally signed, smoke-tested) | Your real key + Play App Signing |

## 3. Platform limits (by design, stated in the apps)

* macOS has no public API to read other apps' notifications → Mac → phone sends MyBuddy's own alerts only.
* No control of a sleeping, locked-at-login, powered-off or FileVault-locked Mac; secure input fields and
  protected content can't be captured.
* Android reads the clipboard only in the foreground or on an explicit tap; background apps are frozen within
  seconds — MyBuddy keeps the link only while a transfer moves or mirroring is on, and says so.
* Relayed internet sessions never transfer files (no file bytes through any server).
* Wake words / Siri are not offered (push-to-talk only); unattended access is not available.
* iOS controller: not built — no Xcode on this Mac (`CONNECTIVITY.md` §6).

## 4. Known limitations / risks to accept or fix

* MBH1 is a composition of standard primitives with cross-language vectors but **no external review** (R3).
* Ad-hoc Mac builds lose Screen Recording / Accessibility grants on every rebuild (R2) — use Developer ID.
* A relayed internet session ends when its TURN credentials expire (default 12 h) and reconnects (R11).
* Hardware checks in `TEST_PLAN.md` §5: pairing, health and streaming ran on the Vivo X300; R1–R17 not run yet.
* Ad-hoc builds lose Screen Recording / Accessibility on every reinstall; a self-signed or Developer ID signing
  identity would keep them (R2).

## 5. Release steps

1. All of §1 green; `git status` reviewed (nothing generated or secret staged).
2. Bump versions (Mac `Info.plist`, Android `build.gradle.kts`).
3. Mac: Developer ID build + notarize (`RELEASE.md` §1). Android: signed APK/AAB (`RELEASE.md` §2).
4. Run `MANUAL_TEST_GUIDE.md` on the M1 + Vivo X300 with those exact builds; record results in `TEST_PLAN.md` §5.
5. Release notes: copy §2/§3 with the updated statuses; publish SHA-256 sums and the signing fingerprints.
