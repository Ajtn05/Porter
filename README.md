<div align="center">
<img src="Branding/porter-icon.svg" width=256>

# Porter

A free, native macOS app for moving files to and from an Android phone over a
USB cable. It supports USB debugging (ADB) and standard Android File Transfer
mode (MTP), so USB debugging is optional.

Google discontinued Android File Transfer in May 2024. Porter aims to replace
it with resumable, checksum-verified ADB transfers and direct MTP support.
</div>

## Status

Version 1.0.0 is being prepared as a GitHub release. The universal release build
bundles ADB; public distribution signing and notarization are pending. See the
[v1.0.0 release notes](Docs/releases/v1.0.0.md) for installation and known limits.

Early functionality has been tested with a Galaxy S22 on Android 16. It can
browse and copy over USB debugging (ADB) or normal File Transfer mode (MTP).


**Works:** USB discovery identifies file-transfer mode separately from
charge-only mode. When a phone is available through both cable transports,
Porter uses the faster ADB connection; when it is only in File Transfer mode,
it falls back to MTP automatically. Both transports support volume and folder
browsing, creating folders, deleting, renaming, moving within a volume, and
copying files in both directions. Conflict handling, filename sanitising, and
the available preflight checks for free space and the FAT32 4 GiB ceiling are
shared by the transfer engine.

ADB transfers have block-aligned resume, modification-date preservation, and
SHA-256 verification against the device. Small ADB files are batched for both
pulling and hashing: files at or below 8 MiB can share one `adb pull` and one
`sha256sum` call instead of paying two round trips per file.

**Measured with ADB:** 30 MB/s against a 37.6 MB/s `adb pull` baseline, with
checksum verification. A 3 GB / 716-file batch completed with 716 verified
and no failures. The small-file batching implementation is covered by fake
device tests; its real-device throughput still needs measuring.

## Browser views and previews

The Mac and Android panes have separate saved view modes, sort orders,
hidden-file rules, and icon-preview toggles. Use the controls in each pane's
header to switch between list and icon view independently.

Each pane has an optional preview sidebar showing the selected file's thumbnail
and metadata, with Quick Look and a summary for multiple selections. Its width
can be resized, and each pane's sidebar button hides or shows its own preview.
Settings saves the Mac and Android sidebar toggles independently. The Mac
sidebar previews local files directly and shares the Mac icon thumbnail cache.
Icon view also shows thumbnails for supported images, movies, PDFs, text, and documents
when macOS can generate them. Unsupported files keep their file-type icons.

MTP icon previews prefer native thumbnails supplied by the phone, including
for large originals, instead of downloading full files. Missing thumbnails keep
the file-type icon. Settings can enable slower full-file icon fallbacks, capped
at 16 MB per file and 64 MB per folder visit. Selection previews can use a
bounded full-file fallback; Quick Look explicitly loads larger files.

Fetches run one at a time and pause during directory loading and transfers.
A bounded memory cache shares images between the sidebar and icons and reuses
them across folder visits. File bytes used for fallbacks are deleted after
rendering. Refresh and device changes clear the remote image cache. Settings
also contains the preview/sidebar options, each pane's preferences, and the
menu bar button toggle; choices persist across launches.

The storage root also uses one property-list request where supported, with
handle 0 and depth 0, then filters the result by storage and parent. This avoids
per-item metadata round trips without recursively enumerating the phone.
Unsupported or incomplete replies use the ordinary handle/object-info path.
The wire shapes follow [Android's MTP database implementation](https://android.googlesource.com/platform/frameworks/base/+/master/media/java/android/mtp/MtpDatabase.java)
and [native thumbnail API](https://developer.android.com/reference/android/mtp/MtpDevice#getThumbnail(int)).

## MTP, without USB debugging

MTP is the fallback for a wired phone that is in File Transfer mode but has not
enabled USB debugging. Porter implements the MTP wire protocol, USB bulk pipe,
and session layer directly. Its transactions are serialised, so a quick folder
change cannot consume another request's reply.

MTP has protocol limits that Porter exposes rather than conceals: one transfer
runs at a time; interrupted transfers restart rather than resume; device-side
checksums are unavailable, so completed transfers are marked unverified; and
modification-date preservation and free-space or file-size reports are best
effort. Enable USB debugging when resumable, checksum-verified transfers are
more important than avoiding the developer option.

macOS normally gives the MTP interface to `ptpcamerad`, and that exclusive
claim cannot be taken back. Porter starts an interface claimer with the app and
races it when the phone is attached. Start Porter before connecting the phone.
If another app wins, Porter prompts you to ask it to quit, then reconnect the
phone so Porter can claim MTP. If macOS's `ptpcamerad` wins, Porter explains
that the system service cannot be closed and prompts you to reconnect instead.
`porterctl mtp` identifies
the process holding the interface, and `porterctl mtp-watch` reports the result
of each attach. Porter only claims known Android phones, never cameras. While
it holds a phone's MTP interface, Photos and Image Capture cannot use that
phone until it is unplugged.

## Next

1. **Validate Finder access.** A read-only File Provider extension can register
   a phone in Finder and asks the host app to materialize whole files through
   an App-Group bridge. Signed, on-device Finder browsing and downloads still
   need integration testing before this is a supported path.
2. **Measure MTP on real devices.** Check large files, mixed folders, and
   device compatibility before changing USB buffer sizes or transaction shape.
3. **Phase 3:** photo import, watched folders, and APK sideloading.

Developer ID signing and notarisation remain release work. The release script
bundles a checksum-pinned ADB binary and its notices. Sustained multi-hour throughput also
needs testing; it falls as the phone throttles under load.

## Layout

```
Kit/                    Swift package - all the logic, no UI
  Sources/PorterKit/
    Model/              Paths, devices, volumes, errors
    Transport/          DeviceTransport, ADB, and MTP
    Engine/             Queue, planner, and the copy engine
    Discovery/          USB bus watching and device merging
    Support/            Checksums, sanitising, throughput
  Sources/porterctl/       Read-only diagnostic CLI
  Tests/                Swift package tests
App/                    The SwiftUI app
FileProvider/           Read-only Finder extension
FileProviderShared/     App-Group request and metadata types
project.yml             XcodeGen input; generates Porter.xcodeproj
```


## Comment conventions

Comments explain **why**, never **what** — they record a measurement, name a bug
that was hit, or explain why an obvious alternative was rejected. A comment that
only restates its code should be deleted rather than reworded.

The register is flat, and uniform across the codebase:

- Third person. No `we`, `us`, `our`, or `you` in a comment.
- The engineering reason, not the product reason. "Auto-select the first
  browsable device so plugging in a phone is enough to start browsing", not
  "making the user click it is friction for nothing".
- No editorialising. State the guarantee rather than praising it.
- ASCII punctuation. Em dashes and typographic quotes are used deliberately in
  user-facing strings; comments use a comma, a colon, or a new sentence.
- `///` for API docs, `//` for inline notes. A doc comment opens with one
  declarative sentence; anything longer goes in a second paragraph after a
  blank `///` line.
- A test pinning a past bug opens with `// Regression:`.

None of that licenses stripping comments back to nothing. The specifics are why
they are worth reading — superblock magic numbers, the measured 37.6 against
15.7 MB/s, why `iflag=skip_bytes` is avoided, why a cancelled task must be
awaited. Keep every one of those; cut only the narration around them.


## Building

```bash
cd Kit && swift test
```

```bash
bash Scripts/fetch-platform-tools.sh
rm -rf build/Porter.app build/DerivedData
xcodegen generate
xcodebuild -project Porter.xcodeproj -scheme Porter -configuration Release \
  -derivedDataPath build/DerivedData build
ditto build/DerivedData/Build/Products/Release/Porter.app build/Porter.app
codesign --verify --deep --strict build/Porter.app
rm -rf build/DerivedData
```

Every app build replaces the previous output at `build/Porter.app`. Build
intermediates use `build/DerivedData` and are removed after verification. The
repository-wide build and sandbox rules are in [AGENTS.md](AGENTS.md).

Browser state checks run without launching the app or contacting a phone:

```bash
bash Scripts/test-browser-state.sh
```

macOS 14+, Xcode 26. The app target needs a signing team; set `DEVELOPMENT_TEAM`
in `project.yml`.

The Xcode project compiles the `Kit/Sources/PorterKit` sources as a local static
library target. `Kit/` also remains a Swift package for tests and the diagnostic
CLI. Building the app does not require Swift package resolution.

### Release packaging

```bash
bash Scripts/fetch-platform-tools.sh
bash Scripts/build-release.sh
```

The script builds both Mac architectures, verifies the embedded extension and
bundled ADB, and writes a ZIP, source archive, checksums, and build metadata to
`build/release/`. The single unpacked app remains at `build/Porter.app`.
Without `PORTER_SIGNING_IDENTITY`, the output is ad hoc signed for testing and
is not notarized. Set that variable to a Developer ID Application identity for
distribution signing; notarization must still be completed separately.

## The diagnostic CLI

`porterctl` runs the same transport code the app runs and prints what it saw.

```bash
cd Kit && swift build --product porterctl
./.build/debug/porterctl devices
```

```
adb: /Users/you/Library/Android/sdk/platform-tools/adb
R5CT502XWRL  SM S901E  [adb]  ready
    usb 04e8:6860  interfaces: 6/1/1 2/2/1 10/0/0 255/66/1
```

Interface numbers let the app distinguish a phone in file-transfer mode from
one that is only charging.

Other commands: `volumes`, `ls`, `biggest`, `pull`, `pull-tree`, `resume-test`,
`checksum`, and `mtp`, which drives the MTP transport directly and reports what
is holding the still-image interface. `mtp-watch` reports whether Porter won
that interface on each subsequent attach. The two MTP commands do not use ADB.

## Decision Considerations

**Transport and interface.** `ADBTransport` is preferred because it can seek
within a file, hash a file in place, report reliable sizes, and set an mtime.
`MTPTransport` is the direct USB fallback for phones without USB debugging.
Both publish `TransportCapabilities`, and the engine reads those rather than switching on
the transport kind.

**Partial files.** In-flight bytes live in a `.porterpart` sidecar. The real
filename only appears once the file is complete. ADB can resume an aligned
partial after a disconnect; MTP deliberately restarts it because ranged reads
and resumable writes are not dependable across Android MTP implementations.

**Verification.** With ADB, the device hashes its own copy and
Porter hashes its copy; a mismatch discards the result. MTP has no device-side
checksum operation, so an MTP transfer can complete but is marked *unverified*.



**Errors.** "This phone is connected but set to
charge only" will show steps to fix it instead of showing "no storage found".

## Non-goals

Will not be implemeting cloud relay, account system, screen mirroring, SMS bridging, or 
remote control. No telemetry. This is a file transfer tool lol.
