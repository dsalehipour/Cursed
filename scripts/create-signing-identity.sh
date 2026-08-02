#!/usr/bin/env bash
# Creates the local code-signing identity that scripts/build.sh signs with.
#
# Why this exists: clicking a row has to bring Cursor forward, and macOS only lets a background
# app do that through Accessibility. It pins that grant to the app's signature, and an ad-hoc
# signature changes on every build — so the permission silently lapsed after each rebuild and
# clicks quietly stopped working. A fixed certificate keeps the signature stable, so the grant is
# given once and stays given.
#
# Self-signed and local: it proves nothing to anyone else, it only gives macOS a consistent
# identity to pin the permission to. Run once per machine.
set -euo pipefail

IDENTITY="cursed-dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
    echo "'$IDENTITY' already exists — nothing to do."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT   # the private key lives here until it is in the keychain

cat > "$WORK/cert.cnf" <<'CNF'
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = cursed-dev
[ v3 ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

echo "==> generating certificate"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null

# OpenSSL 3 defaults to encryption Keychain cannot read, hence the explicit legacy algorithms.
PW="$(openssl rand -hex 16)"
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/id.p12" \
    -passout "pass:$PW" -name "$IDENTITY" \
    -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES 2>/dev/null

echo "==> importing into the login keychain"
security import "$WORK/id.p12" -k "$KEYCHAIN" -P "$PW" -A >/dev/null

# Until it is trusted for code signing, codesign will not consider it a valid identity. This is
# the step that asks for your password.
echo "==> trusting it for code signing (may prompt)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
security find-identity -v -p codesigning | grep "\"$IDENTITY\"" || {
    echo "identity was created but is still not valid for code signing" >&2
    exit 1
}
echo
echo "Done. Rebuild with scripts/build.sh, then grant Accessibility once in"
echo "System Settings > Privacy & Security > Accessibility."
