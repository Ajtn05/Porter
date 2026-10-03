# Status

Current implementation snapshot: 3 October 2026.

| Area | State | Remaining boundary |
| --- | --- | --- |
| ADB USB transfers | Implemented | Earlier Galaxy S22 testing exercised browse and copy. Resume, checksums, modification dates, and small-file batching have package test coverage. |
| MTP USB transfers | Implemented | Direct protocol codec, USB pipe, session, interface claimer, and transport are present. The session serializes metadata requests and a complete upload as one exchange. More real-device performance and compatibility measurements are needed. |
| Finder File Provider | Read-only source prototype | The extension enumerates storage and asks the host app to materialize files through an App-Group bridge. Signed Finder registration and downloads need on-device validation. |
| Browser views and previews | Implemented | Each pane saves its own view, sort, and hidden-file preferences. The Android sidebar and icons prefer native MTP thumbnails, reuse cached images across folders, and defer previews during directory loading; Settings includes the menu bar toggle. Layout and thumbnail rendering still need runtime validation. |
| Phase 3 | Partial | Quick Look materializes a selected remote file. Photo import, watched folders, and APK sideloading remain future work. |

The Android companion and paired Wi-Fi transfer path have been removed. Porter
connects to phones over USB through ADB or MTP.

## Build verification

A clean Apple silicon Release build of the app, its local PorterKit static
library, and the embedded Finder extension succeeded inside the workspace
sandbox on 3 October 2026. The local app bundle passed signature and bundle
checks. It was not launched during this check; Finder and phone behavior still
need runtime validation. Browser state checks also passed eleven command-line
checks for independent preference encoding, thumbnail reuse, request ordering,
download limits, failure caching, cancellation, folder-cache reuse, and native
preview fallback behavior. All 184 package tests in 22 suites passed, including
root property-list filtering and bounded native thumbnail transactions.

## Transport guarantees

| Capability | ADB | MTP |
| --- | --- | --- |
| Resume interrupted download or upload | Yes | No |
| Compare a device-side checksum | Yes | No |
| Preserve modification time | Yes | Best effort |
| Free-space report | Yes | Best effort |
| Concurrent streams | Engine-limited | One |

Incoming bytes use a `.porterpart` sidecar until complete. MTP downloads and
uploads restart after interruption; a completed MTP copy is marked unverified
because the protocol has no device-side checksum operation.

## Next checks

1. Validate MTP browsing, large uploads and downloads, cancellation, and
   mixed-file throughput on several phones in File Transfer mode.
2. Validate signed Finder registration and read-only browsing with a real
   phone over both USB transports.
3. Finish signing and notarisation, bundle `adb`, and measure sustained load.
