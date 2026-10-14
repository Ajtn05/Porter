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

## Photo import

`PhotoImportScanner` enumerates metadata under the chosen storage folder and
filters regular files by photo and video extensions. `PhotoImportSession`
captures the source phone and folder, tracks selection and destination changes,
and discards obsolete scan and review results. Review re-stats selected sources
and uses `TransferPlanner` with a shared relative-path root to preserve albums.
Confirmed imports enter the ordinary transfer queue. Existing-file policy is
retained through final placement, including when a file appears after review.

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

**Partial files.** In-flight bytes live in a `.porter-<item UUID>.porterpart`
sidecar beside the destination. Persisted item IDs isolate queued transfers
and retain the same temporary name on retry. Final destinations are serialized
by the engine, and bulk-read claims use the local sidecar rather than a remote
path shared by several phones. The real filename only appears once the file
is complete. ADB can resume an aligned
partial after a disconnect; MTP deliberately restarts it because ranged reads
and resumable writes are not dependable across Android MTP implementations.

**Placement.** The planner blocks source names that converge after sanitization,
case folding, or flattening; overlapping selections are deduplicated. File and
folder type conflicts also block. Destination metadata failures propagate.
The engine rechecks conflict choices when placing verified bytes. Unplanned
destinations fail safely, Skip reports a skipped item, and Replace if Newer
requires a newer source date. Local Replace uses a same-directory atomic rename
instead of deleting first. Phone Replace renames the original to a unique
`.porterbackup`, places the copy, then removes the backup. A placement failure
attempts rollback even after cancellation. If rollback or backup removal fails,
the drawer reports the retained backup path. Only placement is serialized on a
phone; byte copying retains its supported concurrency. Remote placement cannot
guarantee atomicity against changes made by other apps or a device disconnect.

**Browser errors and prompts.** Mac navigation commits its path and history
only after enumeration succeeds. Failed refresh preserves the last good view;
the inline Retry action retains the failed destination and navigation mode.
Interactive conflict requests queue while the current sheet is presented;
dismissing a sheet resumes its planner with Skip rather than leaving it parked.
Copy options, storage metadata, and new-folder destinations are captured before
resolving a transport.

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
