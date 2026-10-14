#!/bin/bash
set -euo pipefail
repository_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_dir"
mkdir -p build/BrowserTestModuleCache build/SwiftModuleCache build/SwiftPMCache
CLANG_MODULE_CACHE_PATH="$repository_dir/build/SwiftModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$repository_dir/build/SwiftModuleCache" \
swift build --package-path Kit --disable-sandbox --cache-path "$repository_dir/build/SwiftPMCache" \
  --product PorterKit -Xswiftc -module-cache-path -Xswiftc "$repository_dir/build/SwiftModuleCache"
sources=(App/*.swift App/Views/*.swift App/FileProvider/*.swift FileProviderShared/*.swift)
test_sources=()
for source in "${sources[@]}"; do
  [[ "$source" == App/PorterApp.swift ]] || test_sources+=("$source")
done
binary_dir="$(swift build --package-path Kit --disable-sandbox --show-bin-path)"
if [[ -f "$binary_dir/libPorterKit.a" ]]; then
  module_dir="$binary_dir"
  kit_objects=("$binary_dir/libPorterKit.a")
else
  module_dir="$binary_dir/Modules"
  kit_objects=("$binary_dir/PorterKit.build/"*.o)
fi
xcrun swiftc -swift-version 6 -parse-as-library -disable-sandbox \
  -module-cache-path build/BrowserTestModuleCache -I "$module_dir" \
  "${test_sources[@]}" Tests/AppBrowserChecks.swift Tests/ClipboardChecks.swift Tests/LocalFileOperationChecks.swift \
  Tests/PhotoImportChecks.swift \
  Kit/Tests/PorterKitTests/FakeTransport.swift "${kit_objects[@]}" \
  -o build/app-browser-checks
build/app-browser-checks
