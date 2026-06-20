#!/usr/bin/env bash
#
# dev-create-cert.sh — create the self-signed code-signing certificate that
# Debug builds of Ora use.
#
# Why this exists:
#   TCC (the macOS privacy system) remembers a permission grant by the pair
#   (bundle id, code-signing Designated Requirement). With ad-hoc signing —
#   what you get when DEVELOPMENT_TEAM is empty — the DR is just the binary's
#   cdhash, which changes on EVERY build. So every rebuild looks like a brand
#   new app and macOS makes you re-grant Microphone + Accessibility. Painful.
#
#   A real signing certificate gives a STABLE DR (anchored to the cert, not
#   the cdhash), so you grant permissions ONCE and they survive every rebuild.
#   This script mints a local, self-signed certificate for that purpose — no
#   Apple Developer account or Team ID required. The Debug build configuration
#   in project.pbxproj is set to sign with this identity by name.
#
#   This is for LOCAL DEBUG BUILDS ONLY. It is not notarizable and must never
#   be used for release/distribution — release signing uses your real
#   Developer ID (see scripts/create-release.sh and dev-env.local.sh).
#
# Usage:
#   ./scripts/dev-create-cert.sh          # run once per machine
#
# It is idempotent: re-running when the identity already exists is a no-op.

set -euo pipefail

CERT_NAME="Ora Dev Signing"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CERT_NAME"; then
    echo "[dev-cert] code-signing identity '$CERT_NAME' already exists — nothing to do."
    exit 0
fi

echo "[dev-cert] creating self-signed code-signing certificate '$CERT_NAME'..."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1. Self-signed cert + key, valid 10 years, with the Code Signing EKU that
#    codesign requires. basicConstraints CA:false / keyUsage digitalSignature
#    keep it a strict leaf-style signing cert.
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 \
    -subj "/CN=$CERT_NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

# 2. Import the certificate and the private key SEPARATELY (no PKCS#12).
#    OpenSSL 3.x exports .p12 with a MAC algorithm Apple's `security` can't
#    read ("MAC verification failed"), so we skip the bundle entirely. The
#    login keychain auto-forms a code-signing *identity* once both the cert
#    and its matching key are present. -T pre-authorizes codesign to use the
#    key so you don't get a keychain prompt on every build.
security import "$TMP/cert.pem" -k "$LOGIN_KEYCHAIN" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security import "$TMP/key.pem" -k "$LOGIN_KEYCHAIN" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# 4. Trust the cert for the code-signing policy in YOUR keychain (user domain,
#    no sudo). Without this, `security find-identity -v` won't list a
#    self-signed cert as a *valid* signing identity. macOS will pop a password
#    dialog here — that's expected, it's editing your login keychain's trust.
echo "[dev-cert] adding code-signing trust (you may be asked for your login password)..."
security add-trusted-cert -r trustRoot -p codeSign -k "$LOGIN_KEYCHAIN" "$TMP/cert.pem"

# 5. Verify.
if security find-identity -v -p codesigning | grep -qF "$CERT_NAME"; then
    echo "[dev-cert] done. '$CERT_NAME' is ready:"
    security find-identity -v -p codesigning | grep -F "$CERT_NAME"
    echo "[dev-cert] next: ./scripts/dev-launch.sh   (grant Mic + Accessibility ONCE)"
else
    cat <<EOF
[dev-cert] WARNING: the identity isn't showing up as valid for codesigning.
This sometimes happens with CLI-imported certs. Fall back to the GUI route:

  1. Open Keychain Access ▸ menu Keychain Access ▸ Certificate Assistant ▸
     Create a Certificate…
  2. Name:            $CERT_NAME
     Identity Type:   Self Signed Root
     Certificate Type: Code Signing
  3. Create, then re-run nothing — the Debug build already points at this name.
EOF
    exit 1
fi
