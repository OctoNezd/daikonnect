#!/bin/sh
#
# Create the local code-signing identity daiKonnect builds are signed with.
#
# A self-signed certificate is enough here: this app is built and run on this
# machine, and Apple's identity is only needed to distribute or notarise. What
# it buys is a *stable* code identity — signing with a real certificate gives
# the app a designated requirement pinned to that certificate, so permissions
# macOS granted it (Local Network, notifications) survive a rebuild. Ad-hoc
# signing gives each build its own identity, and those grants are lost.
#
# The private key is generated locally and never belongs in the repository.
# Only this script is committed, so any machine can make its own identity.
#
# Run once, then:
#
#   1. Keychain Access → "daiKonnect Local Signing" → Get Info → Trust →
#      set "When using this certificate" to Always Trust. This needs your
#      password, and is what turns it into a usable signing identity.
#
#   2. Build from Xcode. The first build asks whether codesign may use the
#      key — choose Always Allow.
#
# The certificate's subject is deliberately generic: no name, no email, no
# Apple account, nothing that identifies a person.

set -e

IDENTITY_NAME="daiKonnect Local Signing"

# `--ci` makes a separate identity for GitHub Actions and prints what to store
# there. It never touches the keychain: exporting an identity from it means
# `security export -t identities`, which offers *every* identity — including an
# Apple one, which is not what a self-signed build should be signed with. A
# fresh certificate avoids that entirely, and CI does not care which one it is,
# so long as every release is signed with the same one.
if [ "$1" = "--ci" ]; then
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT

    PASSWORD="$(openssl rand -hex 16)"
    OUT="${PWD}/ci-signing.p12"

    # Every release must be signed with the same certificate, or macOS treats
    # each one as a different app and asks for its permissions again. Making a
    # second one would quietly undo exactly the thing this is for.
    if [ -e "$OUT" ]; then
        echo "$OUT already exists. Reusing its certificate keeps releases the"
        echo "same app; making a new one would not. Move or delete it first if"
        echo "you really mean to replace it."
        exit 1
    fi

    echo "Generating a release signing certificate..."
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 3650 \
        -subj "/CN=daiKonnect Release Signing/O=daiKonnect" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" \
        -addext "basicConstraints=critical,CA:FALSE" 2>/dev/null

    # The legacy algorithms are not nostalgia: `security import` cannot read the
    # modern PKCS#12 encryption OpenSSL 3 defaults to.
    openssl pkcs12 -export -out "$OUT" \
        -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
        -passout "pass:$PASSWORD" \
        -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

    base64 -i "$OUT" | pbcopy

    cat <<DONE

Wrote $OUT and copied its base64 to the clipboard.

In the repository's settings → Secrets and variables → Actions, add:

  SIGNING_CERTIFICATE_P12       (already on your clipboard — paste it)
  SIGNING_CERTIFICATE_PASSWORD  $PASSWORD

ci-signing.p12 is ignored by git and holds the private key. Keep it somewhere
safe if you want to reuse this same identity for later releases — every
release has to be signed with the same one for macOS to treat them as the
same app. Delete it when you are done if you would rather not keep it.
DONE
    exit 0
fi
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY_NAME"; then
    echo "Already present: $IDENTITY_NAME"
    exit 0
fi

echo "Generating a self-signed code-signing certificate..."
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 3650 \
    -subj "/CN=$IDENTITY_NAME/O=daiKonnect" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:FALSE" 2>/dev/null

# `security import` predates the modern PKCS#12 encryption OpenSSL 3 defaults
# to and reports a MAC failure on it, so the legacy algorithms are requested
# explicitly.
openssl pkcs12 -export -out "$WORK/identity.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -passout pass:daikonnect \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

echo "Importing into the login keychain, allowing codesign to use it..."
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P daikonnect \
    -T /usr/bin/codesign -T /usr/bin/security

cat <<'DONE'

Created. Two one-time steps remain, both needing your password:

  1. Keychain Access → "daiKonnect Local Signing" → Get Info → Trust →
     "When using this certificate" → Always Trust.
     Until then the identity shows as CSSMERR_TP_NOT_TRUSTED.

  2. Build from Xcode. The first build asks whether codesign may use the
     key — Always Allow.

After that the app keeps one identity across rebuilds, so the Local Network
and notification permissions stop resetting.
DONE
