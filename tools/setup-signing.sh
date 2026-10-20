#!/bin/bash
# One-time: creates a local self-signed code-signing identity in its own keychain
# (~/Library/PocketMacSigning, NOT your login keychain). Signing every build with the
# same identity means macOS keeps Screen Recording / Accessibility permissions across
# updates (ad-hoc signatures change on every build, so macOS forgets them).
set -euo pipefail
DIR="$HOME/Library/PocketMacSigning"
KC="$DIR/pocketmac-signing.keychain-db"
NAME="PocketMac Local Signing"
if [ -f "$KC" ]; then echo "Signing identity already set up: $KC"; exit 0; fi
mkdir -p "$DIR"; chmod 700 "$DIR"
PW=$(openssl rand -hex 24)
printf '%s' "$PW" > "$DIR/keychain-password"; chmod 600 "$DIR/keychain-password"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 7300 \
  -subj "/CN=$NAME" -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
P12PW=$(openssl rand -hex 12)
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout "pass:$P12PW" -legacy 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout "pass:$P12PW"
security create-keychain -p "$PW" "$KC"
security set-keychain-settings "$KC"            # no auto-lock
security unlock-keychain -p "$PW" "$KC"
security import "$TMP/id.p12" -k "$KC" -P "$P12PW" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$PW" "$KC" >/dev/null 2>&1
echo "Created signing identity \"$NAME\" in $KC"
