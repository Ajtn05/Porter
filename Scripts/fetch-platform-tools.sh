#!/usr/bin/env bash
# Downloads Google's Android platform-tools and puts `adb` where the app bundle
# expects it.
#
# The app ships its own adb because "install Android platform-tools first" is
# exactly the kind of step that makes people give up and go back to emailing
# themselves photos.
#
# This is not run automatically: it fetches a binary from Google, and that is
# the packager's decision to make, not the build system's.
set -euo pipefail

DESTINATION="${1:-App/Resources/platform-tools}"
URL="https://dl.google.com/android/repository/platform-tools-latest-darwin.zip"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Downloading $URL"
curl --fail --location --progress-bar "$URL" --output "$WORK/platform-tools.zip"

echo "Checksum of what was downloaded (record this in the release notes):"
shasum -a 256 "$WORK/platform-tools.zip"

unzip -q "$WORK/platform-tools.zip" -d "$WORK"
mkdir -p "$DESTINATION"

# adb needs its own support files alongside it, not just the binary.
for file in adb; do
    cp "$WORK/platform-tools/$file" "$DESTINATION/"
done

chmod +x "$DESTINATION/adb"
echo "Installed $("$DESTINATION/adb" version | head -1) into $DESTINATION"
echo
echo "Next: sign it as part of the app bundle. A nested executable must carry"
echo "the same Developer ID signature and the Hardened Runtime, or Gatekeeper"
echo "will refuse to launch the app on another Mac:"
echo "  codesign --force --options runtime --sign \"Developer ID Application: ...\" \"$DESTINATION/adb\""
