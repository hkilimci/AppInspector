#!/usr/bin/env bash
# Wraps the SwiftPM build into AppInspector.app, so Full Disk Access can be granted to the app itself.
# Tools/release.sh builds on this for Developer ID, notarized releases.
#   APPINSPECTOR_VERSION (default 0.1.0) and APPINSPECTOR_BUILD (default 1) set the bundle versions;
#   the build number must grow with every release, because Sparkle compares it.
set -euo pipefail
CALLER="$PWD"
cd "$(dirname "$0")/../App"
# APPINSPECTOR_UNIVERSAL=1 builds for Apple silicon and Intel (release builds); dev builds use the host only.
ARCH_FLAGS=()
[ "${APPINSPECTOR_UNIVERSAL:-0}" = 1 ] && ARCH_FLAGS=(--arch arm64 --arch x86_64)
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BINDIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"
BIN="$BINDIR/AppInspector"
VERSION="${APPINSPECTOR_VERSION:-0.1.0}"; BUILD="${APPINSPECTOR_BUILD:-1}"
OUT="${1:-../build/AppInspector.app}"
case "${1:-}" in /*) ;; "") ;; *) OUT="$CALLER/$1" ;; esac   # a relative argument is relative to where the user ran the script
rm -rf "$OUT"; mkdir -p "$OUT/Contents/MacOS"
cp "$BIN" "$OUT/Contents/MacOS/AppInspector"
# Sparkle: embed the framework and look for it in Contents/Frameworks. Its XPC services are only for
# sandboxed apps, and App Inspector isn't sandboxed, so they are left out (as Sparkle documents).
mkdir -p "$OUT/Contents/Frameworks"
ditto "$BINDIR/Sparkle.framework" "$OUT/Contents/Frameworks/Sparkle.framework"
rm -rf "$OUT/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$OUT/Contents/Frameworks/Sparkle.framework/XPCServices"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$OUT/Contents/MacOS/AppInspector"
# Drop build-machine toolchain paths from the search list; Swift itself comes from /usr/lib/swift.
for r in $(otool -l "$OUT/Contents/MacOS/AppInspector" | awk '/LC_RPATH/{getline; getline; print $2}' | grep '^/Applications/Xcode' || true); do
  install_name_tool -delete_rpath "$r" "$OUT/Contents/MacOS/AppInspector"
done
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
  <key>CFBundleShortVersionString</key><string>VERSION_PLACEHOLDER</string>
  <key>CFBundleVersion</key><string>BUILD_PLACEHOLDER</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Sparkle. The updater only starts when release.sh adds AppInspectorDistribution=release. -->
  <key>SUFeedURL</key><string>https://raw.githubusercontent.com/hkilimci/AppInspector/main/appcast.xml</string>
  <key>SUPublicEDKey</key><string>U8eaZtyGxl6XOv+xOE4oIWywioo60RiUZWm8QUXrTaE=</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
  <key>SUVerifyUpdateBeforeExtraction</key><true/>
  <key>SURequireSignedFeed</key><true/>
  <key>SUEnableSystemProfiling</key><false/>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$OUT/Contents/Info.plist"
# A real identity keeps the designated requirement stable across rebuilds, so the Full Disk Access grant
# survives. Ad-hoc signatures change with every build and macOS then treats the app as a new one.
# Override with APPINSPECTOR_SIGN_IDENTITY (a name or SHA-1); falls back to ad-hoc when no identity exists.
IDENTITY="${APPINSPECTOR_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | awk '/Apple Development|Developer ID Application/ { print $2; exit }')}"
../Tools/sign-bundle.sh "$OUT" "${IDENTITY:--}"
codesign -dv "$OUT" 2>&1 | grep -E "Identifier|flags"
echo "built $OUT"
