#!/usr/bin/env bash
# Regenerates App/Resources/AppIcon.icns from Tools/make-icon.swift (all macOS icon sizes, 16–1024 px).
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swift Tools/make-icon.swift "$WORK/master.png" >/dev/null
SET="$WORK/AppIcon.iconset"; mkdir "$SET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$WORK/master.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$WORK/master.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
mkdir -p App/Resources
iconutil -c icns "$SET" -o App/Resources/AppIcon.icns
echo "wrote App/Resources/AppIcon.icns"
