#!/bin/bash
# build-app.sh — compiles the Swift sources into Roost.app. No Xcode project:
# just swiftc + a hand-assembled bundle, so a clone builds with one command and
# only the Command Line Tools installed.
#
#   ./build-app.sh            build to ./build/Roost.app
#   ./build-app.sh --install  also install into /Applications
#
# Re-run after editing anything in Sources/, Info.plist, or the icon.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
NAME="Roost"
MIN_OS="14.0"
ARCH="$(uname -m)"
BUILD="$DIR/build/$NAME.app"
CONTENTS="$BUILD/Contents"
DEST="/Applications/$NAME.app"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Signing identity. Prefer a stable one so macOS keeps per-app grants (and the
# Keychain ACL on our stored tokens) across rebuilds; ad-hoc regenerates the
# app's identity every build, which makes the system treat it as a new app:
#   $SIGN_ID set        -> use it (e.g. a Developer ID, or "-" to force ad-hoc)
#   setup-signing cert  -> use it automatically
#   otherwise           -> ad-hoc, with a hint to run ./setup-signing.sh
SIGN_KEYCHAIN="$HOME/Library/Keychains/roost-signing.keychain-db"
SIGN_NAME="Roost Local Signing"
if [[ -n "${SIGN_ID:-}" ]]; then
    IDENTITY="$SIGN_ID"
elif security find-identity -p codesigning "$SIGN_KEYCHAIN" 2>/dev/null | grep -q "$SIGN_NAME"; then
    # No -v: the cert is self-signed/untrusted (fine to sign with) so it won't
    # show as a "valid" identity, but codesign still uses it and produces a
    # stable designated requirement that survives rebuilds.
    IDENTITY="$SIGN_NAME"
    security unlock-keychain -p "" "$SIGN_KEYCHAIN" 2>/dev/null || true
else
    IDENTITY="-"
fi

# 1) fresh bundle skeleton
rm -rf "$BUILD"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

# 2) compile every Swift source into the bundle's executable. Sources/ is nested
#    (Core, Model, Providers, Views), so collect recursively rather than globbing
#    one level.
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find "$DIR/Sources" -name '*.swift' | sort)
if [[ ${#SOURCES[@]} -eq 0 ]]; then
    echo "error: no Swift sources found under $DIR/Sources" >&2
    exit 1
fi

swiftc \
  -O \
  -parse-as-library \
  -swift-version 5 \
  -target "${ARCH}-apple-macosx${MIN_OS}" \
  -o "$CONTENTS/MacOS/$NAME" \
  "${SOURCES[@]}"

# 3) metadata + icon. The .icns is generated (not checked in) — render it on the
#    first build, and carry on without one if that fails rather than blocking.
cp "$DIR/Info.plist" "$CONTENTS/Info.plist"

#    Stamp the commit this build came from. A hand-maintained version number in
#    Info.plist is a number somebody has to remember to bump, and it is wrong the
#    moment they don't; the SHA is always true and is what a bug report needs.
#    Written into the *copied* plist, never the checked-in one, and before
#    signing — any edit after codesign invalidates the signature.
GIT_SHA="$(git -C "$DIR" rev-parse --short=8 HEAD 2>/dev/null || echo unknown)"
if [[ -n "$(git -C "$DIR" status --porcelain 2>/dev/null)" ]]; then
    # Untracked files count: build-app.sh compiles everything under Sources/,
    # so an uncommitted new file is in this binary whether git tracks it or not.
    GIT_SHA="$GIT_SHA-dirty"
fi
/usr/libexec/PlistBuddy -c "Add :RoostGitSHA string $GIT_SHA" "$CONTENTS/Info.plist" >/dev/null
if [[ ! -f "$DIR/icon/$NAME.icns" ]]; then
    "$DIR/icon/build-icon.sh" >/dev/null 2>&1 || echo "  (icon render failed — building without an app icon)"
fi
if [[ -f "$DIR/icon/$NAME.icns" ]]; then
    cp "$DIR/icon/$NAME.icns" "$CONTENTS/Resources/$NAME.icns"
fi

# 4) code-sign (must be last; any later edit invalidates it). No --keychain:
#    codesign resolves identities through the user's keychain search list, which
#    setup-signing.sh registers ours on. Passing --keychain alone does not work.
codesign --force --sign "$IDENTITY" "$BUILD"

echo "Built $BUILD"
if [[ "$IDENTITY" == "-" ]]; then
    echo "  (ad-hoc signed — macOS re-prompts for Keychain access on each rebuild;"
    echo "   run ./setup-signing.sh once for a stable identity that avoids it.)"
else
    echo "  (signed as \"$IDENTITY\")"
fi

# 5) optional install
if [[ "${1:-}" == "--install" ]]; then
    # Replacing a running copy leaves a zombie in the menu bar; stop it first.
    pkill -x "$NAME" 2>/dev/null || true
    rm -rf "$DEST"
    cp -R "$BUILD" "$DEST"
    "$LSREG" -f "$DEST"
    touch "$DEST"
    echo "Installed $DEST"
fi
