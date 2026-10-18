#!/usr/bin/env bash
# Builds MyBuddy.app from the SwiftPM package (no Xcode needed) and signs it.
#   scripts/build-app.sh            → build/MyBuddy.app (release, ad-hoc signed)
#   scripts/build-app.sh --debug    → debug build
#   MYBUDDY_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/build-app.sh
#                                   → Developer ID signature, hardened runtime, secure timestamp and
#                                     Resources/MyBuddy.entitlements; then scripts/notarize.sh (docs/RELEASE.md)
# Ad-hoc signatures change on every build, so macOS may ask again for Screen Recording /
# Accessibility after rebuilding; a stable Developer ID signature keeps those grants.
set -euo pipefail
PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG=release
[[ "${1:-}" == "--debug" ]] && CONFIG=debug

swift build --package-path "$PKG" -c "$CONFIG" --product MyBuddy
BIN_DIR="$(swift build --package-path "$PKG" -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/MyBuddy"

APP="$PKG/build/MyBuddy.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MyBuddy"
cp "$PKG/Resources/Info.plist" "$APP/Contents/Info.plist"

# libwebrtc (LiveKitWebRTC, BSD-3-Clause + MIT packaging) ships inside the bundle; headers are not needed at runtime.
FW="$APP/Contents/Frameworks/LiveKitWebRTC.framework"
mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/Resources/Licenses"
ditto "$BIN_DIR/LiveKitWebRTC.framework" "$FW"
rm -rf "$FW/Headers" "$FW/Modules" "$FW/Versions/A/Headers" "$FW/Versions/A/Modules"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/MyBuddy"
LICENSE_SRC="$(find "$PKG/.build/artifacts" -path '*LiveKitWebRTC.xcframework/LICENSE' -print -quit)"
[[ -n "$LICENSE_SRC" ]] && cp "$LICENSE_SRC" "$APP/Contents/Resources/Licenses/WebRTC-LICENSE.txt"

# App icon rendered from the BrandMark component.
ICONSET="$PKG/build/AppIcon.iconset"
rm -rf "$ICONSET"
"$BIN" --render-icon "$ICONSET" >/dev/null 2>&1 || true
if [[ -f "$ICONSET/icon_512x512@2x.png" ]] && command -v iconutil >/dev/null; then
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

# Sign inside-out: the embedded framework, then the app.
IDENTITY="${MYBUDDY_SIGN_IDENTITY:-}"
if [[ -n "$IDENTITY" ]]; then
  # Identity names a certificate in the login keychain; no secret ever passes through this script.
  ENT="$PKG/Resources/MyBuddy.entitlements"
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$FW"
  codesign --force --sign "$IDENTITY" --options runtime --timestamp --entitlements "$ENT" "$APP"
  codesign --verify --strict --deep "$APP"
  echo "Built $APP ($CONFIG, signed by \"$IDENTITY\", hardened runtime) — next: scripts/notarize.sh"
else
  codesign --force --sign - --timestamp=none "$FW"
  codesign --force --sign - --timestamp=none "$APP"
  codesign --verify --strict "$APP"
  echo "Built $APP ($CONFIG, ad-hoc signed)"
fi
