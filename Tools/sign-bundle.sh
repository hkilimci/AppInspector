#!/usr/bin/env bash
# Signs AppInspector.app inside-out: Sparkle's helpers, then the framework, then the app.
#   Tools/sign-bundle.sh <path/to/AppInspector.app> <identity> [--timestamp]
# Hardened runtime everywhere. No --deep: each nested component is signed explicitly, as Sparkle documents.
set -euo pipefail
APP="${1:?usage: sign-bundle.sh <app> <identity> [--timestamp]}"
ID="${2:?usage: sign-bundle.sh <app> <identity> [--timestamp]}"
TS=(); [ "${3:-}" = "--timestamp" ] && TS=(--timestamp)
ENT="$(cd "$(dirname "$0")" && pwd)/AppInspector.entitlements"
FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$FW" ]; then
  codesign --force ${TS[@]+"${TS[@]}"} --options runtime --sign "$ID" "$FW/Versions/B/Autoupdate"
  codesign --force ${TS[@]+"${TS[@]}"} --options runtime --sign "$ID" "$FW/Versions/B/Updater.app"
  codesign --force ${TS[@]+"${TS[@]}"} --options runtime --sign "$ID" "$FW"
fi
codesign --force ${TS[@]+"${TS[@]}"} --options runtime --entitlements "$ENT" --sign "$ID" "$APP"
codesign --verify --strict --deep "$APP"
