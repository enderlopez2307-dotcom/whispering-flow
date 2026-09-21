#!/bin/bash
# Diagnose an installed Whispering Flow. Read-only unless --relaunch is given.
#
#   ./Scripts/doctor.sh              # static checks
#   ./Scripts/doctor.sh --relaunch   # also restart the app and read what it reports
#
# It never resets, grants or edits macOS permissions.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=signing.conf
source "$ROOT/Scripts/signing.conf"
PREFIX="$HOME/Applications"
RELAUNCH=0
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="${2:?}"; shift 2 ;;
        --relaunch) RELAUNCH=1; shift ;;
        *) echo "Unknown option: $1"; exit 2 ;;
    esac
done
APP="$PREFIX/WhisperingFlow.app"
SUPPORT="$HOME/Library/Application Support/WhisperingFlow"
problems=0
ok()   { printf '  [ok]   %s\n' "$*"; }
bad()  { printf '  [FIX]  %s\n' "$*"; problems=$((problems + 1)); }

echo "Whispering Flow doctor"
OS_VERSION="$(sw_vers -productVersion)"
[ "${OS_VERSION%%.*}" -ge 26 ] 2>/dev/null && ok "macOS $OS_VERSION" || bad "macOS 26+ required (have $OS_VERSION)"
[ "$(uname -m)" = "arm64" ] && ok "Apple Silicon" || bad "Apple Silicon required"

if security find-identity -p codesigning | grep -qF "$WF_SIGN_IDENTITY"; then
    ok "signing certificate '$WF_SIGN_IDENTITY' exists"
else
    bad "no signing certificate. Run ./Scripts/create-signing-cert.sh"
fi

if [ -d "$APP" ]; then
    ok "installed at $APP"
    DR="$(codesign -d -r- "$APP" 2>/dev/null | sed -n 's/^designated => //p')"
    if [ -z "$DR" ]; then bad "app is not signed"
    elif printf '%s' "$DR" | grep -q cdhash; then bad "app is ad-hoc signed; permissions would reset on every build. Re-run ./Scripts/install.sh"
    else ok "stable signing identity"; fi
else
    bad "not installed at $APP. Run ./Scripts/install.sh"
fi

if pgrep -f "$APP/Contents/MacOS" >/dev/null; then ok "app is running"; else bad "app is not running. Run ./Scripts/install.sh --launch"; fi

if [ -d "$SUPPORT" ]; then
    ok "data folder exists"
    [ -f "$SUPPORT/vocabulary.json" ] && ok "vocabulary: $(grep -c '"spoken"' "$SUPPORT/vocabulary.json") rules"
else
    echo "  [info] no data folder yet (created on first launch)"
fi

if [ "$RELAUNCH" = 1 ] && [ -d "$APP" ]; then
    echo
    echo "Restarting the app and reading what it reports for 8 seconds..."
    LOG="$(mktemp)"
    /usr/bin/log stream --info --style compact \
        --predicate "subsystem == \"$WF_BUNDLE_ID\"" >"$LOG" 2>&1 &
    LOGPID=$!
    sleep 1
    pkill -f "$APP/Contents/MacOS" 2>/dev/null; sleep 1
    open "$APP"
    sleep 8
    kill "$LOGPID" 2>/dev/null
    echo "--- permissions and hotkey, as the app itself sees them ---"
    grep -E "\[launch\]|event tap|first event|hotkey start failed|Secure input|secure" "$LOG" | sed 's/^.*WhisperingFlow\[[0-9:a-z]*\] //' | head -12
    if grep -q "hotkey start failed" "$LOG"; then
        bad "the keyboard tap could not start: Input Monitoring is probably not granted (System Settings > Privacy & Security > Input Monitoring), then run ./Scripts/install.sh --launch"
    fi
    if grep -Eq "\[launch\].*(denied|notDetermined)" "$LOG"; then
        bad "a permission is not granted yet; see the line above and grant it in System Settings > Privacy & Security"
    fi
    rm -f "$LOG"
fi

echo
if [ "$problems" = 0 ]; then echo "Nothing to fix."; else echo "$problems thing(s) to fix (marked [FIX])."; fi
exit 0
