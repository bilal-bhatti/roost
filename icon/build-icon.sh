#!/bin/bash
# build-icon.sh — renders the master PNG, scales it into an .iconset, and packs
# Roost.icns. build-app.sh calls this automatically when the .icns is missing,
# so the artifacts stay out of git.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
NAME="Roost"
MASTER="$DIR/roost-1024.png"
SET="$DIR/roost.iconset"

swift "$DIR/draw-icon.swift" "$MASTER"

rm -rf "$SET"
mkdir -p "$SET"
# The exact filenames iconutil expects; each @2x is the next size up.
for size in 16 32 128 256 512; do
    sips -z $size $size            "$MASTER" --out "$SET/icon_${size}x${size}.png"    >/dev/null
    sips -z $((size*2)) $((size*2)) "$MASTER" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$SET" -o "$DIR/$NAME.icns"
echo "Built $DIR/$NAME.icns"
