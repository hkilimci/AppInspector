#!/usr/bin/env bash
# Self-audit of a built app (plan §9). Checks signing, hardened runtime, Gatekeeper, and that the binary links no networking.
#   Tools/self-audit.sh [path/to/AppInspector.app]
# Runtime checks need root and a live scan, so they are printed as commands to run, not run here:
#   sudo fs_usage -w -f filesys AppInspector     # during a scan: no writes under TCC / BTM / launchd paths
#   nettop -p $(pgrep AppInspector) -L 3         # during a scan: no network traffic
set -u   # no pipefail: `grep -q` closing early would SIGPIPE the producer and fake a failure
APP="${1:-build/AppInspector.app}"
BIN="$APP/Contents/MacOS/AppInspector"
fail=0
check() { if eval "$2" >/dev/null 2>&1; then echo "ok    $1"; else echo "FAIL  $1"; fail=1; fi; }

check "bundle exists"                    "[ -x '$BIN' ]"
check "codesign verifies (strict)"       "codesign --verify --strict '$APP'"
check "hardened runtime flag set"        "codesign -dv '$APP' 2>&1 | grep -q 'flags=.*runtime'"
check "not sandboxed (needs system DBs)" "! codesign -d --entitlements - '$APP' 2>&1 | grep -q 'app-sandbox'"
check "no network entitlement"           "! codesign -d --entitlements - '$APP' 2>&1 | grep -q 'network'"
check "no URLSession / CFNetwork symbols" "! nm -u '$BIN' 2>/dev/null | grep -Eq 'URLSession|CFNetwork|NSURLConnection'"
echo "info  Gatekeeper (only meaningful for a notarized build):"; spctl -a -vv -t exec "$APP" 2>&1 | sed 's/^/        /'
echo "info  runtime checks to run by hand: fs_usage and nettop (see header)"
exit $fail
