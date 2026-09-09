<div align="center">
<img src="Branding/porter-icon.svg" width=256>

# Porter

A free, native macOS app for moving files to and from an Android phone, over a
cable or over Wi-Fi

Google discontinued Android File Transfer in May 2024 and most alternatives are either paid, bloated, or look outdated. This aims to replace all that. With this service, the phone behaves like a drive with  transfers
resuming when connection is interrupted, and every file is checksum-verified.
</div>

## Status

Early functionality works on testing with a Galaxy S22 on Android 16: browse,
copy, resume, verify, over USB with `adb`.


**Works:** device discovery over the USB bus, including telling a phone in
file-transfer mode from one that is only charging. Full filesystem browse.
Copying in both directions with a durable queue, block-aligned resume, and
SHA-256 verification of every file. Conflict handling, filename sanitising, and
preflight checks for free space and the FAT32 4 GiB ceiling.

**Statistics:** 30 MB/s against a 37.6 MB/s `adb pull` baseline, with checksum
verification. 3 GB / 716-file batch completed with
716 verified and 0 failures.


**Not finished, in the order it is being done:**

1. **MTP** — the transport for phones without USB debugging, which is a developer
   option, and one that utility apps with strict security such as banking apps
   will flag when it is on. This is the gap that decides whether the app works for
   anyone who is not a developer, so it goes first. The wire protocol, the session
   layer, and the USB pipe under them are all written; the pipe is blocked on
   macOS itself, described below.

   **The `ptpcamerad` problem.** MTP rides on the USB still-image interface,
   class 6/1/1. macOS opens that interface on anything publishing one, through
   `/usr/libexec/ptpcamerad`, and holds it for as long as the phone is plugged
   in. The open is exclusive, so `USBInterfaceOpen` returns
   `kIOReturnExclusiveAccess`. Measured on a Galaxy S22, every way around it
   fails:

   - `USBInterfaceOpenSeize`, the documented way to take an interface from
     another user-space client, returns the same error.
   - Opening the parent `IOUSBHostDevice` first succeeds and changes nothing.
   - `SetConfiguration` to the value already set is a no-op in
     `IOUSBHostFamily`, so it does not rebuild the interface nubs.
   - `ptpcamerad` is protected by System Integrity Protection: `kill` returns 0
     and the process does not die.
   - ImageCaptureCore, which would be the supported way to send PTP through
     `ptpcamerad` rather than around it, does not publish the phone at all.
     `ICDeviceBrowser` reports zero devices while `ptpcamerad` holds the
     interface, so `ICCameraDevice.requestSendPTPCommand` has nothing to send
     to.

   What is left is a race. Both processes are woken by the same match
   notification, and whoever calls `USBInterfaceOpen` first keeps the interface
   until the cable is pulled. `MTPInterfaceClaimer` enters that race: it
   registers `kIOFirstMatchNotification` narrowed to the still-image class and
   opens the interface inside the callback, with only a vendor check in
   between. It is started by `DeviceCoordinator.start()`, so it is armed for the
   life of the app; a phone already attached at launch is always lost, and only
   a replug can be won. Claims are held for the whole attachment and lent to
   `MTPUSBPipe`, which gives them back rather than closing them, because a
   closed interface goes straight back to `ptpcamerad`.

   Only phones are claimed, never cameras: `AndroidVendorIDs` gates it, so
   importing from a DSLR in Image Capture is untouched. Importing from a
   *phone* is not — while Porter holds the interface, Photos and Image Capture
   cannot see it. That is the trade.

   Where the race is lost, `MTPTransport` fails with an error naming the
   process that won it, read from the interface's own `UsbExclusiveOwner`
   property rather than guessed at. `porterctl mtp` prints that for the
   attached phone; `porterctl mtp-watch` sits on the notification and reports
   who won each attach, which is how the race is measured.
2. **Batching small files.** Written, and verified against the fake device
   rather than a phone. Per-file overhead was about 145 ms, charged per call
   rather than per byte, which is what held a folder of thumbnails to 8 MB/s
   while a single large file managed 30.

   It was two round trips a file: one `adb pull`, one `adb shell sha256sum`.
   Both are now batched, on the same demand-driven shape. The first small file
   dispatched fetches the small pulls queued behind it, and the first to reach
   verification hashes them, so the rest find their sidecar whole and their
   hash cached. `adb pull` takes a list of paths and a directory, and
   `sha256sum` takes a list, so each batch is one process and one round trip.
   Files above 8 MiB are still handled one at a time, where the device reading
   the file dwarfs the round trip.

   Over a 40-file folder that is one read call and one hash call against 40 of
   each. What is left is measuring it on the Galaxy S22: the call counts are
   what the tests pin, not the resulting MB/s.
3. **The Android companion app** for Wi-Fi. Not started. `WiFiTransport` is
   already complete against `WiFiProtocol.swift` and simply has no server to talk
   to. Third rather than first because it is a whole second codebase in a second
   language, and the USB side should be honestly done before that starts.
4. **The File Provider extension** (phone in the Finder sidebar). Not started.
   Note before attempting it: the extension is sandboxed and therefore cannot
   spawn `adb`, so it has to proxy to the main app over XPC.

Behind those: **Phase 3** — photo import, watched folders, APK sideloading. Not
started. **Signing and notarisation**, and bundling `adb` (see `Scripts/`), are
release work rather than a phase, and block only the first build handed to
somebody else.

Sustained multi-hour throughput is untested; it drops under load as the phone
throttles.

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
  Tests/                165 tests
App/                    The SwiftUI app
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

Interface numbers are how the app tells a phone in file-transfer mode from
one that is only charging 

Other commands: `volumes`, `ls`, `biggest`, `pull`, `pull-tree`, `resume-test`,
`checksum`, and `mtp`, which drives the MTP transport directly and reports what
is holding the still-image interface.

## Decision Considerations

**Transport and Interface.** `ADBTransport` is defaulted as it is the only
one that can seek within a file, hash a file in place, report honest sizes, and
set an mtime. `WiFiTransport` talks to a companion Android app. `MTPTransport`
is the fallback for phones without USB debugging. Each publishes a
`TransportCapabilities`, and the engine reads that instead of switching on the
transport kind. 

**Partial files.** In-flight bytes live in a `.porterpart`
sidecar. The real filename only appears once the file is whole and verified. Pulling
the cable leaves a recognizable relaunch resume point.

**Verification.** The device hashes its own copy with `sha256sum`, we
hash ours, and a mismatch discards the result. When a device has no hashing tool
the app completes the copy and says the file was *not* verified.



**Errors.** "This phone is connected but set to
charge only" will show steps to fix it instead of showing "no storage found".

## Non-goals

Will not be implemeting cloud relay, account system, screen mirroring, SMS bridging, or 
remote control. No telemetry. This is a file transfer tool lol.
