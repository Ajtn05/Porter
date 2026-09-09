# Architecture

## Shape

```
                         SwiftUI app  (App/)
                                  |
              +-------------------+-------------------+
              |                                       |
       DeviceCoordinator                        TransferEngine
       (discovery and                           (queue, partials,
        transport selection)                     resume, verification)
              |                                       |
              +--------------- DeviceTransport -------+
                                      |
             +------------------------+------------------------+
             |                        |                        |
        ADBTransport              MTPTransport            WiFiTransport
       USB debugging            USB File Transfer        local HTTPS companion
```

Everything below the app is in `Kit/`, a Swift package with no UI dependency.
That lets protocol parsers and transfer failures be tested without requiring a
phone or a cable at exactly the wrong moment.

## Transports are capability-driven

`DeviceTransport` publishes `TransportCapabilities`. The transfer engine uses
those values instead of branching on a transport name, so a new connection path
does not create a second copy loop.

| Transport | Connection | Resume and verification | Important limits |
| --- | --- | --- | --- |
| ADB | USB debugging | Ranged reads, resumable writes, device-side SHA-256, mtime | Requires developer options and USB debugging. |
| MTP | USB File Transfer | A completed copy is size-checked only | One operation at a time; no device checksum; interrupted transfers restart; metadata and capacity reports are best effort. |
| Wi-Fi | Paired Android companion on the LAN | HTTP Range downloads, offset uploads, device-side SHA-256/MD5, mtime | Requires the companion and Android all-files access; automatic Mac-side discovery is not implemented yet. |

All transports use a `.porterpart` sidecar while bytes are in flight. A final
name appears only after the transport's completion criteria are met. ADB and
Wi-Fi can resume; MTP intentionally restarts because Android MTP devices do
not provide dependable ranged transfers.

The word *verified* is deliberately transport-specific. ADB and Wi-Fi compare
the Mac hash with a hash returned by the phone. MTP does not expose a checksum
operation, so its successful transfers are recorded as unverified rather than
claiming a guarantee it cannot make.

## Discovery and selection

`USBDeviceMonitor` watches IOKit for Android devices and distinguishes a phone
in charge-only mode from one offering ADB or MTP. `DeviceMerge` folds USB, ADB,
and paired wireless records into one device list and selects the best usable
transport. ADB wins over MTP when both are present; a paired wireless record
uses its saved host and credentials to construct `WiFiTransport`.

The Android companion advertises `_porter._tcp` with its stable certificate
fingerprint as an identifier. The advertisement is ready for a future Mac
browser; the current pairing UI asks for an address explicitly, which keeps the
first network path small and auditable.

## Wi-Fi pairing and trust

The Wi-Fi path stays on the local network. It has no account service, relay, or
Internet API.

1. The Android companion makes or reuses a self-signed RSA certificate in
   Android Keystore, starts HTTPS on port 53317, and displays a six-digit code
   plus the certificate SHA-256 fingerprint.
2. Porter sends that code to `POST /v1/pair`. The companion rate-limits failed
   attempts and returns a bearer token, device name, and certificate SHA-256
   fingerprint only after a correct code.
3. The Mac accepts the self-signed certificate for this request only, calculates
   the leaf-certificate fingerprint, and rejects the reply unless it matches
   both the fingerprint transcribed from the phone and the returned fingerprint.
4. The Mac stores the bearer token in login Keychain. Its preferences contain
   only the display name, address, port, and pinned fingerprint. All subsequent
   requests use the token and reject a certificate with a different fingerprint.

`WiFiProtocol.swift` defines the v1 JSON and byte-streaming contract. Metadata
operations use JSON; `GET /v1/read` accepts HTTP `Range`; `PUT /v1/write` takes
an explicit offset. The Android server implements information, volumes,
directory operations, stat, reads, writes, checksums, mtime, and free-space
endpoints.

The server canonicalises every requested path and permits it only beneath an
Android shared-storage root. It will not mutate a storage-volume root. This is
defence in depth behind the pairing token: a paired Mac should be able to manage
shared files, not arbitrary application or system paths.

## MTP and macOS ownership

Porter implements the MTP protocol, USB bulk pipe, and serial session layer
directly. A session serialises transactions so a response cannot be consumed by
a different request after a fast UI navigation. MTP uses handles rather than
paths; `MTPTransport` resolves and caches the path-to-handle walk.

macOS frequently gives the MTP interface to `ptpcamerad`. Porter launches an
interface claimer and races for it when a known Android phone attaches. Start
Porter before connecting the phone; if another process won the exclusive
interface, unplug and reconnect it. `porterctl mtp` identifies the current
holder and `porterctl mtp-watch` reports subsequent attach attempts. While
Porter holds an interface, Photos and Image Capture cannot use that phone.

## Storage and preflight

The ADB path accounts for Android user storage being a FUSE presentation layer:
when possible it resolves the backing filesystem so a FAT32 4 GiB limit can be
reported before a transfer begins. MTP cannot reliably provide that filesystem
identity, so it does not guess. Wi-Fi reports free space for the companion's
allowed storage root and uses the server's actual available-byte check before a
write chunk.

## Current boundary

The Mac package test suite validates parsing, transfer planning, capability
handling, MTP protocol/session behavior, and the Wi-Fi client/pairing code. The
Android companion now builds as a debug APK. The next test boundary is a real
phone: install the companion, grant all-files access, pair over a normal LAN,
and exercise certificate rejection, resume, permissions, and a sustained
transfer before advertising Wi-Fi as hardware-validated.

The next architectural phase is the Finder File Provider extension. It cannot
spawn `adb` from its sandbox, so it must proxy transport requests to the main
app through XPC. Putting ADB code directly in the extension is not viable.
