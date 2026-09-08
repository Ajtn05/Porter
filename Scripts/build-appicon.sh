#!/bin/bash
# Renders Branding/porter-icon.svg into the app's AppIcon asset set.
#
# Run after editing the SVG. Uses qlmanage rather than ImageMagick to rasterise:
# ImageMagick builds without an SVG delegate produce a black image instead of
# reporting an error.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="Branding/porter-icon.svg"
OUT="App/Resources/Assets.xcassets/AppIcon.appiconset"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }

# Render one master and downsample it. Rendering each size directly from the
# SVG produces worse small sizes than Lanczos-reducing a 1024px master.
qlmanage -t -s 1024 -o "$TMP" "$SRC" >/dev/null 2>&1
MASTER="$TMP/$(basename "$SRC").png"
[ -f "$MASTER" ] || { echo "qlmanage failed to render $SRC" >&2; exit 1; }

mkdir -p "$OUT"
# macOS requires 16/32/128/256/512 at both 1x and 2x.
for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
            "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
            "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
    set -- $spec
    magick "$MASTER" -filter Lanczos -resize "$1x$1" -strip "$OUT/$2.png"
done

echo "wrote $(ls "$OUT"/*.png | wc -l | tr -d ' ') PNGs to $OUT"
