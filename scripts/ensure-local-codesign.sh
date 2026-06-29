#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIGNING_DIR="${SPACECUE_SIGNING_DIR:-$HOME/Library/Application Support/SpaceCue/signing}"
KEYCHAIN="$SIGNING_DIR/SpaceCue.keychain"
CERT_NAME="SpaceCue Local Code Signing"
PASSWORD="spacecue-local"

mkdir -p "$SIGNING_DIR"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CERT_NAME"; then
  security unlock-keychain -p "$PASSWORD" "$KEYCHAIN" >/dev/null 2>&1 || true
  security set-keychain-settings -lut 21600 "$KEYCHAIN" >/dev/null 2>&1 || true
  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "$PASSWORD" \
    "$KEYCHAIN" >/dev/null 2>&1 || true
  echo "$KEYCHAIN"
  exit 0
fi

rm -f "$KEYCHAIN" "$SIGNING_DIR"/SpaceCue.{key,crt,p12,cnf}

cat > "$SIGNING_DIR/SpaceCue.cnf" <<'EOF'
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = SpaceCue Local Code Signing
O = Local

[v3_req]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF

openssl req \
  -new \
  -newkey rsa:2048 \
  -nodes \
  -x509 \
  -days 3650 \
  -keyout "$SIGNING_DIR/SpaceCue.key" \
  -out "$SIGNING_DIR/SpaceCue.crt" \
  -config "$SIGNING_DIR/SpaceCue.cnf" >/dev/null 2>&1

openssl pkcs12 \
  -export \
  -inkey "$SIGNING_DIR/SpaceCue.key" \
  -in "$SIGNING_DIR/SpaceCue.crt" \
  -out "$SIGNING_DIR/SpaceCue.p12" \
  -name "$CERT_NAME" \
  -passout pass:"$PASSWORD" >/dev/null 2>&1

security create-keychain -p "$PASSWORD" "$KEYCHAIN" >/dev/null
security set-keychain-settings -lut 21600 "$KEYCHAIN" >/dev/null
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN" >/dev/null
security import "$SIGNING_DIR/SpaceCue.p12" \
  -k "$KEYCHAIN" \
  -P "$PASSWORD" \
  -T /usr/bin/codesign >/dev/null

security add-trusted-cert \
  -r trustRoot \
  -k "$KEYCHAIN" \
  "$SIGNING_DIR/SpaceCue.crt" >/dev/null 2>&1 || true

security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "$PASSWORD" \
  "$KEYCHAIN" >/dev/null 2>&1 || true

if ! security find-identity -v -p codesigning "$KEYCHAIN" | grep -q "$CERT_NAME"; then
  echo "failed to create local code signing identity" >&2
  exit 1
fi

echo "$KEYCHAIN"
