#!/usr/bin/env bash
# Notarizes and staples a Developer ID–signed build/MyBuddy.app (docs/RELEASE.md).
#   One-time: xcrun notarytool store-credentials "mybuddy-notary" --apple-id <id> --team-id <TEAMID>
#             (prompts for an app-specific password and keeps it in your login keychain — never in this repo)
#   Then:     MYBUDDY_NOTARY_PROFILE=mybuddy-notary scripts/notarize.sh
set -euo pipefail
PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$PKG/build/MyBuddy.app"
PROFILE="${MYBUDDY_NOTARY_PROFILE:?set MYBUDDY_NOTARY_PROFILE to the keychain profile created with notarytool store-credentials}"

[[ -d "$APP" ]] || { echo "No $APP — run scripts/build-app.sh with MYBUDDY_SIGN_IDENTITY first." >&2; exit 1; }
if codesign -dv "$APP" 2>&1 | grep -q "Signature=adhoc"; then
  echo "$APP is ad-hoc signed; notarization needs a Developer ID signature (MYBUDDY_SIGN_IDENTITY)." >&2
  exit 1
fi
codesign -dv --verbose=2 "$APP" 2>&1 | grep -q "runtime" || { echo "Hardened runtime missing; rebuild with MYBUDDY_SIGN_IDENTITY." >&2; exit 1; }

ZIP="$PKG/build/MyBuddy-notarize.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
rm -f "$ZIP"
echo "Notarized and stapled: $APP"
