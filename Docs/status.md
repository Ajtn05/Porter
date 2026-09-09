# Status

Current implementation snapshot: 9 September 2026.

## Implemented

| Area | State | Evidence and remaining boundary |
| --- | --- | --- |
| ADB USB transfers | Implemented | Browse, copy, resume, checksums, mtime, queueing, conflicts, and small-file batching are covered by the Swift package tests. Earlier Galaxy S22 testing exercised the USB path. |
| MTP USB fallback | Implemented | The direct MTP codec, session, USB pipe, interface claimer, and transport are in the app. It is intentionally serial and reports its weaker guarantees honestly. Keep using real devices to broaden compatibility coverage. |
| Wi-Fi client on macOS | Implemented | `WiFiTransport`, secure six-digit pairing, certificate pinning, Keychain storage, the paired-device registry, and a **Pair Wi-Fi Phone** sheet are in the app. |
| Wi-Fi companion on Android | Implemented, hardware validation pending | `Android/` builds a debug APK and implements the v1 HTTPS API, pairing authority, TLS identity, storage scoping, checksums, resume operations, and `_porter._tcp` advertisement. It has not yet been run through a real pairing and sustained transfer in this repository. |
| Finder File Provider | Not started | It must proxy to the main app through XPC because the extension cannot spawn `adb`. |
| Phase 3 features | Not started | Photo import, watched folders, APK sideloading, and Quick Look remain future work. |

## Current automated checks

The Swift package has **172 tests in 22 suites**. `cd Kit && swift test` passes
with the Wi-Fi pairing and transport additions compiled into PorterKit.

The Android companion builds with JDK 17, Android SDK platform 35, and Gradle
9.6 or newer:

```bash
cd Android
./gradlew :app:assembleDebug
```

The debug build is source-level verification, not a substitute for installing
the app on a phone. No Android device is attached to this workspace.

## What each transport promises

| Capability | ADB | MTP | Paired Wi-Fi |
| --- | --- | --- | --- |
| Resume an interrupted download | Yes | No | Yes |
| Resume an interrupted upload | Yes | No | Yes |
| Compare a device-side checksum | Yes | No | Yes |
| Preserve mtime | Yes | Best effort | Yes |
| Free-space report | Yes | Best effort | Yes |
| Concurrent streams | Engine-limited | One | Two |

Every transport writes incoming data to a `.porterpart` sidecar so an incomplete
file never takes the final filename. “Verified” means a device-side hash was
compared; that applies to ADB and Wi-Fi, not MTP.

## Paired Wi-Fi implementation details

The Android app runs a local HTTPS server on port 53317 after the user grants
all-files access and presses **Start sharing**. The server:

- uses a certificate held in Android Keystore;
- displays a six-digit pairing code and its certificate fingerprint, and
  throttles repeated wrong attempts;
- returns a bearer token only to a correct pairing request;
- confines every path to Android shared-storage roots and refuses to mutate a
  volume root;
- supports device information, volumes, listing, stat, mkdir, delete, move,
  read with `Range`, offset writes, SHA-256/MD5, mtime, and free-space reports.

On the Mac, the pairing request temporarily accepts the phone's self-signed
certificate only long enough to calculate its SHA-256 fingerprint. That value
must match both the fingerprint transcribed from the phone and the pairing
reply. Later requests use the bearer token from Keychain and reject any other
certificate. The preferences record has no token, only the display name, host,
port, and pinned fingerprint.

The Android server advertises `_porter._tcp`, but the Mac currently requires a
manual address in the pairing sheet. This avoids presenting unverified network
discovery as a finished user flow.

## Next phases

1. **Wi-Fi device validation.** Install the debug APK on Android 11 or later;
   grant all-files access; pair with a Mac on the same LAN; test browse, copy in
   both directions, interruption/resume, wrong code handling, changed
   certificate rejection, and a sustained mixed-file transfer. Record device,
   Android release, throughput, and failures.
2. **Mac-side mDNS discovery.** Browse `_porter._tcp`, show discovered phones,
   and still require the six-digit pairing code and fingerprint before saving
   credentials.
3. **Finder File Provider.** Build the XPC proxy boundary first, then expose a
   deliberately limited Finder surface rather than putting transport logic in
   the sandboxed extension.
4. **Release hardening and Phase 3.** Complete signing/notarisation, bundle
   `adb`, widen MTP and Wi-Fi hardware coverage, then consider photo import,
   watched folders, APK sideloading, and Quick Look.

## Acceptance record

| Criterion | Current position |
| --- | --- |
| USB transfer with checksum verification | Demonstrated on the existing ADB hardware path. |
| MTP with no USB debugging | Implemented as the USB File Transfer fallback; behavior should continue to be checked against varied phones. |
| Wi-Fi without a cloud service | Implemented in source and compiled on both platforms; hardware integration is the next proof point. |
| Phone in Finder sidebar | Not started. |
| Long, mixed-file transfer under sustained load | Existing ADB evidence is useful, but Wi-Fi and longer multi-hour runs still need measurement. |
