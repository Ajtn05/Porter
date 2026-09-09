#!/bin/bash
# Renders Branding/porter-icon.svg into the app's AppIcon asset set.
#
# Run after editing the SVG. The rasterising and the downsampling both live in
# render-icon.swift; this script only names the sizes macOS asks for.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="Branding/porter-icon.svg"
OUT="App/Resources/Assets.xcassets/AppIcon.appiconset"

[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }

# macOS requires 16/32/128/256/512 at both 1x and 2x.
swift Scripts/render-icon.swift "$SRC" "$OUT" \
    icon_16x16:16 icon_16x16@2x:32 icon_32x32:32 icon_32x32@2x:64 \
    icon_128x128:128 icon_128x128@2x:256 icon_256x256:256 \
    icon_256x256@2x:512 icon_512x512:512 icon_512x512@2x:1024

echo "wrote $(ls "$OUT"/*.png | wc -l | tr -d ' ') PNGs to $OUT"
