#!/usr/bin/env bash
# Release build: Developer ID signing, hardened runtime, notarization, stapling, DMG.
#
#   DEVELOPER_ID_APP="Developer ID Application: Name (TEAMID)" \
#   NOTARY_PROFILE="appinspector-notary" \
#   Tools/release.sh [version]
#
# One-time setup of the notary profile (stores credentials in the login keychain, never in this repo):
#   xcrun notarytool store-credentials appinspector-notary --apple-id <id> --team-id <TEAMID>
#
# Exit criterion (plan §8, Phase 3): the notarized build passes the full test matrix. This script only builds,
# signs and notarizes; run Tools/self-audit.sh and the test matrix on the result.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-0.1.0}"
: "${DEVELOPER_ID_APP:?set DEVELOPER_ID_APP to your 'Developer ID Application: …' identity (see: security find-identity -v -p codesigning)}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile}"

security find-identity -v -p codesigning | grep -F "$DEVELOPER_ID_APP" >/dev/null \
  || { echo "identity not found in keychain: $DEVELOPER_ID_APP" >&2; exit 1; }

ROOT="$PWD"
APP="$ROOT/build/AppInspector.app"; DMG="$ROOT/build/AppInspector-$VERSION.dmg"; ZIP="$ROOT/build/AppInspector-$VERSION.zip"
Tools/make-app-bundle.sh "$APP" >/dev/null            # absolute path: the script changes directory
[ -x "$APP/Contents/MacOS/AppInspector" ] || { echo "bundle was not created at $APP" >&2; exit 1; }
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"

# Hardened runtime, no sandbox (the app must read system databases), no extra entitlements.
codesign --force --timestamp --options runtime --entitlements Tools/AppInspector.entitlements \
  --sign "$DEVELOPER_ID_APP" "$APP"
codesign --verify --strict --verbose=2 "$APP"

ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vv -t exec "$APP"

rm -rf "$ROOT/build/dmg" && mkdir -p "$ROOT/build/dmg" && cp -R "$APP" "$ROOT/build/dmg/" && ln -s /Applications "$ROOT/build/dmg/Applications"
hdiutil create -volname "App Inspector" -srcfolder "$ROOT/build/dmg" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$DEVELOPER_ID_APP" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
echo "done: $DMG"
