#!/usr/bin/env bash
# Downloads Google's Android platform-tools and installs `adb` where the app
# bundle expects it.
#
# The app ships its own adb so that no separate platform-tools install is
# required.
#
# Not run automatically: it fetches a binary from Google, which is the
# packager's decision rather than the build system's.
set -euo pipefail

repository_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_dir"
DESTINATION="${1:-App/Resources/platform-tools}"
URL="https://dl.google.com/android/repository/platform-tools_r37.0.1-darwin.zip"
EXPECTED_SHA256="ee39ad5967e95c2a07f04dbcbde96b1a0c916ba376096db5d2f498b7727a5d1d"
mkdir -p build
WORK="$(mktemp -d "$repository_dir/build/platform-tools.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "Downloading $URL"
if [[ -n "${2:-}" ]]; then
    cp "$2" "$WORK/platform-tools.zip"
else
    curl --fail --location --progress-bar "$URL" --output "$WORK/platform-tools.zip"
fi

actual_sha256="$(shasum -a 256 "$WORK/platform-tools.zip" | awk '{print $1}')"
if [[ "$actual_sha256" != "$EXPECTED_SHA256" ]]; then
    echo "Platform-tools checksum mismatch: $actual_sha256" >&2
    exit 1
fi

unzip -q "$WORK/platform-tools.zip" -d "$WORK"
mkdir -p "$DESTINATION"

# adb needs its support files alongside it, not just the binary.
for file in adb NOTICE.txt source.properties; do
    cp "$WORK/platform-tools/$file" "$DESTINATION/"
done
printf '%s\n' "$actual_sha256" > "$DESTINATION/archive.sha256"

chmod +x "$DESTINATION/adb"
echo "Installed $("$DESTINATION/adb" version | head -1) into $DESTINATION"
echo
echo "Next: sign it as part of the app bundle. A nested executable must carry"
echo "the same Developer ID signature and the Hardened Runtime, or Gatekeeper"
echo "will refuse to launch the app on another Mac:"
echo "  codesign --force --options runtime --sign \"Developer ID Application: ...\" \"$DESTINATION/adb\""
