#!/bin/bash
set -euo pipefail
repository_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_dir"
mkdir -p build/BrowserTestModuleCache
xcrun swiftc -swift-version 6 -parse-as-library \
  -module-cache-path build/BrowserTestModuleCache \
  App/PanePreferences.swift App/PreviewThumbnailStore.swift Tests/BrowserStateChecks.swift \
  -o build/browser-state-checks
build/browser-state-checks
