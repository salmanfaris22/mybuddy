# Dependency & Toolchain Decisions

All versions below were read from the live registries/APIs on **2026-10-16** (not recalled).
Sources: Google Maven `maven-metadata.xml`, Maven Central, `proxy.golang.org/@latest`,
`services.gradle.org/versions`, GitHub REST API (`/repos/*/releases`), Android Developers docs.

## Verified local toolchain (MacBook Air M1, `MacBookAir10,1`)

| Tool | Version | Notes |
|---|---|---|
| macOS | 26.4.1 (25E253), arm64 | |
| Xcode | **not installed** | `xcode-select -p` → `/Library/Developer/CommandLineTools`; `xcodebuild` unavailable |
| Swift | 6.3.3 (CLT), SDK `MacOSX26.5.sdk` | SwiftUI/AppKit/ScreenCaptureKit/Speech/IOKit/CryptoKit build via SwiftPM (verified with a probe package) |
| Swift Testing | CLT `Testing.framework` | Needs `-F …/Library/Developer/Frameworks`, `-plugin-path …/host/plugins/testing`, rpaths to `Frameworks` and `usr/lib` → `apps/macos/MyBuddyMac/scripts/test.sh` |
| XCTest | not available with CLT | Tests use Swift Testing |
| JDK | OpenJDK 21.0.12.1 (Homebrew keg `/opt/homebrew/opt/openjdk@21`) | Not on default `PATH`; scripts export `JAVA_HOME` |
| Android SDK | `~/Library/Android/sdk`: platforms 34/35/36/37.0, build-tools 35.0.0/36.0.0, NDK 28.2.13676358, emulator, AVD `metrix360_pixel` | Android Studio not installed |
| Gradle | not installed globally | Project uses the Gradle Wrapper (9.6.1), bootstrapped from the official distribution with SHA-256 verification |
| adb | 1.0.41 (37.0.1) | No device attached during this session |
| Go | 1.26.2 darwin/arm64 | |
| PostgreSQL | 18.3 (Homebrew service running on `/tmp:5432`) | MyBuddy tests use a **separate throw-away cluster** in a temp dir — the user's server is untouched |
| Docker | **not installed** | `docker compose` files are written but not run this session |
| Claude Code | 2.1.301 (`~/.local/bin/claude`) | Headless: `-p --output-format stream-json`, `--permission-mode`, `auth status --json` |
| Codex CLI | 0.160.0 (`/opt/homebrew/bin/codex`) | Headless: `exec --json --sandbox …`, `login status` |
| Ollama | **not installed** | Adapter tested against a local mock server; real test pending |

## Android

| Component | Version | License | Why |
|---|---|---|---|
| Android Gradle Plugin | 9.4.1 | Apache-2.0 | Latest stable; requires Gradle ≥ 9.6.0, JDK ≥ 17, Build Tools 36.0.0, supports API ≤ 37; **built-in Kotlin** (no `org.jetbrains.kotlin.android` plugin) |
| Gradle | 9.6.1 | Apache-2.0 | Patch release of AGP 9.4's default Gradle line. Lint (2026-10-16) reports 9.8.1 available; upgrading = new wrapper + verified checksum + full build/test |
| Kotlin (Compose compiler plugin `org.jetbrains.kotlin.plugin.compose`, serialization plugin) | 2.4.21 | Apache-2.0 | Latest stable; Compose compiler version must equal Kotlin version |
| Compose BOM | 2026.09.00 (ui/foundation/animation 1.12.1, material3 1.4.0, material-icons-extended 1.7.8) | Apache-2.0 | Compose ≥ 1.12 requires `compileSdk 37` + AGP 9 |
| androidx.activity:activity-compose | 1.13.0 | Apache-2.0 | |
| androidx.core:core-ktx | 1.19.1 | Apache-2.0 | |
| androidx.lifecycle (runtime-compose, viewmodel-compose) | 2.11.0 | Apache-2.0 | |
| androidx.navigation:navigation-compose | 2.10.2 | Apache-2.0 | |
| androidx.camera (camera2, lifecycle, view) | 1.6.2 | Apache-2.0 | QR scanning preview/analysis |
| androidx.datastore:datastore-preferences | 1.2.1 | Apache-2.0 | Trusted host + settings |
| com.google.zxing:core | 3.5.4 | Apache-2.0 | QR decoding without Play Services (works on any Vivo ROM) |
| org.jetbrains.kotlinx:kotlinx-coroutines-android | 1.11.0 | Apache-2.0 | |
| org.jetbrains.kotlinx:kotlinx-serialization-json | 1.11.0 | Apache-2.0 | Envelope codec |
| com.squareup.okhttp3:okhttp | 5.5.0 | Apache-2.0 | WebSocket client (LAN + Connect) |
| io.github.webrtc-sdk:android | 150.7871.01 (2026-08-31) — **in the build** (`org.webrtc` package) | MIT packaging, WebRTC BSD-3-Clause | Maintained libwebrtc AAR (same M150 branch as the Mac framework). The app ships only `arm64-v8a` (`abiFilters`; Vivo X300 and Apple-silicon emulators), keeping ~33 MB of other ABIs out; debug APK 90.7 MB. `io.getstream:stream-webrtc-android` last released 2025-09 → not chosen |
| junit:junit | 4.13.2 | EPL-1.0 | JVM unit tests |

## macOS

| Component | Version | License | Why |
|---|---|---|---|
| LiveKit `webrtc-xcframework` (SwiftPM package `exact: "150.7871.03"`, product `LiveKitWebRTC`, binary target checksum `5727a03c…4557`) | 150.7871.03 (2026-10-05) — **in the build** (target `MyBuddyMedia`) | MIT packaging, WebRTC BSD-3-Clause | Maintained; macOS slice arm64+x86_64 (29 MB); class prefix `LKRTC`. Embedded in `MyBuddy.app/Contents/Frameworks` and re-signed by `build-app.sh`; license copied to `Contents/Resources/Licenses/WebRTC-LICENSE.txt`. Note: `LKRTCMTLNSVideoView` is not exported on macOS — the unified `LKRTCMTLVideoView` is used. `stasel/WebRTC` (M155, license NOASSERTION) kept as an alternative |
| Apple frameworks | SDK 26.5 | Apple | SwiftUI, AppKit, ScreenCaptureKit, CoreGraphics, ApplicationServices (AX), IOKit, Network, Speech, AVFoundation, CryptoKit, Security, CoreImage |

No other third-party Swift dependencies.

## Go service

| Module | Version | License | Why |
|---|---|---|---|
| Go | 1.26.2 | BSD-3 | stdlib `net/http` routing, `crypto/ecdsa`, `crypto/hkdf`, `crypto/ecdh` |
| github.com/coder/websocket | v1.8.15 (2026-06-15) | ISC | Maintained, context-aware WebSocket (successor of nhooyr.io/websocket) |
| github.com/jackc/pgx/v5 | v5.11.0 (2026-09-07) | MIT | PostgreSQL driver/pool |

### Development-only relay (`services/devturn`, its own module — never deployed)

| Module | Version | License | Why |
|---|---|---|---|
| github.com/pion/turn/v4 | v4.1.4 (2026-01-08) | MIT | Loopback-only TURN relay that accepts connect-api's REST credentials, so the relayed path can be tested on one Mac with the emulator (production uses coturn) |
| pion/dtls, pion/stun, pion/transport, pion/logging, pion/randutil (indirect) | v3.0.7, v3.0.1, v3.0.8 / v4.0.1, v0.2.4, v0.1.0 | MIT | pion/turn dependencies |
| github.com/wlynxg/anet (indirect) | v0.0.5 | BSD-3-Clause | Interface listing used by pion/transport |
| golang.org/x/crypto, golang.org/x/sys (indirect) | v0.32.0, v0.30.0 | BSD-3-Clause | pion dependencies |

## Infrastructure (`infrastructure/`, written but not run here — no Docker on this Mac)

Image tags verified to exist on Docker Hub / GCR on 2026-10-16. Pin digests for production.

| Image | Tag | Role |
|---|---|---|
| golang | `1.26-alpine` | Build stage for `connect-api` |
| gcr.io/distroless/static-debian13 | `nonroot` | Runtime for `connect-api` (static binary, non-root) |
| postgres | `18-alpine` | Metadata store (PGDATA under `/var/lib/postgresql` in 18.x images) |
| caddy | `2.11-alpine` | TLS reverse proxy, automatic certificates |
| coturn/coturn | `4.18-alpine` | TURN relay (`use-auth-secret`, private peer ranges denied, relay 49160–49200) |

## API references consulted

* Anthropic Messages API (via Claude API skill reference, cached 2026-10-06): `POST /v1/messages`,
  `anthropic-version: 2023-06-01`, SSE events, `GET /v1/models` (capabilities), `refusal` stop reason,
  `fallbacks: "default"` + `server-side-fallback-2026-07-01`.
* OpenAI Responses streaming event types: `openai/openai-python` `src/openai/types/responses/*` (docs
  site returned HTTP 403 to automated fetch).
* Ollama: `docs/api.md` (endpoints), `docs/api/streaming.mdx` (NDJSON), `docs/api/errors.mdx`.
* Claude Code / Codex: `--help` output of the installed CLIs (2.1.301 / 0.160.0).
* AGP 9.4 release notes and "Migrate to built-in Kotlin"; Compose compiler setup page.
