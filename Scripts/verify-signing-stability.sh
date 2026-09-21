#!/bin/bash
# Phase 1 / Q5: do TCC grants survive rebuilds under our local signing setup?
#
# TCC pins grants to the app's designated requirement (DR). If the DR is stable
# across builds, grants persist; if it is cdhash-based, they reset every build.
#
# METHOD NOTE — this matters, and getting it wrong invalidates the result.
# The app MUST be launched with `open`, and its TCC state read from OSLog.
# Running the binary from a shell reports the TERMINAL's grants, because TCC
# attributes a shell-spawned process to its responsible process.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
APP="$ROOT/build/WhisperingFlow.app"
PLIST="$ROOT/Resources/Info.plist"
N="${1:-3}"

read_app_tcc() {
    local out; out="$(mktemp)"
    pkill -9 -f "WhisperingFlow.app" 2>/dev/null || true; sleep 1
    /usr/bin/log stream --predicate 'subsystem == "com.whisperingflow.dictation"' \
        --info --style compact > "$out" 2>&1 &
    local lp=$!
    sleep 2; open "$APP"; sleep 4; kill $lp 2>/dev/null || true
    pkill -9 -f "WhisperingFlow.app" 2>/dev/null || true
    local mic ax hid
    mic=$(grep -o 'Microphone: [a-zA-Z]*'       "$out" | tail -1 | awk '{print $2}')
    ax=$( grep -o 'Accessibility: [a-zA-Z]*'    "$out" | tail -1 | awk '{print $2}')
    hid=$(grep -o 'Input Monitoring: [a-zA-Z]*' "$out" | tail -1 | awk '{print $3}')
    rm -f "$out"
    echo "mic=${mic:-?} accessibility=${ax:-?} inputMonitoring=${hid:-?}"
}

cp "$PLIST" "$PLIST.bak"
trap 'mv -f "$PLIST.bak" "$PLIST" 2>/dev/null || true' EXIT

echo "Rebuilding $N times with genuinely different binaries."
echo
prev_dr=""; ok=1
for i in $(seq 1 "$N"); do
    # Bump the build number: it lands in Info.plist, which is hashed into the
    # code signature, guaranteeing a different cdhash each iteration.
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((100 + i))" "$PLIST" >/dev/null
    ./Scripts/build.sh release >/dev/null 2>&1
    dr="$(codesign -d -r- "$APP" 2>/dev/null | sed 's/^# *//')"
    cdh="$(codesign -dvvv "$APP" 2>&1 | grep -i '^CDHash=' | cut -d= -f2)"
    bin="$(shasum -a 256 "$APP/Contents/MacOS/WhisperingFlow" | cut -c1-12)"
    printf 'build %d  cdhash=%s…  binary=%s\n' "$i" "${cdh:0:16}" "$bin"
    printf '         grants: %s\n' "$(read_app_tcc)"
    [ -n "$prev_dr" ] && [ "$dr" != "$prev_dr" ] && { echo "         DR CHANGED"; ok=0; }
    prev_dr="$dr"
done

echo
echo "Designated requirement (constant across all builds):"
echo "  $prev_dr"
echo
if [ "$ok" -eq 1 ] && ! printf '%s' "$prev_dr" | grep -q cdhash; then
    echo "PASS — DR is identity-based and unchanged across $N rebuilds."
else
    echo "FAIL — DR is unstable; TCC grants will reset on every build."
    exit 1
fi
