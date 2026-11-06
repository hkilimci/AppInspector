#!/usr/bin/env bash
# Dev-only: wraps the SwiftPM build into AppInspector.app (ad-hoc signed) so Full Disk Access
# can be granted to the app itself instead of Terminal. Shipping build = Xcode project, Developer ID + notarization.
set -euo pipefail
CALLER="$PWD"
cd "$(dirname "$0")/../App"
# APPINSPECTOR_UNIVERSAL=1 builds for Apple silicon and Intel (release builds); dev builds use the host only.
ARCH_FLAGS=()
[ "${APPINSPECTOR_UNIVERSAL:-0}" = 1 ] && ARCH_FLAGS=(--arch arm64 --arch x86_64)
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/AppInspector"
OUT="${1:-../build/AppInspector.app}"
case "${1:-}" in /*) ;; "") ;; *) OUT="$CALLER/$1" ;; esac   # a relative argument is relative to where the user ran the script
rm -rf "$OUT"; mkdir -p "$OUT/Contents/MacOS"
cp "$BIN" "$OUT/Contents/MacOS/AppInspector"
mkdir -p "$OUT/Contents/Resources"
cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"   # regenerate with Tools/make-icon.sh
cat >"$OUT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.appinspector.AppInspector</string>
  <key>CFBundleName</key><string>App Inspector</string>
  <key>CFBundleExecutable</key><string>AppInspector</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# A real identity keeps the designated requirement stable across rebuilds, so the Full Disk Access grant
# survives. Ad-hoc signatures change with every build and macOS then treats the app as a new one.
# Override with APPINSPECTOR_SIGN_IDENTITY (a name or SHA-1); falls back to ad-hoc when no identity exists.
IDENTITY="${APPINSPECTOR_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | awk '/Apple Development|Developer ID Application/ { print $2; exit }')}"
codesign --force --options runtime --entitlements ../Tools/AppInspector.entitlements \
  --sign "${IDENTITY:--}" "$OUT"
codesign -dv "$OUT" 2>&1 | grep -E "Identifier|flags"
echo "built $OUT"
