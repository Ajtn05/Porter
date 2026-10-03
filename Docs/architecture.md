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
