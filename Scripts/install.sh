#!/bin/bash
# One-command install of Whispering Flow on this Mac.
#
#   ./Scripts/install.sh              # check, sign, build, install, register permissions
#   ./Scripts/install.sh --launch     # just (re)start the installed app
#   ./Scripts/install.sh --help
#
# Safe to run again: every step is idempotent, and it NEVER resets macOS
# permissions (TCC). Nothing here needs sudo. Nothing leaves this Mac except the
# one-time Apple speech-model download the app itself triggers on first launch.
#
# Options
#   --prefix DIR        install the app into DIR instead of ~/Applications
#   --no-permissions    skip the permission-registration step
#   --no-launch         install but do not start the app
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=signing.conf
source "$ROOT/Scripts/signing.conf"

PREFIX="$HOME/Applications"
REQUEST_PERMISSIONS=1
LAUNCH=1
LAUNCH_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
        --no-permissions) REQUEST_PERMISSIONS=0; shift ;;
        --no-launch) LAUNCH=0; shift ;;
        --launch) LAUNCH_ONLY=1; shift ;;
        -h|--help) sed -n '2,17p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "Unknown option: $1 (try --help)"; exit 2 ;;
    esac
done

APP_NAME="WhisperingFlow.app"
DEST="$PREFIX/$APP_NAME"

say()  { printf '\n==> %s\n' "$*"; }
fail() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }

restart_app() {
    say "Starting $DEST"
    pkill -f "$DEST/Contents/MacOS" 2>/dev/null || true
    sleep 1
    open "$DEST"
    sleep 3
    # The app has silently failed to start before; never assume.
    if pgrep -f "$DEST/Contents/MacOS" >/dev/null; then
        echo "    running (menu-bar icon: a microphone)"
    else
        fail "the app did not start. Run it from a terminal to see why: $DEST/Contents/MacOS/WhisperingFlow"
    fi
}

if [ "$LAUNCH_ONLY" = 1 ]; then
    [ -d "$DEST" ] || fail "$DEST is not installed yet. Run ./Scripts/install.sh first."
    restart_app
    exit 0
fi

# ---------------------------------------------------------------- 1. preflight
say "1/5  Checking this Mac"

OS_VERSION="$(sw_vers -productVersion)"
OS_MAJOR="${OS_VERSION%%.*}"
[ "$OS_MAJOR" -ge 26 ] 2>/dev/null \
    || fail "macOS 26 or later is required (this Mac has $OS_VERSION). Apple's on-device speech engine ships with macOS 26."
[ "$(uname -m)" = "arm64" ] \
    || fail "Apple Silicon is required (this Mac is $(uname -m))."
command -v swift >/dev/null 2>&1 \
    || fail "No Swift toolchain. Install Xcode from the App Store or run: xcode-select --install   (a human must click through the dialog), then re-run this script."
SWIFT_LINE="$(swift --version 2>&1 | head -1)"
SWIFT_VERSION="$(printf '%s' "$SWIFT_LINE" | sed -n 's/.*Swift version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"
SWIFT_MAJOR="${SWIFT_VERSION%%.*}"
SWIFT_MINOR="${SWIFT_VERSION#*.}"
if [ -z "$SWIFT_VERSION" ] || [ "$SWIFT_MAJOR" -lt 6 ] || { [ "$SWIFT_MAJOR" -eq 6 ] && [ "${SWIFT_MINOR%%.*}" -lt 2 ]; }; then
    fail "Swift 6.2 or later is required (found: $SWIFT_LINE). Update Xcode."
fi
echo "    macOS $OS_VERSION, arm64, $SWIFT_LINE"

# --------------------------------------------------------------- 2. certificate
say "2/5  Local signing certificate (created once, on this Mac only)"
echo "    If a password dialog appears now, it is the macOS keychain asking the"
echo "    logged-in human to allow the certificate import. An agent cannot answer it."
"$ROOT/Scripts/create-signing-cert.sh"

# ---------------------------------------------------------------------- 3. build
say "3/5  Building (the first build takes a few minutes)"
echo "    If this seems stuck, a keychain dialog asking to let 'codesign' use the"
echo "    key is waiting for the human. Choose Always Allow."
"$ROOT/Scripts/build.sh" release

# -------------------------------------------------------------------- 4. install
say "4/5  Installing to $DEST"
mkdir -p "$PREFIX"
pkill -f "$DEST/Contents/MacOS" 2>/dev/null || true
sleep 1
rm -rf "$DEST"
cp -R "$ROOT/build/$APP_NAME" "$DEST"
if codesign -d -r- "$DEST" 2>/dev/null | grep -q 'cdhash'; then
    fail "the installed app is ad-hoc signed (its identity contains a cdhash). macOS would forget its permissions on every rebuild. Re-run ./Scripts/create-signing-cert.sh and this script."
fi
codesign --verify --strict "$DEST" 2>&1 | sed 's/^/    /' || fail "signature check failed"
echo "    signed with a stable identity: $(codesign -d -r- "$DEST" 2>/dev/null | sed -n 's/^designated => //p')"

# ------------------------------------------------------------- 5. permissions
if [ "$REQUEST_PERMISSIONS" = 1 ]; then
    say "5/5  Registering with macOS privacy settings"
    echo "    macOS will now show up to three prompts. These are the HUMAN's to answer."
    open "$DEST" --args --request-permissions
    # The registration run stays alive until the human answers the Microphone
    # prompt. Restarting the app before that would dismiss the dialog, so wait
    # (up to 3 minutes) and only then carry on.
    sleep 2
    waited=0
    while pgrep -f "$DEST/Contents/MacOS" >/dev/null && [ "$waited" -lt 180 ]; do
        [ "$waited" -eq 0 ] && echo "    waiting for the Microphone prompt to be answered..."
        sleep 2; waited=$((waited + 2))
    done
    if pgrep -f "$DEST/Contents/MacOS" >/dev/null; then
        echo "    no answer yet; continuing. The prompt can be answered later from System Settings."
    fi
fi

if [ "$LAUNCH" = 1 ]; then
    restart_app
fi

cat <<DONE

Installed: $DEST

THE HUMAN STILL HAS TO DO THESE (an agent must not click them):
  1. Microphone       -> click Allow in the prompt.
  2. Input Monitoring -> System Settings > Privacy & Security > Input Monitoring
                         > turn "Whispering Flow" ON.
  3. Accessibility    -> System Settings > Privacy & Security > Accessibility
                         > turn "Whispering Flow" ON.
  After 2 and 3, restart the app once:  ./Scripts/install.sh --launch

TRY IT: click into any text field (TextEdit is a good first test), HOLD Right Command,
say a sentence, release. Double-tap Right Command to keep talking hands-free;
tap once to finish; Escape cancels.

If something is off:  ./Scripts/doctor.sh
DONE
