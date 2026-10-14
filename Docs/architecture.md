# Architecture

```
                     SwiftUI app (App/)
                            |
               DeviceCoordinator + TransferEngine
                            |
                     DeviceTransport
                       /          \
                ADBTransport   MTPTransport
                USB debugging  USB File Transfer
```

`Kit/` contains the model, discovery, transports, and transfer engine without a
UI dependency. `DeviceTransport` publishes capabilities so the engine can adapt
resume, verification, and concurrency to the selected USB transport.

## USB discovery

`USBDeviceMonitor` watches IOKit and distinguishes charge-only phones from
phones offering ADB or MTP. `DeviceMerge` combines the USB snapshot and wired
ADB listing into one row per phone. ADB is preferred when it is ready; MTP can
still be used when USB debugging is unauthorized but File Transfer is active.

## Transfer behavior

Every incoming file first uses a `.porterpart` sidecar. ADB can resume a partial
file and compare a device-side SHA-256 hash before reporting verified success.
MTP restarts interrupted copies and reports completed copies as unverified:
Android MTP implementations do not provide dependable ranged writes or a
device-side checksum operation. MTP metadata and free-space reports are best
effort.

`MTPTransport` resolves paths through numbered object handles and caches the
walk. `MTPSession` serializes complete transactions, including the two-part
upload operation, over one USB bulk pipe. Where supported, one property-list
transaction supplies a folder's children and metadata; otherwise it falls back
to a handle list and per-object information requests.

macOS may give the MTP interface to `ptpcamerad`. Porter arms its interface
claimer before discovery and asks the user to reconnect if another process
wins the claim. The app does not seize another process's interface.

## Finder bridge

The read-only File Provider extension cannot spawn `adb` from its sandbox. It
sends metadata and whole-file requests through an App-Group queue to the main
app, which owns the USB transports. Signed runtime behavior still needs
on-device validation.

## Transport decisions

**Transport and interface.** `ADBTransport` is preferred because it can seek
within a file, hash a file in place, report reliable sizes, and set an mtime.
`MTPTransport` is the direct USB fallback for phones without USB debugging.
Both publish `TransportCapabilities`, and the engine reads those rather than
switching on the transport kind.

**Partial files.** In-flight bytes live in a `.porterpart` sidecar. The real
filename only appears once the file is complete. ADB can resume an aligned
partial after a disconnect; MTP deliberately restarts it because ranged reads
and resumable writes are not dependable across Android MTP implementations.

**Verification.** With ADB, the device hashes its own copy and
Porter hashes its copy; a mismatch discards the result. MTP has no device-side
checksum operation, so an MTP transfer can complete but is marked *unverified*.

**Errors.** "This phone is connected but set to
charge only" will show steps to fix it instead of showing "no storage found".

## MTP metadata requests

The storage root also uses one property-list request where supported, with
handle 0 and depth 0, then filters the result by storage and parent. This avoids
per-item metadata round trips without recursively enumerating the phone.
Unsupported or incomplete replies use the ordinary handle/object-info path.
The wire shapes follow [Android's MTP database implementation](https://android.googlesource.com/platform/frameworks/base/+/master/media/java/android/mtp/MtpDatabase.java)
and [native thumbnail API](https://developer.android.com/reference/android/mtp/MtpDevice#getThumbnail(int)).

## Small ADB files

Files at or below 8 MiB can share one `adb pull` and one `sha256sum` call. This
batches downloading and device hashing to avoid two round trips per file.
The implementation has fake-device test coverage; its real-device throughput
still needs measuring. See [recorded measurements](development.md#recorded-adb-measurements).
