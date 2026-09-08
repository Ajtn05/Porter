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


**Not finished:**

- **MTP** — the transport for phones without USB debugging, as this is a developer option which when enabled can be flagged by utility apps with strict security such as banking apps. 
- **The Android companion app** for Wi-Fi. Not started.
- **The File Provider extension** (phone in the Finder sidebar). Not started.
  Note before attempting it: the extension is sandboxed and therefore cannot
  spawn `adb`, so it has to proxy to the main app over XPC.
- **Phase 3** — photo import, watched folders, APK sideloading. Not Started
- **Signing and notarisation**, and bundling `adb` (see `Scripts/`).

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
  Tests/                66 tests
App/                    The SwiftUI app
project.yml             XcodeGen input; generates Porter.xcodeproj
```


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
`checksum`.

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
