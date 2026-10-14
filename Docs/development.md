# Developing Porter

Requires macOS 14+, Xcode 26, and XcodeGen. Run the commands below from the
repository root unless a command changes directory. The app target needs a
signing team in `project.yml`.

## Building and checks

```bash
(cd Kit && swift test)
```

```bash
(
  set -e
  mkdir -p build
  rm -rf build/Porter.app build/DerivedData build/release DerivedData
  rm -f build/build-info.json
  : > build/build.log
  trap 'rm -rf build/Porter.app' ERR
  bash Scripts/fetch-platform-tools.sh
  xcodegen generate
  xcodebuild -project Porter.xcodeproj -scheme Porter -configuration Release \
    -derivedDataPath build/DerivedData build > build/build.log 2>&1
  ditto build/DerivedData/Build/Products/Release/Porter.app build/Porter.app
  plutil -lint build/Porter.app/Contents/Info.plist \
    build/Porter.app/Contents/PlugIns/PorterFileProvider.appex/Contents/Info.plist
  codesign --verify --deep --strict build/Porter.app
  rm -rf build/DerivedData
)
```

Every app build replaces the previous output at `build/Porter.app`. Remove any
other stale Porter build output before building. Build intermediates use
`build/DerivedData` and are removed after verification. The
repository-wide build and sandbox rules are in [AGENTS.md](../AGENTS.md).

Browser state checks run without launching the app or contacting a phone:

```bash
bash Scripts/test-browser-state.sh
bash Scripts/test-app-browser.sh
```

The app browser checks use temporary fixture folders under `build/` to exercise
navigation and refresh in the real app model without launching Porter or
contacting a phone.

The Xcode project compiles the `Kit/Sources/PorterKit` sources as a local static
library target. `Kit/` also remains a Swift package for tests and the diagnostic
CLI. Building the app does not require Swift package resolution.

### Release packaging

Commit the release changes before packaging. The script requires a clean
checkout and `Docs/releases/v<version>.md` matching `project.yml`, so the
source archive and metadata identify the exact code compiled into the app.

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

## Repository layout

```
Kit/                    Swift package - all the logic, no UI
  Sources/PorterKit/
    Model/              Paths, devices, volumes, errors
    Transport/          DeviceTransport, ADB, and MTP
    Engine/             Queue, planner, and the copy engine
    Discovery/          USB bus watching and device merging
    Support/            Checksums, sanitising, throughput
  Sources/porterctl/     Diagnostic CLI
  Tests/                Swift package tests
App/                    The SwiftUI app
FileProvider/           Read-only Finder extension
FileProviderShared/     App-Group request and metadata types
project.yml             XcodeGen input; generates Porter.xcodeproj
```

## Diagnostic CLI

`porterctl` runs the same transport code the app runs and prints what it saw.

```bash
cd Kit && swift build --product porterctl
./.build/debug/porterctl devices
```

```
adb: /Users/you/Library/Android/sdk/platform-tools/adb
DEVICE_SERIAL  SM S901E  [adb]  ready
    usb 04e8:6860  interfaces: 6/1/1 2/2/1 10/0/0 255/66/1
```

Interface numbers let the app distinguish a phone in file-transfer mode from
one that is only charging.

Other commands: `volumes`, `ls`, `biggest`, `pull`, `pull-tree`, `resume-test`,
`checksum`, and `mtp`, which drives the MTP transport directly and reports what
is holding the still-image interface. `mtp-watch` reports whether Porter won
that interface on each subsequent attach. The two MTP commands do not use ADB.

## Recorded ADB measurements

Earlier Galaxy S22 testing recorded 30 MB/s against a 37.6 MB/s `adb pull`
baseline, with checksum verification. A 3 GB / 716-file batch completed with 716 verified
and no failures. The small-file batching implementation is covered by fake
device tests; its real-device throughput still needs measuring.

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

## Further reading

- [Architecture](architecture.md)
- [Implementation and validation status](status.md)
- [Testing notes](testing-notes.md)
- [Repository build and sandbox instructions](../AGENTS.md)

[Back to Porter](../README.md)
