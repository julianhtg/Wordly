#!/bin/bash
# One-time: create a stable self-signed code-signing identity for Wordly.
#
# Why: an ad-hoc signature (codesign --sign -) gets a fresh hash on every
# rebuild, and macOS treats a new hash as a new app — so your Accessibility and
# Microphone grants are thrown away every time you rebuild, and you get
# re-prompted. A stable certificate keeps one identity across rebuilds, so you
# grant permissions once and they stick.
#
# Run once:   bash scripts/setup-signing.sh
# It asks for your login password once (to trust the certificate). After that,
# `make app` signs with this identity automatically.
set -euo pipefail

NAME="Wordly Local Signing"
DIR="$HOME/.config/wordly/signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "✅ Signing identity '$NAME' is already set up. Nothing to do."
    exit 0
fi

mkdir -p "$DIR"
if [ ! -f "$DIR/cert.pem" ] || [ ! -f "$DIR/key.pem" ]; then
    echo "→ Creating self-signed code-signing certificate…"
    openssl req -x509 -newkey rsa:2048 -keyout "$DIR/key.pem" -nodes -out "$DIR/cert.pem" \
        -days 3650 -subj "/CN=$NAME" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" \
        -addext "basicConstraints=critical,CA:false"
fi

# macOS's Security framework can't read OpenSSL 3's default PKCS12 MAC/cipher,
# so export with legacy SHA1/3DES.
openssl pkcs12 -export -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -out "$DIR/id.p12" \
    -passout pass:wordly -name "$NAME" -legacy -macalg sha1 \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES

echo "→ Importing into your login keychain…"
security import "$DIR/id.p12" -k "$KEYCHAIN" -P wordly -T /usr/bin/codesign -A

echo "→ Trusting it for code signing — enter your login password if macOS asks…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$DIR/cert.pem"

rm -f "$DIR/id.p12"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "✅ '$NAME' is ready. Next: run 'make app', then grant Accessibility"
    echo "   once more (the identity changed) — it will stick from now on."
else
    echo "❌ Identity still isn't valid for signing. Re-run, or check the output above."
    exit 1
fi
