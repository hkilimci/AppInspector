#!/usr/bin/env bash
# Builds the signed Sparkle feed (appcast.xml at the repo root) for one release.
#   Tools/make-update-feed.sh <version> <release-notes.html>
# Needs build/AppInspector-<version>.zip from Tools/release.sh, and the EdDSA key in the login Keychain
# under Sparkle account dev.appinspector.AppInspector. The private key never leaves the Keychain.
#
# The feed lists only the newest release: every App Inspector release needs the same macOS version, so
# older entries would never be offered. Publish in this order, so the feed never points at a missing file:
#   1. gh release create v<version> build/AppInspector-<version>.dmg build/AppInspector-<version>.zip
#   2. commit and push appcast.xml
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: make-update-feed.sh <version> <release-notes.html>}"
NOTES="${2:?usage: make-update-feed.sh <version> <release-notes.html>}"
ACCOUNT=dev.appinspector.AppInspector
BIN="${SPARKLE_BIN_DIR:-App/.build/artifacts/sparkle/Sparkle/bin}"
[ -x "$BIN/generate_appcast" ] || (cd App && swift package resolve >/dev/null)
ZIP="build/AppInspector-$VERSION.zip"
[ -f "$ZIP" ] || { echo "missing $ZIP: run Tools/release.sh first" >&2; exit 1; }
[ -f "$NOTES" ] || { echo "missing release notes: $NOTES" >&2; exit 1; }

WORK="build/UpdateFeed-$VERSION"
rm -rf "$WORK" && mkdir -p "$WORK"
cp "$ZIP" "$WORK/"
cp "$NOTES" "$WORK/AppInspector-$VERSION.html"   # same base name as the archive, so it's picked up
"$BIN/generate_appcast" --account "$ACCOUNT" \
  --download-url-prefix "https://github.com/hkilimci/AppInspector/releases/download/v$VERSION/" \
  --embed-release-notes \
  --full-release-notes-url "https://github.com/hkilimci/AppInspector/releases" \
  --link "https://azrapps.com/AppInspector/" \
  --maximum-deltas 0 \
  "$WORK"
"$BIN/sign_update" --account "$ACCOUNT" --verify "$WORK/appcast.xml"
cp "$WORK/appcast.xml" appcast.xml
echo "appcast.xml updated and verified. Publish the GitHub release first, then commit and push appcast.xml."
