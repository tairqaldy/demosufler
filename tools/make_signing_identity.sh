#!/bin/bash
# Creates the signing identity of demosufler: a self-signed certificate with its private key,
# kept as a file in your home folder (not in a keychain).
#
# macOS ties camera, microphone and screen recording permissions to the signature of an app.
# Builds signed with this one identity look like the same app to macOS, so permissions given
# once survive every update. Keep the folder: if it is lost, a new identity has to be made and
# everybody is asked for the permissions one more time. Never commit it or share it.
set -euo pipefail

DIR="${DEMOSUFLER_SIGNING_DIR:-$HOME/Library/Application Support/demosufler-signing}"
if [ -f "$DIR/identity.p12" ]; then
    echo "The identity already exists: $DIR"
    exit 0
fi
mkdir -p "$DIR"
chmod 700 "$DIR"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

openssl rand -hex 24 > "$DIR/password"
chmod 600 "$DIR/password"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$DIR/certificate.pem" -days 7300 \
    -subj "/CN=demosufler (self-signed)" \
    -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$DIR/certificate.pem" -out "$DIR/identity.p12" \
    -passout "file:$DIR/password" -name "demosufler (self-signed)"
chmod 600 "$DIR/identity.p12"
echo "Created the signing identity in: $DIR"
