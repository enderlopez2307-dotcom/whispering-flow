#!/bin/bash
# Build and sign Whispering Flow.app
#
#   ./Scripts/build.sh [debug|release]
#
# Produces build/WhisperingFlow.app, signed with the identity in signing.conf.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=signing.conf
source "$ROOT/Scripts/signing.conf"

CONFIG="${1:-release}"
APP="$ROOT/build/WhisperingFlow.app"
BIN_NAME="WhisperingFlow"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" --arch arm64 2>&1 | grep -Ev '^\[[0-9]+/[0-9]+\]|^Building|^Compiling' || true
BIN_PATH="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/$BIN_NAME"
[ -x "$BIN_PATH" ] || { echo "FATAL: binary not produced at $BIN_PATH"; exit 1; }

echo "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$BIN_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing as: $WF_SIGN_IDENTITY"
# Note: no -v. A self-signed root reports CSSMERR_TP_NOT_TRUSTED, so it is
# absent from the "valid identities" list — but codesign signs with it happily,
# and the resulting designated requirement is stable, which is all we need.
if ! security find-identity -p codesigning | grep -qF "$WF_SIGN_IDENTITY"; then
    echo "FATAL: signing identity '$WF_SIGN_IDENTITY' not found in the keychain."
    echo "       Run ./Scripts/create-signing-cert.sh to create it."
    exit 1
fi

codesign --force \
         --options runtime \
         --entitlements "$ROOT/Resources/WhisperingFlow.entitlements" \
         --sign "$WF_SIGN_IDENTITY" \
         --timestamp=none \
         "$APP"

echo "==> Verifying"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

echo
echo "Designated requirement (this is what TCC pins grants to):"
codesign -d -r- "$APP" 2>/dev/null | sed 's/^/    /'

if codesign -d -r- "$APP" 2>/dev/null | grep -q 'cdhash'; then
    echo
    echo "  WARNING: the designated requirement contains a cdhash."
    echo "  The cdhash changes on every build, so TCC grants will reset each time."
fi

echo
echo "Built: $APP"
