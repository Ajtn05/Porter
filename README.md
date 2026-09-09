<div align="center">
<img src="Branding/porter-icon.svg" width=256>

# Porter

A free, native macOS app for moving files to and from an Android phone over a
USB cable or the local network. It supports USB debugging (ADB), the standard
Android file-transfer mode (MTP), and a paired Wi-Fi companion app, so USB
debugging is optional.

Google discontinued Android File Transfer in May 2024 and most alternatives are either paid, bloated, or look outdated. This aims to replace all that. The phone behaves like a drive, with resumable and checksum-verified ADB or paired Wi-Fi transfers plus a standard MTP fallback when USB debugging is off.
</div>

## Status

Early functionality has been tested with a Galaxy S22 on Android 16. It can
browse and copy over USB debugging (ADB) or normal File Transfer mode (MTP).
The new paired Wi-Fi path builds on both platforms and is ready for on-device
integration testing.


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

## Paired Wi-Fi

The repository now includes `Android/`, a companion app that serves the same
v1 Wi-Fi protocol used by `WiFiTransport`. Start sharing in the companion,
then choose **Pair Wi-Fi Phone** in Porter and enter the phone's local address
and six-digit code, plus its displayed certificate fingerprint. Pairing happens
over TLS; the Mac compares that out-of-band fingerprint to the certificate it
sees and to the pairing reply, then keeps the bearer token in Keychain and pins
that certificate for every later request.
There is no account, cloud relay, or Internet service.

The companion supports volume and directory operations, ranged downloads,
resumable uploads, SHA-256/MD5 checksums, modification dates, and free-space
reports. It advertises `_porter._tcp` on the LAN for future discovery; the Mac
pairing screen currently asks for the address manually. The server restricts
requests to Android shared-storage roots and will not modify a volume root.


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
races it when the phone is attached. Start Porter before connecting the phone;
if another process wins, unplug and reconnect it. `porterctl mtp` identifies
the process holding the interface, and `porterctl mtp-watch` reports the result
of each attach. Porter only claims known Android phones, never cameras. While
it holds a phone's MTP interface, Photos and Image Capture cannot use that
phone until it is unplugged.

## Next

1. **Validate paired Wi-Fi on hardware.** Install the companion on real phones,
   exercise pairing, resume, certificate rejection, storage permissions, and
   long-running transfers. Add Mac-side mDNS discovery after that path is
   proven.
2. **File Provider extension.** This would put the phone in the Finder sidebar.
   The sandboxed extension must proxy ADB work to the main app over XPC.
3. **Phase 3:** photo import, watched folders, and APK sideloading.

Signing, notarisation, and bundling `adb` are release work needed before the
first build is handed to somebody else. Sustained multi-hour throughput also
needs testing; it falls as the phone throttles under load.

## Layout

```
Kit/                    Swift package - all the logic, no UI
  Sources/PorterKit/
    Model/              Paths, devices, volumes, errors
    Transport/          DeviceTransport and its three implementations
    Engine/             Queue, planner, and the copy engine
    Discovery/          USB bus watching and device merging
    Support/            Checksums, sanitising, throughput
  Sources/porterctl/       Read-only diagnostic CLI
  Tests/                172 tests
App/                    The SwiftUI app
Android/                Companion app for local Wi-Fi transfers
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
xcodegen generate && open Porter.xcodeproj
```

macOS 14+, Xcode 26. The app target needs a signing team; set `DEVELOPMENT_TEAM`
in `project.yml`.

The Android companion uses JDK 17, Android SDK platform 35, and Gradle 9.6 or
newer. With an Android SDK configured locally:

```bash
cd Android && ./gradlew :app:assembleDebug
```

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
`WiFiTransport` speaks to the paired local Android companion. Each publishes
`TransportCapabilities`, and the engine reads those rather than switching on
the transport kind.

**Partial files.** In-flight bytes live in a `.porterpart` sidecar. The real
filename only appears once the file is complete. ADB can resume an aligned
partial after a disconnect; MTP deliberately restarts it because ranged reads
and resumable writes are not dependable across Android MTP implementations.

**Verification.** With ADB or paired Wi-Fi, the device hashes its own copy and
Porter hashes its copy; a mismatch discards the result. MTP has no device-side
checksum operation, so an MTP transfer can complete but is marked *unverified*.



**Errors.** "This phone is connected but set to
charge only" will show steps to fix it instead of showing "no storage found".

## Non-goals

Will not be implemeting cloud relay, account system, screen mirroring, SMS bridging, or 
remote control. No telemetry. This is a file transfer tool lol.
