#!/bin/bash
# Creates a stable local code-signing certificate named "DockBar Development"
# if one is not already in the login keychain. Reusing this certificate is what
# keeps Accessibility and Screen Recording grants across rebuilds.

set -euo pipefail

IDENTITY="${CODESIGN_IDENTITY:-DockBar Development}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Capture first. grep -q would close the pipe early and, with pipefail, look like no certificate exists.
identities="$(security find-identity -v -p codesigning || true)"
if printf '%s\n' "$identities" | grep -F -q "$IDENTITY"; then
  exit 0
fi

echo "Creating a stable code-signing certificate named \"$IDENTITY\"..."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.conf" << EOF
[ req ]
distinguished_name = dn
x509_extensions = codesign
prompt = no
[ dn ]
CN = ${IDENTITY}
[ codesign ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$WORK/key.pem" \
  -out "$WORK/cert.pem" \
  -config "$WORK/cert.conf" >/dev/null 2>&1

PASS="$(openssl rand -base64 24 | tr -d '\n')"
openssl pkcs12 -export \
  -out "$WORK/cert.p12" \
  -inkey "$WORK/key.pem" \
  -in "$WORK/cert.pem" \
  -passout "pass:${PASS}" >/dev/null 2>&1

# No -A: only codesign may use this key, so another local app cannot sign as DockBar.
security import "$WORK/cert.p12" \
  -k "$KEYCHAIN" \
  -P "$PASS" \
  -T /usr/bin/codesign >/dev/null

# User trust settings, so codesign accepts the certificate without an admin password.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

identities="$(security find-identity -v -p codesigning || true)"
if ! printf '%s\n' "$identities" | grep -F -q "$IDENTITY"; then
  echo "The certificate was created, but macOS still does not trust it for code signing." >&2
  echo "Open Keychain Access, find \"$IDENTITY\", and set it to Always Trust for Code Signing." >&2
  exit 1
fi

echo "Code-signing certificate \"$IDENTITY\" is ready."
