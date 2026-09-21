#!/bin/bash
# Create the persistent self-signed code-signing certificate used for all local
# builds of Whispering Flow.
#
# Free. Offline. No Apple Developer Program membership. No expiry churn.
#
# WHY THIS EXISTS
#   TCC pins every granted permission to the app's code signature. Ad-hoc
#   signing (Xcode's "Sign to Run Locally") produces a designated requirement
#   built from the *cdhash*, which changes on every single build — so every
#   rebuild silently revokes Microphone, Accessibility and Input Monitoring.
#   A real certificate produces a designated requirement built from the
#   certificate instead, which never changes. See TECH_RESEARCH.md §14.
#
# RUN ONCE. Re-running deletes and recreates the certificate, which changes the
# signature and WILL reset all TCC grants.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=signing.conf
source "$ROOT/Scripts/signing.conf"
NAME="$WF_SIGN_IDENTITY"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning | grep -qF "$NAME"; then
    echo "Identity '$NAME' already exists — nothing to do."
    echo "Recreating it would change the signature and reset every TCC grant."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

cat > openssl.cnf <<CNF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = $NAME
[v3]
basicConstraints   = critical,CA:true
keyUsage           = critical,digitalSignature
extendedKeyUsage   = critical,codeSigning
subjectKeyIdentifier = hash
CNF

echo "==> Generating a 20-year self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -sha256 -days 7300 -nodes \
    -keyout key.pem -out cert.pem -config openssl.cnf 2>/dev/null

# Apple's keychain importer rejects OpenSSL 3's modern PKCS#12 defaults
# (AES-256-CBC + SHA-256 MAC), so the bundle is written with the legacy
# algorithms it does accept. The password is ephemeral and never stored.
PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export -out bundle.p12 -inkey key.pem -in cert.pem -name "$NAME" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
    -passout "pass:$PASS" 2>/dev/null

echo "==> Importing into the login keychain"
# -T /usr/bin/codesign, and deliberately NOT -A: only codesign may use this
# private key, so no other process can sign code that would inherit this app's
# TCC grants.
security import bundle.p12 -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign

rm -f key.pem bundle.p12

echo
echo "==> Result"
security find-identity -p codesigning | grep -F "$NAME" || {
    echo "FATAL: certificate did not import."; exit 1; }
echo
echo "Done. The certificate is valid for 20 years and never needs renewing."
echo "Next: ./Scripts/build.sh"
