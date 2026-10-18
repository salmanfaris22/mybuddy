# MyBuddy Product Design

## 1. Brand

* **Personality:** precise, calm, intelligent, trusted, fast, premium, personal.
* **Mark:** "Companion orbit" — a solid core (mint) with a thin orbit ring and one satellite dot (cyan).
  Built from native vector primitives (SwiftUI `Circle`/`Path`, Compose `Canvas`). When a session is
  live the satellite travels the orbit slowly (8 s/rev); otherwise it rests at 45°. Reduce Motion → static.
* **Voice:** short, concrete, honest. Prefer "Not available on this Mac" over vague errors. Never claim
  a capability that has not been verified at runtime.
* Dark theme is the default and the only polished theme in v1.

## 2. Tokens (shared by Mac and Android)

| Token | Hex | Use | Contrast vs `base` |
|---|---|---|---|
| `base` | `#0A0C10` | Window/app background | — |
| `surface` | `#11151B` | Panels, sidebar | — |
| `elevated` | `#171D25` | Cards, sheets, popovers | — |
| `elevatedHigh` | `#1C232D` | Hover/pressed surfaces, input wells, user chat bubbles (Mac name: `elevatedHover`) | — |
| `border` | `#27303B` | Hairlines, dividers (1 px / 0.5 pt) | — |
| `borderStrong` | `#35404D` | Outlined/secondary button borders, emphasized dividers | — |
| `textPrimary` | `#F4F7FB` | Primary text | 18.2:1 (15.8:1 on `elevated`) |
| `textSecondary` | `#9AA6B5` | Secondary text | 7.9:1 (6.9:1 on `elevated`) |
| `textTertiary` | `#7A8595` | Captions, metadata only | 5.2:1 (4.5:1 on `elevated`) |
| `accent` (electric mint) | `#B8F36B` | Primary action, live/connected state — **sparingly** | 15.0:1; text on accent uses `base` (15.0:1) |
| `info` (cool cyan) | `#6CDCF5` | Links, secondary highlights, relayed path | 12.3:1 |
| `warning` (amber) | `#F4BE62` | Degraded, needs attention | 11.6:1 (10.0:1 on `elevated`) |
| `danger` (coral) | `#FF6B76` | Errors, Emergency Stop, revoke | 7.1:1 (6.2:1 on `elevated`) |

Color is never the only signal: every status also has an icon and a text label.

Spacing (4-pt grid): `xxs 2 · xs 4 · s 8 · m 12 · l 16 · xl 24 · xxl 32 · xxxl 48`.
Radius: `sm 6 · md 10 · lg 16 · xl 24 · pill`.
Elevation: no drop shadows on dark; depth comes from `surface → elevated` steps, a 1-px top highlight
(`white @ 4%`) and restrained background lighting (a single radial gradient, ≤ 6% opacity).

### Typography

| Style | Mac (SF Pro) | Android (system sans) | Use |
|---|---|---|---|
| `display` | 30/36 semibold, rounded digits | 30sp/36 semibold | Hero numbers (battery %, latency) |
| `title` | 20/26 semibold | 22sp/28 semibold | Screen titles |
| `headline` | 15/20 semibold | 17sp/22 semibold | Section headers |
| `body` | 13/18 regular | 15sp/21 regular | Content |
| `callout` | 12/16 regular | 13sp/18 regular | Secondary content |
| `label` | 10.5/13 semibold, +0.6 tracking, uppercase | 11sp/14 semibold, +0.6 tracking | Section labels, chips |
| `mono` | SF Mono 12/16 | monospace 13sp/18 | IDs, versions, paths, diagnostics |

All numerals in live metrics use monospaced digits so values don't jitter.

### Motion

| Token | Value | Use |
|---|---|---|
| `quick` | 120 ms ease-out | Hover, press |
| `standard` | spring(response 0.35, damping 0.86) | Selection, panel changes |
| `emphasized` | spring(response 0.5, damping 0.8) | Connection established, sheet entry |
| `pulse` | 1.6 s ease-in-out repeat | Live/listening indicator |
| `orbit` | 8 s linear repeat | Brand mark while connected |

Reduce Motion: springs become 150 ms cross-fades, repeating animations stop, the voice orb shows a
static level ring. Animations never block input or run on the remote-control hot path.

### Icons

macOS: SF Symbols (`.hierarchical` rendering, consistent `.medium` weight). Android: Material Icons
Rounded (Apache-2.0, via Compose BOM). No emoji as icons. No third-party or OS logos as the brand mark.

## 3. Mac information architecture

Three zones in a resizable `NavigationSplitView`:

* **Sidebar (220 pt):** brand mark + "MyBuddy" + host status dot; nav: Overview, Remote Desktop,
  AI Studio, Voice, Files & Clipboard, Notifications, Mac Health, Activity, Settings. Collapsible.
* **Top status bar (in the detail toolbar):** paired-device + connection pill (state, path direct /
  relayed, latency when measured), command palette (`⌘K`), settings.
* **Canvas:** section content. Mix of live surfaces, tables, compact metric rows, timelines and designed
  empty states — not a uniform card grid.
* **Inspector (≥ 1180 pt window width):** context for the section (session details, device, provider,
  metric provenance). Collapses below that width.

### Screens

| Screen | Content (first viewport) | States |
|---|---|---|
| Overview | Hero: MyBuddy status sentence + Mac host health + phone status; remote session preview with Connect; battery ring with provenance; live activity timeline; current AI provider + Test; quick actions | No phone paired → pairing invitation; collecting → skeletons |
| Remote Desktop | Large stream surface or elegant "not connected" canvas; quality, display, pointer viz, fit/zoom; diagnostics strip (RTT, fps, bitrate, direct/relayed); Disconnect + Emergency Stop | Not paired · waiting · permission needed (Screen Recording / Accessibility) · live · error |
| AI Studio | Mode switch (Chat Models / Coding Agents), provider + model picker, privacy indicator, transcript with streaming, approval cards, agent process panel (workspace, executable, version, state, events), Stop | Not configured · missing key · Ollama not running · CLI missing / not signed in · Local Only blocked |
| Voice | Large orb, mic state, push-to-talk (hold Space or click), live caption, last intent + result, voice/locale/speed settings | Mic/speech permission needed · listening · transcribing · thinking · speaking · error |
| Files & Clipboard | Granted folders (Grant Folder Access), browser, transfers with progress/verify, clipboard mode (Off / Ask / Trusted auto), pause | No folders · denied · transfer failed |
| Notifications | Capability explanation, phone → Mac mirror settings, filters, redaction, master kill switch | Not connected · listener not enabled on phone |
| Mac Health | Overview, Battery, Storage, Memory & CPU, Connectivity, Host diagnostics, History, Export (JSON/Markdown, redaction preview) | Collecting · unavailable metric with reason |
| Activity | Filterable timeline (sessions, transfers, clipboard, notifications, AI, voice), delete history | Empty |
| Settings | Devices & permissions (per-capability toggles, revoke), Pairing, Connect service, AI providers (keys in Keychain), Privacy (Local Only, retention), Voice, Appearance | — |

## 4. Android information architecture

Bottom navigation: **Home · Remote · AI · Files · Activity**. Voice, Health, Notifications and Settings
are reached from Home (and a top-bar settings action) to keep the bar uncluttered.

| Screen | Content |
|---|---|
| Home | Compact Mac identity + connection state; primary Remote CTA; battery + health summary row; MyBuddy Voice orb button; AI status line ("Runs on your Mac via …"); recent activity |
| Pairing | Camera QR scanner with framing guide, manual address fallback (dev), SAS code + "Waiting for approval on your Mac" |
| Remote | Full-bleed video surface; floating minimal controls (Touch / Touchpad mode, keyboard, right-click, scroll, fit/zoom, quality, latency badge); Emergency disconnect always visible; landscape-first |
| AI | Provider/model chips (shows it runs on the Mac), transcript, composer with voice input, approval sheets, Stop |
| Files | Approved Mac folders, transfer list with progress, pause/resume/cancel, SHA-256 verified badge |
| Activity | Filter chips + timeline; delete history |
| Voice (sheet) | Orb, caption, cancel/mute, last command result |
| Health (screen) | Battery, storage, memory/CPU, thermal state; each with source + time |

Gestures (Remote): **Touch mode** — tap = click at point, long-press = right click, two-finger pan =
scroll, pinch = zoom the *local view* (never sends input). **Touchpad mode** — drag moves the remote
pointer relative, tap = click, two-finger tap = right click. A small hint chip shows the active mode.
Zoom/pan gestures are consumed locally and never also emitted as input.

## 5. States (both platforms)

Every data-bearing view renders a `LoadState`: `loading` (skeleton shimmer, Reduce Motion → static),
`available`, `unavailable(reason)`, `notAuthorized(reason, fixAction)`, `failed(error, retry)`.
Designed empty states use the brand mark, one sentence and one action. Raw exception text is never shown;
errors map to user-facing copy with an optional "Details" disclosure (redacted).

**Preview/Demo mode** (Settings → Developer, or `--demo`): uses `DemoData` and shows a persistent
"Preview data" badge. Production state is never populated from demo fixtures.

## 6. Accessibility

* Every control has an accessibility label + hint; status pills expose state as text.
* Dynamic Type (Android sp scaling, Mac uses relative font styles where practical); layouts reflow.
* Visible focus rings on Mac (keyboard navigation through sidebar and canvas).
* Touch targets ≥ 48 dp on Android; ≥ 24 pt hit areas on Mac.
* Contrast per §2; no color-only signaling.
