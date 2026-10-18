# Manual end-to-end test — MacBook Air M1 + Vivo X300

A walk-through for the first real-device run. Each step names the check ID from `TEST_PLAN.md` §5 so results can
be recorded there (pass / fail, date, build). Everything here was exercised on the Android emulator against the
real Mac code; **none of it has run on the Vivo X300 yet**. Budget about 90 minutes.

## 0. Prepare

**Mac**
1. `make build-mac-app` (or a Developer ID build, `RELEASE.md` §1) and copy `apps/macos/MyBuddyMac/build/MyBuddy.app`
   to /Applications. Open it; allow "find devices on your local network" when macOS asks.
2. System Settings → Privacy & Security: you will add MyBuddy to **Screen Recording** (step 4) and
   **Accessibility** (step 5) when the app asks — not before. Ad-hoc builds lose these after a rebuild.

**Vivo X300 (OriginOS)**
1. Settings → About phone → tap *Software version* 7× → Developer options → **USB debugging** on; connect USB and
   accept the computer's key.
2. `make build-android && adb install -r apps/android/MyBuddyAndroid/app/build/outputs/apk/debug/app-debug.apk`
   (or a signed release APK, `RELEASE.md` §2).
3. Battery: Settings → Battery → Background power consumption management → MyBuddy → **Allow** (OriginOS
   otherwise stops background apps aggressively; this matters for notification mirroring and transfers).
4. Phone and Mac on the same Wi-Fi (not a guest network with client isolation).

## 1. Pair (H1–H6)

1. Mac: Overview → **Pair a phone** → a QR code with a 2-minute timer.
2. Phone: **Scan pairing code** → allow the camera → point at the QR. Both screens show the same 6-digit code.
   Mac: approve. → both say Paired; phone Home shows *Connected · Wi-Fi* and this Mac's battery/storage. (H1, H2, H6)
3. Repeat once and **Reject** on the Mac → phone "Pairing declined" (H3). Wait > 2 min on a QR → "expired" (H4).
4. Mac: Settings → Devices → Revoke → phone can't reconnect ("no longer trusts this phone") (H5); pair again.

## 2. Screen and control (H7–H9, H13)

1. Phone: Remote → **View screen**. Mac asks for Screen Recording → *Allow…* in System Settings, relaunch if asked,
   retry. → the real screen on the phone, *Live*, fps/bitrate/RTT, path *Direct*, decoder *hardware*; macOS shows
   its recording indicator; the Mac's Remote Desktop shows the same picture. Try quality chips, Fit/Fill, full
   screen, pinch-zoom/pan. (H7)
2. Mac: *Choose What to Share…* → one window → only that window is streamed (H7b).
3. Mac: Devices → enable *Control mouse & keyboard*; allow Accessibility when asked. Phone: Control → tap,
   double-tap, long-press, drag, two-finger scroll, touchpad, type. Clicks land under your finger. Emergency Stop
   (Mac sidebar) ends everything at once. (H8) Hold a modifier, then turn Wi-Fi off on the phone → the Mac releases
   it within ~15 s (H9).
4. Remove Screen Recording / Accessibility in System Settings → the Mac shows "not authorized" with a fix (H13).

## 3. Files and clipboard (F1–F5)

1. Mac: Files & Clipboard → Grant Folder Access (e.g. Documents/Test); Devices → allow *Browse shared folders* and
   *Send & receive files*. Phone: Files → the folder → a file → **Download** → Downloads/MyBuddy, checksum
   verified; *Open* works. (F1)
2. Phone: **Send a file to your Mac** → pick a photo → Mac: Accept → in ~/Downloads (F2). Mac: *Send File to
   Phone…* → phone Save / Decline (F3).
3. A ~1 GB file: start, press Home, lock the phone → progress notification (allow notifications when asked) →
   completes (F4).
4. Clipboard: try Off / Ask / Automatic on the phone; copy on the Mac; *Send this phone's clipboard*; copy a
   password from a password manager on the Mac → never synced automatically (F5).

## 4. Reconnecting and Tailscale (H10, H14, T1–T4)

1. Lock the phone for 5 minutes with MyBuddy open → it reconnects on unlock (H10).
2. Give the Mac a new IP (renew DHCP lease) → the phone finds it again (H14).
3. Tailscale on both, same tailnet → Mac Settings → Connections shows *Ready · 100.x*; pair or *Add address* on the
   phone; phone on mobile data → *Connected · Tailscale* (T1–T3). Turn *Allow connections over Tailscale* off →
   refused (T4).

## 5. Internet through MyBuddy Connect (I1–I4, H12)

Needs your deployed server (`infrastructure/README.md`).
1. `https://<your-domain>/healthz` → `{"status":"ok"}` (I1).
2. Mac: Settings → Connections → Internet → your address → **Turn On** → *Online*. Phone (on Wi-Fi): *Internet
   access offered* → **Allow** (I2).
3. Phone on mobile data, Wi-Fi and Tailscale off → *Connected · Internet*; health, screen, control work (I3).
   Debug build: *Force TURN relay* → *Connected · Internet (relayed)*, Files says transfers need a direct
   connection (H12).
4. Mac: *Remove Internet Access* → the phone's internet session ends with a clear reason (I4).

## 6. Notifications (N1–N3)

1. Mac: Devices → allow *Mirror notifications*. Phone: Settings → Notifications on your Mac → **Open Android
   settings** → allow notification access (OriginOS may say "restricted": App info → ⋮ → Allow restricted
   settings) → back → switch **Mirror notifications to your Mac** on. Send yourself a message → the Mac's
   Notifications page shows only the app name (default preview) (N1).
2. Choose *Title and text*; receive an SMS one-time code → the Mac shows it masked. Turn Do Not Disturb on →
   nothing arrives. Block an app in the list → its notifications stop (N2).
3. Mac on battery below 15 % (or wait for it) → the phone gets "Mac battery low"; put the Mac to sleep → "Your Mac
   is going to sleep" (N3). Lock the phone for 10 minutes with mirroring on → notifications still arrive.

## 7. Voice and AI (H11)

Phone: hold the orb, say "show my Mac battery health" → caption, spoken answer; risky intents ask for approval on
the Mac. AI: needs a provider key entered on the Mac (Settings → AI providers) — the phone never holds keys.

## Record

Fill in `TEST_PLAN.md` §5 (status, date, build) and add anything that failed to `IMPLEMENTATION_LOG.md`.
