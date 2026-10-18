# Release guide

How to produce builds other people can install. **Signing material never enters the repository**:
certificates live in your login keychain, the Android keystore and its passwords live outside the repo (the
`.gitignore` and `scripts/secret-scan.sh` refuse `*.jks`, `*.keystore`, `*.p12`, `*.p8`, `*.pem`, `*.key`,
`.env`). Nothing below puts a password on a command line.

Current version: Mac `0.1.0 (1)` (`Resources/Info.plist`), Android `0.1.0 (1)` (`app/build.gradle.kts`).
Bump both together.

## 1. Mac app (Developer ID + notarization)

Development builds are ad-hoc signed (`make build-mac-app`): fine on this Mac, but macOS asks again for Screen
Recording / Accessibility after every rebuild and other Macs refuse to open them. Distribution needs:

1. **A Developer ID Application certificate** (Apple Developer Program → Certificates; create it with
   Keychain Access or Xcode on any Mac). It sits in your login keychain; check with
   `security find-identity -v -p codesigning`.
2. **Build and sign** (hardened runtime, secure timestamp, `Resources/MyBuddy.entitlements` — microphone only):
   ```sh
   MYBUDDY_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" apps/macos/MyBuddyMac/scripts/build-app.sh
   ```
   The script signs the embedded `LiveKitWebRTC.framework` first, then the app, and verifies with
   `codesign --verify --strict --deep`.
3. **Notarize and staple** — store an app-specific password once, in your keychain:
   ```sh
   xcrun notarytool store-credentials "mybuddy-notary" --apple-id you@example.com --team-id TEAMID
   MYBUDDY_NOTARY_PROFILE=mybuddy-notary apps/macos/MyBuddyMac/scripts/notarize.sh
   ```
   The script refuses ad-hoc or non-hardened builds, submits with `notarytool --wait`, staples, and checks
   `spctl --assess`. `notarytool` and `stapler` ship with the Command Line Tools (verified present here).
4. **Ship** the stapled `MyBuddy.app` in a zip (`ditto -c -k --keepParent`) or a DMG; publish its SHA-256.

Notes
* Entitlements stay minimal: `com.apple.security.device.audio-input`. Screen Recording and Accessibility are
  user-granted TCC permissions, not entitlements; there is no App Sandbox (ScreenCaptureKit, CGEvent injection and
  the LAN listener run outside it) and no JIT / unsigned-memory / library-validation exceptions.
* **Don't add the hardened runtime to ad-hoc builds.** Library validation then refuses the embedded WebRTC
  framework ("mapping process and mapped file have different Team IDs" — verified here); a Developer ID signature
  gives app and framework the same Team ID, which is what makes it load.
* Not verified here: no Developer ID certificate exists on this Mac, so steps 2–4 have not been run end to end.
  The ad-hoc path, the script guards and the entitlements file were checked.
* Without Xcode the app is a SwiftPM bundle; an Xcode project is optional and only changes where signing settings
  live.

## 2. Android app (release APK / App Bundle)

1. **Create an upload/release key once**, outside the repository, and back it up offline:
   ```sh
   keytool -genkeypair -keystore ~/keys/mybuddy-release.jks -alias mybuddy -keyalg EC -groupname secp256r1 -validity 9125
   ```
   (keytool prompts for the passwords.)
2. **Describe it in a properties file outside the repo** (readable only by you, `chmod 600`):
   ```properties
   storeFile=/Users/you/keys/mybuddy-release.jks
   storePassword=…
   keyAlias=mybuddy
   keyPassword=…
   ```
3. **Build**:
   ```sh
   cd apps/android/MyBuddyAndroid
   MYBUDDY_KEYSTORE_PROPERTIES=~/keys/mybuddy-signing.properties ./gradlew assembleRelease   # APK
   MYBUDDY_KEYSTORE_PROPERTIES=~/keys/mybuddy-signing.properties ./gradlew bundleRelease     # AAB for Play
   ```
   Without `MYBUDDY_KEYSTORE_PROPERTIES`, `assembleRelease` produces `app-release-unsigned.apk`.
4. **Verify**: `apksigner verify --print-certs app-release.apk`; publish the APK's SHA-256 and the signing
   certificate fingerprint so people can check what they install.
5. For Google Play, enrol in Play App Signing (Google keeps the app signing key; yours becomes the upload key).

Notes
* Release builds run R8 (minify + resource shrinking; APK ≈ 17 MB vs ≈ 91 MB debug). libwebrtc ships no R8 rules
  and finds Java classes by name through JNI, so `proguard-rules.pro` keeps `org.webrtc.**` and `org.jni_zero.**`.
  Without the second rule the release build aborted with `ClassNotFoundException: org.jni_zero.JniZero` as soon as
  video started — found and fixed in session 4; after the fix a locally signed release APK paired, loaded health
  and streamed H.264 video on the emulator with no crash.
* Release builds accept only `https://` MyBuddy Connect servers (plain http is a debug-build convenience for
  local testing).
* Sideloaded installs: on Android 13+ the notification-access switch can show "Restricted setting" until the user
  allows it in App info → ⋮ → Allow restricted settings. Play installs don't have this.
* `targetSdk` stays 36 until the Android 17 local-network permission flow is built and tested (see
  `CONNECTIVITY.md` §1).

## 3. MyBuddy Connect server

`infrastructure/README.md` (Docker Compose with Caddy TLS, Postgres, coturn). Secrets are generated on the server
by `scripts/init-secrets.sh` into files mounted as Docker secrets; pin image digests for production.

## 4. Before every release

Run `docs/RELEASE_CHECKLIST.md`: automated suites, secret scan, license review, the manual device checks, and the
verified / unverified / platform-limited list that goes into the release notes.
