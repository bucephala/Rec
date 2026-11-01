#!/bin/bash
# one time: self signed cert so macOS keeps Screen Recording permission across rebuilds.
# ad-hoc signatures change every build and TCC forgets the app each time.
set -euo pipefail
NAME="Rec Development"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "'$NAME' already exists"
    exit 0
fi

openssl genrsa -out "$DIR/key.pem" 2048 2>/dev/null
cat > "$DIR/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
O = Rec
[ext]
keyUsage = digitalSignature
extendedKeyUsage = codeSigning
basicConstraints = CA:false
CONF
openssl req -new -x509 -key "$DIR/key.pem" -out "$DIR/cert.pem" -days 3650 -config "$DIR/cert.conf" 2>/dev/null
openssl pkcs12 -export -out "$DIR/cert.p12" -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -passout pass:rec 2>/dev/null

security import "$DIR/cert.p12" -k ~/Library/Keychains/login.keychain-db -P rec -T /usr/bin/codesign
# user trust first, admin trust (sudo) as fallback
security add-trusted-cert -r trustRoot -k ~/Library/Keychains/login.keychain-db "$DIR/cert.pem" 2>/dev/null \
    || sudo security add-trusted-cert -d -r trustRoot -k ~/Library/Keychains/login.keychain-db "$DIR/cert.pem"

echo "done. rebuild with Scripts/install.sh, grant permissions once, they stick from now on."
