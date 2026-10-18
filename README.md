# MyBuddy

Control and look after your Mac from your Android phone — privately. MyBuddy pairs a phone with a
Mac using a QR code plus a matching 6-digit code, then talks over an end-to-end-encrypted channel
(MBH1). The Mac is always the authority: every action is checked there against capabilities the
user granted, and AI keys never leave it.

| Component | Path | Stack |
|---|---|---|
| MyBuddy for Mac (host) | `apps/macos/MyBuddyMac` | Swift 6, SwiftUI, SwiftPM (no Xcode needed), macOS 14+ |
| MyBuddy for Android (controller) | `apps/android/MyBuddyAndroid` | Kotlin, Jetpack Compose, Material 3, minSdk 31 |
| MyBuddy Connect (optional internet mode) | `services/connect-api`, `infrastructure/` | Go, PostgreSQL, Caddy, coturn |
| Shared protocol | `protocol/` | JSON Schema, golden fixtures, MBH1 test vectors |
| Design, security, protocol, plans | `docs/` | Start with `docs/MASTER_PLAN.md` |

## Status (2026-10-17)

Working and verified on this M1 MacBook Air and the Android 16 emulator:

- **Pairing:** QR + matching 6-digit code + approval on the Mac; resume after restart; forget and
  re-pair. Verified live between the Android app and the real Swift host stack.
- **Screen streaming (Phase 3):** ScreenCaptureKit → WebRTC H.264 (VideoToolbox) on the Mac, a
  hardware-decoded, zoomable view on the phone, quality tiers, live stats, stop/background handling.
  Verified end-to-end with a labelled test pattern (real screen capture needs Screen Recording, which you
  grant on the Mac).
- **Remote control (Phase 4):** tap on the video to click there (Control mode), touchpad and keyboard;
  input travels over low-latency WebRTC data channels while streaming, checked by the Mac like any other
  command. Verified end-to-end with a test host that only logs input (real injection needs Accessibility).
- **Files and clipboard (Phase 6):** send files either way or download from a folder you shared on the
  Mac — accepted by you, checksum-verified, pause/resume/cancel, kept alive in the background on Android;
  plain-text clipboard Off / Ask / Automatic, never auto-syncing text that looks like a password or key.
  Verified end-to-end on the emulator against the real Mac transfer code.
- **Connections:** same Wi-Fi (Bonjour rediscovery when the Mac's IP changes), **Tailscale**, and the
  **internet through your own MyBuddy Connect server** (Phase 11): the server only introduces the phone to the Mac
  with signed WebRTC offers; the encrypted session runs directly or through TURN, file transfer stays off when
  relayed. Verified on the emulator against a local server and a development relay. See `docs/CONNECTIVITY.md`.
- **Notifications (Phase 12):** the phone's notifications on the Mac once you allow it in Android's settings —
  off by default, app name only unless you choose more, codes/keys masked, per-app filters, paused in Do Not
  Disturb; the Mac sends its own alerts (battery low, going to sleep). Verified on the emulator.
- **Mac health on the phone:** real battery, storage, memory, CPU, thermal and system data with
  its source, and "Unavailable" with a reason where macOS has no API.
- **Capabilities:** phone screens that need an ungranted capability (input, files, AI, voice) say so.
- **Mac app:** all nine sections, Preview mode, health report export, AI providers (Anthropic,
  OpenAI, Ollama, OpenAI-compatible; no live call made yet), Claude Code / Codex detection.
- **Connect service:** API, Postgres store, TURN credentials, signaling relay; both apps use it. Not deployed on
  a public server yet (`infrastructure/README.md`).
- **Release readiness:** Mac Developer ID signing + notarization scripts (no certificate here to run them),
  Android release signing and a smoke-tested R8 release build — `docs/RELEASE.md`, `docs/RELEASE_CHECKLIST.md`.

Not done yet: **any test on the real Vivo X300** (walk-through: `docs/MANUAL_TEST_GUIDE.md`), real screen
capture and input injection (they need Screen Recording / Accessibility granted on the Mac), a real tailnet, a
public Connect deployment, live AI provider calls (need your keys), and an iOS app (needs Xcode). Details and
evidence: `docs/IMPLEMENTATION_LOG.md`; per-feature status: `docs/RELEASE_CHECKLIST.md`.

## Build and test

Requirements: Command Line Tools (Swift 6), Go 1.26, JDK 21, Android SDK (platform 37), Python 3.

```sh
make test             # protocol check + Go + Swift + Android unit tests
make build-mac-app    # apps/macos/MyBuddyMac/build/MyBuddy.app (ad-hoc signed)
make build-android    # apps/android/MyBuddyAndroid/app/build/outputs/apk/debug/app-debug.apk
make secret-scan      # run before every commit
make help             # everything else
```

Try it on a phone: install the APK (`adb install -r …/app-debug.apk`), open `MyBuddy.app`, choose
**Pair a phone**, scan the code with the phone, check that both show the same 6 digits, and approve
on the Mac. Without a phone, `docs/TEST_PLAN.md` §3.1 pairs the Android emulator with a loopback host
(`--screen test-pattern` adds a labelled test stream).

## Principles (non-negotiable)

No fake data in the UI · no arbitrary shell, ever · secrets only in Keychain / Keystore / secret
files · Ollama stays on `127.0.0.1` · platform permission prompts are never bypassed ·
push-to-talk only (no wake word) · the Connect server relays ciphertext only. See `docs/SECURITY.md`.
# mybuddy
