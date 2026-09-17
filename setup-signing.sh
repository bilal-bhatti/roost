#!/bin/bash
# setup-signing.sh — creates a stable, local, self-signed code-signing identity
# so rebuilds keep the app's code identity constant.
#
# Why bother: ad-hoc signing (`codesign -s -`) mints a brand-new identity on
# every build. macOS keys per-app state to that identity, so an ad-hoc rebuild
# looks like a different app and the system re-prompts for access to the API
# tokens Roost stored in your Keychain. A stable identity avoids that.
#
#   ./setup-signing.sh           create the identity (idempotent)
#   ./setup-signing.sh --remove  delete it and its keychain
#
# The identity lives in its own keychain, not your login keychain, so it can't
# be confused with anything else and removing it leaves no trace.
set -euo pipefail

KEYCHAIN="$HOME/Library/Keychains/roost-signing.keychain-db"
NAME="Roost Local Signing"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The user's keychain search list, minus ours. Rebuilt rather than appended to
# because `security list-keychains -s` replaces the whole list: passing only our
# keychain would drop the login keychain and break every other app's access.
search_list_without_ours() {
    local line
    while IFS= read -r line; do
        line="${line//\"/}"
        line="$(echo "$line" | xargs)"   # trim surrounding whitespace
        [[ -n "$line" && "$line" != "$KEYCHAIN" ]] && printf '%s\n' "$line"
    done < <(security list-keychains -d user)
}

if [[ "${1:-}" == "--remove" ]]; then
    others=()
    while IFS= read -r line; do others+=("$line"); done < <(search_list_without_ours)
    [[ ${#others[@]} -gt 0 ]] && security list-keychains -d user -s "${others[@]}"
    security delete-keychain "$KEYCHAIN" 2>/dev/null && echo "Removed $KEYCHAIN" \
        || echo "Nothing to remove."
    exit 0
fi

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$NAME"; then
    echo "Identity \"$NAME\" already exists."
    exit 0
fi

# Empty password: this key signs local builds only and never leaves the machine.
# A password here would just mean a prompt on every build.
# Create with the full path, not a bare name: given "roost-signing", the
# security tool produces a file literally called "roost-signing-db", which then
# can't be found under the ".keychain-db" name every later command uses.
if [[ ! -f "$KEYCHAIN" ]]; then
    security create-keychain -p "" "$KEYCHAIN"
fi
security unlock-keychain -p "" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"   # no auto-lock timeout

# Always the system openssl, never whatever is first on PATH. Homebrew's
# OpenSSL 3 writes PKCS#12 with AES-256-CBC and a SHA-256 MAC, which macOS's
# `security import` cannot read — it fails with "MAC verification failed
# (wrong password?)", naming the one thing that isn't wrong. The LibreSSL that
# ships with macOS writes a bundle macOS can read.
OPENSSL=/usr/bin/openssl

# Config file rather than -addext: -addext arrived in OpenSSL 1.1.1 and its
# availability in LibreSSL varies by macOS release, whereas -config is ancient
# and universal.
cat > "$WORK/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no

[ dn ]
CN = $NAME

[ v3 ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 3650 \
    -config "$WORK/openssl.cnf" 2>/dev/null

# A throwaway password rather than an empty one: empty-password PKCS#12 bundles
# are another case `security import` handles inconsistently. It exists for the
# length of this script and is never written anywhere.
P12PASS="$(uuidgen)$(uuidgen)"

"$OPENSSL" pkcs12 -export -out "$WORK/identity.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -passout "pass:$P12PASS" 2>/dev/null

# -T codesign pre-authorises codesign to use the key, so builds don't prompt.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12PASS" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "" "$KEYCHAIN" >/dev/null 2>&1

# Put the keychain on the user's search list. codesign will not find an identity
# in a keychain that isn't listed, even when it is handed the path with
# --keychain — it reports "no identity found", which sounds like the import
# failed rather than like a lookup-path problem.
others=()
while IFS= read -r line; do others+=("$line"); done < <(search_list_without_ours)
security list-keychains -d user -s "${others[@]}" "$KEYCHAIN"

echo "Created \"$NAME\" in $KEYCHAIN"
echo "Now run ./build-app.sh --install — it will pick this up automatically."
