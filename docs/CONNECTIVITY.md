# How the phone reaches the Mac

MyBuddy always talks phone ↔ Mac directly and end-to-end encrypted (MBH1 for control, DTLS-SRTP for
video). What changes between the modes below is only *how the packets find the Mac*. Every mode uses the
same pairing, the same approval on the Mac, the same per-capability permissions and the same refusal of
unknown devices.

| Mode | Use it when | You need | Extra server | Status |
|---|---|---|---|---|
| **Same network (Wi-Fi)** | Phone and Mac are on the same Wi-Fi / LAN | Nothing else | None | Built; verified on the Android emulator against the real Swift host; Vivo X300 not yet run |
| **Tailscale** | You're away from home: other Wi-Fi, mobile data, office | The Tailscale app on the Mac and the phone, signed in to the same tailnet | None of ours (Tailscale's coordination service; data goes device-to-device or via Tailscale's DERP relays) | Built (detection, pairing address, "Add Tailscale address", icons and status on both apps); unit-tested on both platforms; **not yet run on a real tailnet** — Tailscale was installed on this Mac during the session but is stopped (signed out) |
| **MyBuddy Connect** | Away from home without Tailscale | Your own small server (`infrastructure/`) reachable over HTTPS, optionally with TURN | Yes, self-hosted | Built on both apps; verified end-to-end on the emulator against a local server and a development TURN relay (direct and forced-relay paths, revocation, Mac offline, server down); **not yet deployed on a public server or run on mobile data** |
| iOS controller | — | Xcode (not installed here) | — | Not started — see §6 |

The phone tries them in this order and shows which one it used: **Wi-Fi addresses first, then Tailscale
addresses, then MyBuddy Connect** (only if you set it up).

---

## 1. Same network (Wi-Fi / LAN)

**Pairing.** *Pair a phone* on the Mac shows a QR code holding up to four `host:port` addresses (plus the
Mac's key fingerprint and a single-use secret, valid 2 minutes). The Mac lists its Wi-Fi/Ethernet address
first — the interface that carries the default route — then other `en*` interfaces, then bridge
interfaces (Internet Sharing, virtual machines), so the phone never waits out a timeout on an address it
can't reach before trying the right one.

**Reconnecting.** The phone remembers the addresses and reconnects on its own:

* at launch, when the app returns to the foreground, and whenever Android reports a new network;
* with bounded exponential backoff (8 attempts, full jitter) and then a visible "Connection failed" with a
  Connect button — never endless silent retries;
* **if the Mac's IP address changed** (routers hand out new DHCP leases): the Mac advertises itself with
  Bonjour (`_mybuddy._tcp`, TXT `fp` = first 8 characters of its key fingerprint). While the remembered
  addresses are tried, the phone runs Android Network Service Discovery in parallel and dials what it finds.
  The address that worked is remembered for next time. A discovery match only *selects a candidate*: the
  MBH1 handshake pins the Mac's full key, so a fake advertisement cannot impersonate the Mac.

**Requirements and pitfalls**

* Both devices on the same network. Guest networks and "AP/client isolation" on some routers block
  device-to-device traffic — MyBuddy then shows "Can't reach your Mac on this network".
* macOS: the first time, macOS asks whether MyBuddy may find and connect to devices on the local network
  (and, if the firewall is on, whether it may accept incoming connections). Both must be allowed.
* Android: no permission is needed while the app targets API 36. Targeting Android 17 (API 37) will need
  the runtime `ACCESS_LOCAL_NETWORK` permission flow first
  (<https://developer.android.com/privacy-and-security/local-network-permission>).
* Screen video uses WebRTC host candidates on the LAN — no STUN/TURN server.

## 2. Tailscale (connect from anywhere)

[Tailscale](https://tailscale.com) is a WireGuard-based private network ("tailnet"). Every device signed in
to your tailnet gets a stable address from `100.64.0.0/10` (100.64.0.0–100.127.255.255) and from
`fd7a:115c:a1e0::/48`, plus an optional MagicDNS name such as `macbook-air.your-tailnet.ts.net`
(sources: Tailscale KB 1015 "100.x addresses", KB 1081 "MagicDNS", KB 1080 "CLI").

When the Mac and the phone are both on your tailnet, the phone can reach MyBuddy on the Mac exactly as on
a LAN — from any Wi-Fi or mobile network — without any MyBuddy server.

**How MyBuddy uses it**

| Side | What happens |
|---|---|
| Mac | Detects Tailscale by its interface addresses (an IPv4 in `100.64.0.0/10`, confirmed by a `fd7a:115c:a1e0::/48` IPv6 on the same interface or by the installed app). With **Settings → Connections → Allow connections over Tailscale** on (default), the pairing QR also carries the Mac's Tailscale address, and the LAN listener accepts connections arriving over the tailnet. With it off, the address is left out and connections from tailnet addresses are refused. |
| Phone | Stores the Tailscale address with the Wi-Fi ones and tries it after them. **Settings → Connections → Add Tailscale address** accepts the Mac's Tailscale IP (`100.x.y.z` or `fd7a:115c:a1e0:…`) or MagicDNS name (`…ts.net`) for a Mac that was paired before Tailscale was set up. Shows whether the Tailscale app is installed and whether a VPN is active, with *Get Tailscale* / *Open Tailscale*. The connection status reads "Connected · Tailscale" or "Connected · Wi-Fi". |
| Video | WebRTC gathers the tailnet interface as an ordinary host candidate, so the stream flows through the WireGuard tunnel — direct when Tailscale has a direct path, via Tailscale's DERP relays otherwise. |

**Security**

* Traffic is encrypted twice: WireGuard (Tailscale) and MBH1 / DTLS-SRTP end-to-end (MyBuddy). Tailscale's
  coordination service sees which devices exist, not MyBuddy's content.
* Being on the tailnet grants nothing by itself: an unpaired device is refused at the MBH1 handshake, a
  paired one still needs each capability enabled on the Mac.
* MagicDNS names are resolved on the phone and every resolved address must lie inside the tailnet ranges;
  otherwise the name is refused. This blocks a `ts.net` name that resolves to a public IP (for example a
  Tailscale Funnel endpoint). MyBuddy never uses Tailscale Funnel or Serve and never exposes its port to
  the public internet.
* Recommended: restrict who in your tailnet may reach the Mac's MyBuddy port (TCP 47811 for control; WebRTC
  video uses ephemeral UDP ports) with Tailscale access controls, for example a grant that allows only
  your own user's devices.
* `100.64.0.0/10` is also used by carrier-grade NAT; a Wi-Fi network that numbers its devices from that
  range looks like a tailnet to MyBuddy. Turning *Allow connections over Tailscale* off would then also
  refuse those LAN connections — the Settings row explains this.

**Setup (one time)**

1. Install Tailscale on the Mac (<https://tailscale.com/download/macos>) and on the phone
   (Google Play: `com.tailscale.ipn`), and sign in to the **same** tailnet on both.
2. On the Mac, *MyBuddy → Settings → Connections* shows "Tailscale · Connected · 100.x.y.z".
3. Pair as usual (the QR then includes the Tailscale address), or — if already paired — on the phone use
   *Settings → Connections → Add Tailscale address* and enter the address shown on the Mac.
4. Away from home: turn on Tailscale on the phone; MyBuddy connects over it automatically.

**Limits**

* Android allows one VPN at a time: Tailscale cannot run alongside another VPN app.
* Tailscale on the phone uses some battery while connected.
* Not yet run on a real tailnet: Tailscale is installed on this Mac but stopped. Once it runs,
  `MyBuddyInteropHost --tailnet` and the live listener test exercise the Mac side; hardware checks T1–T4 in
  `TEST_PLAN.md` cover the phone.

## 3. MyBuddy Connect (internet mode, self-hosted)

For people who don't use Tailscale. You run a small server (`services/connect-api` behind a TLS reverse
proxy, optionally with coturn — `infrastructure/`). It never sees MyBuddy content: it only introduces your
phone to your Mac so they can open a WebRTC connection to each other, and it can relay that connection's
encrypted packets (TURN) when the networks don't allow a direct path.

**What travels where**

| Step | Path | Content |
|---|---|---|
| Sign-in | HTTPS to your server | Device registration with the device's own key (no account, no password), then a 15-minute token from a signed challenge |
| Introduction | WSS `/v1/signal` (server relays) | Signed WebRTC offer/answer and ICE candidates only (`PROTOCOL.md` §7.3) |
| Session | WebRTC data channel `mb-session` — direct (STUN) or via TURN | The normal MBH1 session (resume handshake, then encrypted envelopes), exactly as on Wi-Fi |
| Screen video | Its own WebRTC connection, negotiated inside MBH1, with the same STUN/TURN servers | DTLS-SRTP video |

**Enrolling (once, on the Mac)**

1. Mac: *Settings → Connections → Internet (MyBuddy Connect)*: enter your server's `https://` address and
   turn on *Allow connections over the internet*. The Mac registers its key with the server.
2. While your phone is connected over Wi-Fi or Tailscale, the Mac offers internet access to it
   (`connect.offer`). The phone asks you: *Allow internet access through connect.example.com?*
3. On *Allow*, the phone registers its key and signs the pairing statement; the Mac signs it too and
   registers the pairing (`connect.enroll` → `POST /v1/pairings` → `connect.enrolled`). Both signatures are
   required, so the server alone can never pair devices.

**Connecting away from home.** When neither Wi-Fi nor Tailscale answers, the phone signs in to the server,
sends a signed offer for a data channel, and the Mac — online on the signaling socket while internet access
is on — verifies the signature against the phone's trusted key, answers (signed), and both gather ICE
candidates with the server's STUN/TURN. When the channel opens, the usual MBH1 resume handshake runs inside
it; the Mac treats the session like any other (same approval rules, capabilities, Emergency Stop).

**Direct vs relayed.** After the connection forms, both apps read the selected ICE candidate pair:
"Connected · Internet" (direct) or "Connected · Internet (relayed)" when a TURN relay carries the packets.
In relayed sessions **file transfer is off** (no file bytes through a server, even encrypted); everything
else works. Screen video then also goes through TURN.

**Security**

* The server can't read or alter sessions: offers/answers are signed with the device keys (a compromised
  server can't swap the DTLS fingerprints), and MBH1 inside the channel pins both keys again.
* Offers are accepted only from phones the Mac trusts (and not revoked), only within ±2 minutes, and each
  rendezvous id only once. Turning internet access off ends internet sessions and refuses new ones.
* Tokens are short-lived and kept in memory only; the device keys stay in Keychain / Keystore. The TURN
  shared secret never leaves the server: credentials are HMAC-derived per device and expire (default 12 h).
  They can't be renewed inside a running relay allocation, so a relayed session older than that drops and
  the phone reconnects on its own with fresh credentials (a few seconds).
* Metadata the server sees: which devices are paired, when they are online, their IP addresses.

**Status.** Built on both apps. Verified on the Android emulator against a local `connect-api` (in-memory store)
and `services/devturn` (development TURN relay, loopback only): enrolment with consent on the phone, reconnect
over the internet after the local listener closed ("Connected · Internet", direct path), screen video and
touch input over it, the forced-relay path ("Connected · Internet (relayed)" on the phone, `internetRelayed` on
the Mac, video "Relayed (TURN) · relay ↔ host"), file transfer refused on the relayed session (both
directions), revocation from the phone ending the session, the Mac going offline (8 bounded retries, then "Your
Mac isn't online…"), and Wi-Fi sessions working with the server down. Not yet run: a public deployment, a phone
on mobile data, a Mac behind a different NAT (hardware checks I1–I4 in `TEST_PLAN.md`).

**Setup and local testing** — `infrastructure/README.md` (deployment), `TEST_PLAN.md` §3.1 step 9 (the
emulator against a local server and a development TURN relay).

## 4. What each app shows (icons)

Only system icon sets are used (SF Symbols on the Mac, Material Symbols on Android) — no third-party logos.

| Row | Mac (SF Symbol) | Android (Material) | States |
|---|---|---|---|
| Same network | `wifi` | `Wifi` | Listening on *address* / Not listening · Connected over Wi-Fi |
| Tailscale | `point.3.connected.trianglepath.dotted` | `VpnLock` | Connected · *100.x.y.z* / Installed, not connected / Not installed / Off in Settings |
| MyBuddy Connect | `globe` | `Public` | Not set up / Signing in / Online · *server* / Offered — waiting for the phone / Enrolled / Connected · Internet (direct or relayed) / Error with the reason |

## 5. Address rules (enforced on both platforms)

| Where an address comes from | Accepted |
|---|---|
| Pairing QR / link (`h=`) | 1–4 IP literals in loopback, RFC 1918, link-local, CGNAT/Tailscale `100.64.0.0/10`, ULA `fc00::/7` (incl. Tailscale `fd7a:115c:a1e0::/48`), or `.local` names. Public addresses are rejected (`PROTOCOL.md` §6.1). |
| Bonjour discovery (phone) | Only from a service whose TXT `fp` matches the paired Mac; same address classes as above; IPv6 link-local skipped (needs an interface scope). |
| *Add Tailscale address* (phone) | `100.64.0.0/10` or `fd7a:115c:a1e0::/48` literals, or a `*.ts.net` name that resolves only to those ranges (the resolved IP is dialled, not the name). |

## 6. iOS

An iOS controller is not part of the current build and **cannot be built on this Mac**: Xcode is not
installed and the Command Line Tools have no iOS SDK, so nothing iOS-specific could be compiled, run or
tested here. The design is ready for it when Xcode is available:

* SwiftUI app reusing `MyBuddyCore` unchanged (envelope codec, MBH1, pairing, intents and policies are
  Foundation/CryptoKit only) — add `.iOS(.v17)` to `Package.swift` and an Xcode app target.
* Identity in the Secure Enclave (Keychain, `kSecAttrTokenIDSecureEnclave`), as on the Mac.
* Transport: `URLSessionWebSocketTask`/`NWConnection` with the same MBH1 frames; LAN discovery with
  `NWBrowser` (`NSLocalNetworkUsageDescription` + `NSBonjourServices` = `_mybuddy._tcp`).
* Video: the same LiveKitWebRTC XCFramework (it ships an iOS slice) with `LKRTCMTLVideoView`.
* Tailscale works the same way on iOS (Tailscale's iOS app provides the VPN).
* First steps: install Xcode, create the app target, port the Android screens' state model, run the shared
  fixtures/vectors in XCTest/Swift Testing on the simulator.
