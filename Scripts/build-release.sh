#!/usr/bin/env bash
set -euo pipefail
repository_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_dir"

# There is one unpacked app, and a failed build must never leave it current.
mkdir -p build
rm -rf build/Porter.app build/DerivedData DerivedData build/release
rm -f build/build-info.json
trap 'rm -rf build/Porter.app build/release; rm -f build/build-info.json' ERR
[[ -x App/Resources/platform-tools/adb ]] || {
    echo 'Run bash Scripts/fetch-platform-tools.sh before packaging a release.' >&2
    exit 1
}

xcodegen generate
extra_settings=()
if [[ -n "${PORTER_SWIFT_FLAGS:-}" ]]; then
    extra_settings+=("OTHER_SWIFT_FLAGS=$PORTER_SWIFT_FLAGS")
fi
xcodebuild build -project Porter.xcodeproj -scheme Porter \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath build/DerivedData ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
    DEVELOPMENT_TEAM='' "${extra_settings[@]}" > build/build.log 2>&1
ditto build/DerivedData/Build/Products/Release/Porter.app build/Porter.app

app=build/Porter.app
extension="$app/Contents/PlugIns/PorterFileProvider.appex"
adb="$app/Contents/Resources/platform-tools/adb"
[[ -x "$adb" && -s "$app/Contents/Resources/platform-tools/NOTICE.txt" ]]
[[ -s "$app/Contents/Resources/LICENSE" ]]
for binary in "$app/Contents/MacOS/Porter" "$extension/Contents/MacOS/PorterFileProvider" "$adb"; do
    lipo -verify_arch arm64 x86_64 "$binary"
done

identity="${PORTER_SIGNING_IDENTITY:--}"
sign_options=(--force --sign "$identity" --options runtime)
if [[ "$identity" == '-' ]]; then
    sign_options+=(--timestamp=none)
else
    sign_options+=(--timestamp)
fi
codesign "${sign_options[@]}" "$adb"
codesign "${sign_options[@]}" --entitlements FileProvider/Resources/PorterFileProvider.entitlements "$extension"
codesign "${sign_options[@]}" --entitlements App/Resources/Porter.entitlements "$app"
codesign --verify --strict --verbose=2 "$adb"
codesign --verify --deep --strict --verbose=2 "$app"
plutil -lint "$app/Contents/Info.plist" "$extension/Contents/Info.plist"
rm -rf build/DerivedData

mkdir -p build/release
python3 - "$identity" <<'PY'
from datetime import datetime, timezone
from pathlib import Path
import hashlib, json, plistlib, subprocess, sys
app = Path('build/Porter.app')
info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
extension_info = plistlib.loads((app/'Contents/PlugIns/PorterFileProvider.appex/Contents/Info.plist').read_bytes())
assert info['CFBundleShortVersionString'] == extension_info['CFBundleShortVersionString']
assert info['CFBundleVersion'] == extension_info['CFBundleVersion']
assert extension_info['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.fileprovider-nonui'
record = {
    'built_at_utc': datetime.now(timezone.utc).isoformat(),
    'configuration': 'Release',
    'architectures': ['arm64', 'x86_64'],
    'minimum_macos': info['LSMinimumSystemVersion'],
    'bundle_identifier': info['CFBundleIdentifier'],
    'version': info['CFBundleShortVersionString'],
    'build_number': info['CFBundleVersion'],
    'source_commit': subprocess.check_output(['git', '-c', 'core.fsmonitor=false', 'rev-parse', 'HEAD'], text=True).strip(),
    'source_dirty': bool(subprocess.check_output(['git', '-c', 'core.fsmonitor=false', 'status', '--porcelain'], text=True).strip()),
    'signature': 'ad hoc' if sys.argv[1] == '-' else sys.argv[1],
    'notarized': False,
    'finder_extension_embedded': True,
    'desktop_ui_tests_run': False,
    'adb_platform_tools_version': (app/'Contents/Resources/platform-tools/source.properties').read_text().strip(),
    'adb_archive_sha256': (app/'Contents/Resources/platform-tools/archive.sha256').read_text().strip(),
    'binary_sha256': {
        str(path.relative_to(app)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in [app/'Contents/MacOS/Porter',
                     app/'Contents/PlugIns/PorterFileProvider.appex/Contents/MacOS/PorterFileProvider',
                     app/'Contents/Resources/platform-tools/adb']
    },
    'xcode_version': subprocess.check_output(['xcodebuild', '-version'], text=True).strip()
}
Path('build/build-info.json').write_text(json.dumps(record, indent=2)+'\n')
Path('build/release/build-info.json').write_text(json.dumps(record, indent=2)+'\n')
PY

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
ditto -c -k --sequesterRsrc --keepParent "$app" "build/release/Porter-$version-macos-universal.zip"
git -c core.fsmonitor=false archive --format=tar.gz -o "build/release/Porter-$version-source.tar.gz" HEAD
cp Docs/releases/v1.0.0.md build/release/RELEASE-NOTES.md
cp LICENSE build/release/LICENSE
(
    cd build/release
    shasum -a 256 "Porter-$version-macos-universal.zip" "Porter-$version-source.tar.gz" build-info.json RELEASE-NOTES.md LICENSE > SHA256SUMS.txt
)
echo "Release assets: $repository_dir/build/release"
if [[ "$identity" == '-' ]]; then
    echo 'This build is ad hoc signed and not notarized. Public distribution signing remains pending.'
fi
