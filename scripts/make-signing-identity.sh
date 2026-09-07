#!/bin/bash
# Creates a persistent self-signed code-signing identity in the login keychain, once.
# macOS ties Screen Recording and Accessibility grants to an app's signing identity. Ad-hoc
# signatures change on every build; this one does not, so grants survive rebuilds.
# Run it yourself in Terminal: macOS may ask for your login password to trust the certificate.
set -euo pipefail

NAME="${1:-PRC Local Signing}"
if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "identity \"$NAME\" already exists"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/ext.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/ext.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/identity.p12" -passout pass:prc -name "$NAME"

KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P prc -T /usr/bin/codesign -T /usr/bin/security
# Let codesign use the key without a prompt on every build.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || \
  echo "note: if codesign prompts for the keychain, click Always Allow once"
# Trust it for code signing (user trust settings; macOS may ask for your password).
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" || \
  echo "note: could not add trust settings; codesign still works, macOS may warn on first launch"

echo "created identity \"$NAME\". Build with:  PRC_SIGN_IDENTITY=\"$NAME\" scripts/build-apps.sh"
