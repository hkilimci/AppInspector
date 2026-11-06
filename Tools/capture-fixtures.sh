#!/usr/bin/env bash
# Phase 0 fixture capture. Run INSIDE a test VM (15.x / 26.x / 27.x).
#
#   Tools/capture-fixtures.sh [--out DIR] [--btm] [--tcc] [--vm]
#
#   --btm  also run `sudo sfltool dumpbtm` (needs sudo)
#   --tcc  also copy TCC.db files. Refused unless --vm is given: TCC.db is
#          never copied from a user's real machine.
#   --login-items  also query System Events (triggers an Automation prompt)
#   --vm   assert this is a disposable test VM
#
# Without flags: read-only, no sudo, no TCC.db, no browser profiles.
# Every command's failure is recorded (exit code + stderr), never fatal:
# "this source is unavailable on this OS" is itself a Phase 0 result.
set -u

OUT=""; WANT_LI=0; WANT_BTM=0; WANT_TCC=0; IS_VM=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --btm) WANT_BTM=1; shift ;;
    --login-items) WANT_LI=1; shift ;;
    --tcc) WANT_TCC=1; shift ;;
    --vm)  IS_VM=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ "$WANT_TCC" = 1 ] && [ "$IS_VM" != 1 ]; then
  echo "refusing --tcc without --vm (TCC.db is VM-only)" >&2; exit 2
fi

BUILD="$(sw_vers -buildVersion)"
VER="$(sw_vers -productVersion)"
ARCH="$(uname -m)"
OUT="${OUT:-fixtures/${VER}-${BUILD}-${ARCH}}"
mkdir -p "$OUT"

# cap NAME CMD... : run, save stdout to NAME.txt, stderr+exit code to NAME.meta
cap() {
  local name="$1"; shift
  local rc
  "$@" >"$OUT/$name.txt" 2>"$OUT/$name.err"; rc=$?
  {
    echo "cmd: $*"
    echo "exit: $rc"
    echo "stdout_bytes: $(wc -c <"$OUT/$name.txt" | tr -d ' ')"
    echo "stderr_bytes: $(wc -c <"$OUT/$name.err" | tr -d ' ')"
  } >"$OUT/$name.meta"
  [ -s "$OUT/$name.err" ] || rm -f "$OUT/$name.err"
  printf '%-28s exit=%s\n' "$name" "$rc"
}

{
  echo "macOS $VER ($BUILD) $ARCH"
  echo "captured: $(date -u +%FT%TZ)"
  echo "vm_asserted: $IS_VM"
  echo "uid: $(id -u)"
  echo "sip: $(csrutil status 2>&1)"
  echo "hw_model: $(sysctl -n hw.model 2>&1)"
  echo "virtual: $(sysctl -n kern.hv_vmm_present 2>&1)"
} >"$OUT/host.txt"

UIDN="$(id -u)"

# Extensions
cap pluginkit-all        pluginkit -mAvvv
cap pluginkit-election   pluginkit -mAD
cap systemextensions     systemextensionsctl list

# Startup / background items
cap launchctl-print-gui    launchctl print "gui/$UIDN"
cap launchctl-print-system launchctl print system
cap launchctl-disabled-gui launchctl print-disabled "gui/$UIDN"
cap launchctl-disabled-sys launchctl print-disabled system
cap launchctl-list-user    launchctl list

# Per-job detail for user agents
mkdir -p "$OUT/jobs"
for dir in "$HOME/Library/LaunchAgents" /Library/LaunchAgents /Library/LaunchDaemons; do
  [ -d "$dir" ] || continue
  for p in "$dir"/*.plist; do
    [ -e "$p" ] || continue
    label="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$p" 2>/dev/null)"
    [ -n "$label" ] || continue
    case "$dir" in
      /Library/LaunchDaemons) dom="system" ;;
      *) dom="gui/$UIDN" ;;
    esac
    launchctl print "$dom/$label" >"$OUT/jobs/${label}.txt" 2>&1
    cp "$p" "$OUT/jobs/${label}.plist" 2>/dev/null
  done
done

# Login items (legacy API view)
[ "$WANT_LI" = 1 ] && cap loginitems-osascript osascript -e 'tell application "System Events" to get the name of every login item'

# Installed apps (identity, no secrets)
cap apps-spotlight mdfind "kMDItemContentType == 'com.apple.application-bundle'"
cap apps-system_profiler system_profiler SPApplicationsDataType -json

# TCC: schema only, unless explicitly allowed on a VM
USER_TCC="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
SYS_TCC="/Library/Application Support/com.apple.TCC/TCC.db"
cap tccutil-help tccutil help
cap tccutil-list tccutil list
if [ "$WANT_TCC" = 1 ]; then
  mkdir -p "$OUT/tcc"
  cp "$USER_TCC" "$OUT/tcc/user-TCC.db" 2>"$OUT/tcc/user.err"
  sudo cp "$SYS_TCC" "$OUT/tcc/system-TCC.db" 2>"$OUT/tcc/system.err"
  for db in "$OUT"/tcc/*.db; do
    [ -e "$db" ] || continue
    sqlite3 "$db" ".schema" >"$db.schema.txt" 2>&1
    sqlite3 "$db" "select value from admin where key='version'" >"$db.version.txt" 2>&1
  done
fi

# MDM / managed state
cap profiles-list profiles list
cap profiles-show profiles show -type configuration

# BTM (needs root)
if [ "$WANT_BTM" = 1 ]; then
  cap sfltool-dumpbtm sudo sfltool dumpbtm
fi
ls -la /private/var/db/com.apple.backgroundtaskmanagement/ >"$OUT/btm-dir-listing.txt" 2>&1

# System Settings deep-link probes: record what the URL handler resolves, don't open.
cap lsregister-systemprefs bash -c \
  "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -dump | grep -A3 'x-apple.systempreferences' | head -50"

echo "done -> $OUT"
