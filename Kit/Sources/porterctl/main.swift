import PorterKit
import Foundation

/// A read-only diagnostic tool for the transport layer.
///
/// Exists because the interesting failures — a ROM whose `stat` output differs,
/// a resume that lands on the wrong offset — are invisible from the UI. This
/// runs the same code the app runs and prints what it saw.
///
/// Nothing here writes to the device.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("porterctl: " + message + "\n").utf8))
    exit(1)
}

func resolveTransport() async throws -> (ADBTransport, Device) {
    guard let adbURL = ADBLocator.locate() else {
        fail("adb not found. Looked in:\n  " + ADBLocator.candidatePaths().map(\.path).prefix(6).joined(separator: "\n  "))
    }
    let listings = try await ADBTransport.listDevices(adbURL: adbURL)
    guard let listing = listings.first(where: { $0.readiness == .ready }) else {
        fail("no ready device. adb reports: \(listings.map { "\($0.serial) \($0.state)" }.joined(separator: ", "))")
    }
    let device = Device(id: DeviceID(listing.serial), displayName: listing.model ?? listing.serial,
                        serial: listing.serial, transport: .adb)
    let transport = ADBTransport(adbURL: adbURL, serial: listing.serial, device: device)
    try await transport.connect()
    return (transport, try await transport.currentDevice())
}

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "help"

switch command {
case "devices":
    guard let adbURL = ADBLocator.locate() else { fail("adb not found") }
    print("adb: \(adbURL.path)")
    let snapshots = USBDeviceMonitor.currentDevices()
    let listings = try await ADBTransport.listDevices(adbURL: adbURL)
    for device in DeviceMerge.merge(usb: snapshots, adb: listings) {
        print("\(device.id)  \(device.displayName)  [\(device.transport.rawValue)]  \(device.readiness)")
        if let usb = device.usb {
            let classes = usb.interfaces.map { "\($0.interfaceClass)/\($0.interfaceSubclass)/\($0.interfaceProtocol)" }
            print("    usb \(String(format: "%04x:%04x", usb.vendorID, usb.productID))  interfaces: \(classes.joined(separator: " "))")
        }
    }

case "volumes":
    let (transport, device) = try await resolveTransport()
    print("\(device.displayName) (Android \(device.androidRelease ?? "?"))")
    for volume in try await transport.volumes() {
        let free = volume.freeBytes.map(ByteFormat.short) ?? "?"
        let total = volume.totalBytes.map(ByteFormat.short) ?? "?"
        print("  \(volume.displayName)  \(volume.rootPath)  \(free) free of \(total)  [\(volume.filesystem.displayName)]")
    }

case "ls":
    guard arguments.count > 1 else { fail("usage: porterctl ls <remote-path>") }
    let (transport, _) = try await resolveTransport()
    let entries = try await transport.list(RemotePath(arguments[1]))
    for entry in entries {
        let marker = entry.isDirectory ? "d" : "-"
        let size = entry.isDirectory ? "" : ByteFormat.short(entry.size)
        let date = entry.modified.map { ISO8601DateFormatter().string(from: $0) } ?? "-"
        print("\(marker) \(size.padded(10)) \(date)  \(entry.name)")
    }
    print("(\(entries.count) entries)")

case "biggest":
    // Finds a large file to exercise the resume path against.
    guard arguments.count > 1 else { fail("usage: porterctl biggest <remote-path>") }
    let (transport, _) = try await resolveTransport()
    let all = try await transport.walk(RemotePath(arguments[1]))
    let files = all.filter { $0.kind == .file }.sorted { $0.size > $1.size }
    for file in files.prefix(8) {
        print("\(ByteFormat.short(file.size).padded(10))  \(file.path)")
    }

case "pull":
    guard arguments.count > 2 else { fail("usage: porterctl pull <remote-path> <local-path>") }
    let (transport, device) = try await resolveTransport()
    let remote = RemotePath(arguments[1])
    let localURL = URL(fileURLWithPath: arguments[2])

    guard let stat = try await transport.stat(remote) else { fail("\(remote) not found") }
    print("pulling \(remote.name)  \(ByteFormat.short(stat.size))")

    let queue = TransferQueue(storeURL: URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("porterctl-queue.json"))
    let engine = TransferEngine(queue: queue, resolver: SingleTransportResolver(transport: transport),
                                maximumConcurrency: 1)
    let item = TransferItem(batchID: UUID(), direction: .pull, deviceID: device.id,
                            remotePath: remote, localURL: localURL, displayPath: remote.name,
                            totalBytes: stat.size, sourceModified: stat.modified)
    let started = Date()
    await engine.enqueue([item])

    while true {
        try await Task.sleep(for: .milliseconds(250))
        guard let current = await queue.item(item.id) else { break }
        if current.state.isTerminal || current.state == .paused {
            let elapsed = Date().timeIntervalSince(started)
            print("state: \(current.state.rawValue)")
            if let error = current.errorMessage { print("error: \(error)") }
            if current.state == .completed {
                let rate = Double(current.totalBytes) / max(elapsed, 0.001)
                print("moved \(ByteFormat.short(current.totalBytes)) in \(ByteFormat.duration(elapsed)) (\(ByteFormat.rate(rate)))")
                print("verified: \(current.verifiedChecksum.map(\.description) ?? "no")")
            }
            break
        }
        let percent = Int(current.fractionComplete * 100)
        FileHandle.standardError.write(Data("\r  \(percent)%  \(ByteFormat.short(current.bytesTransferred))".utf8))
    }
    await queue.flush()

case "resume-test":
    // Proves the acceptance criterion that matters most, against real hardware:
    // interrupt a large copy partway, then continue it rather than restarting.
    guard arguments.count > 2 else { fail("usage: porterctl resume-test <remote-path> <local-path>") }
    let (transport, device) = try await resolveTransport()
    let remote = RemotePath(arguments[1])
    let localURL = URL(fileURLWithPath: arguments[2])
    guard let stat = try await transport.stat(remote) else { fail("\(remote) not found") }

    try? FileManager.default.removeItem(at: localURL)
    try? FileManager.default.removeItem(at: localURL.appendingToName(TransferItem.partialSuffix))

    let queue = TransferQueue(storeURL: URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("porterctl-resume.json"))
    let engine = TransferEngine(queue: queue, resolver: SingleTransportResolver(transport: transport),
                                maximumConcurrency: 1)
    let item = TransferItem(batchID: UUID(), direction: .pull, deviceID: device.id,
                            remotePath: remote, localURL: localURL, displayPath: remote.name,
                            totalBytes: stat.size, sourceModified: stat.modified)
    print("file: \(remote.name)  \(ByteFormat.short(stat.size))")
    await engine.enqueue([item])

    // Interrupt once past a quarter of the way through.
    var interruptedAt: Int64 = 0
    while true {
        try await Task.sleep(for: .milliseconds(40))
        guard let current = await queue.item(item.id) else { break }
        if current.bytesTransferred > stat.size / 4 {
            await engine.pause(item.id)
            interruptedAt = current.bytesTransferred
            break
        }
        if current.state.isTerminal { fail("finished before it could be interrupted; use a larger file") }
    }
    try await Task.sleep(for: .milliseconds(400))

    let partialURL = localURL.appendingToName(TransferItem.partialSuffix)
    let partialSize = (try? FileManager.default.attributesOfItem(atPath: partialURL.path)[.size] as? NSNumber)??.int64Value ?? 0
    print("interrupted at \(ByteFormat.short(interruptedAt))")
    print("  final name exists yet?  \(FileManager.default.fileExists(atPath: localURL.path))  (must be false)")
    print("  partial on disk:        \(ByteFormat.short(partialSize))")

    print("resuming...")
    let resumedAt = Date()
    await engine.resume(item.id)
    while true {
        try await Task.sleep(for: .milliseconds(200))
        guard let current = await queue.item(item.id) else { break }
        if current.state.isTerminal || current.state == .paused {
            print("state: \(current.state.rawValue)")
            if let error = current.errorMessage { print("error: \(error)") }
            if current.state == .completed {
                print("resumed portion took \(ByteFormat.duration(Date().timeIntervalSince(resumedAt)))")
                print("verified: \(current.verifiedChecksum.map(\.description) ?? "no")")
            }
            break
        }
    }
    let leftover = FileManager.default.fileExists(atPath: partialURL.path)
    print("  partial cleaned up?     \(!leftover)  (must be true)")
    await queue.flush()

case "pull-tree":
    // Exercises the whole pipeline the app uses: plan a folder, queue it, copy
    // it, verify every file. `maxBytes` keeps a test run bounded.
    guard arguments.count > 2 else { fail("usage: porterctl pull-tree <remote-dir> <local-dir> [maxBytes]") }
    let (transport, device) = try await resolveTransport()
    let remoteRoot = RemotePath(arguments[1])
    let localRoot = URL(fileURLWithPath: arguments[2])
    let budget = arguments.count > 3 ? (Int64(arguments[3]) ?? .max) : .max
    try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)

    guard let rootStat = try await transport.stat(remoteRoot) else { fail("\(remoteRoot) not found") }
    var plan = try await TransferPlanner().planPull(
        sources: [rootStat], from: transport, device: device.id,
        toLocalDirectory: localRoot, conflicts: FixedConflictResolver(.replace)
    )
    print("planned \(plan.fileCount) files, \(ByteFormat.short(plan.totalBytes))")
    for warning in plan.warnings.prefix(5) { print("  warning: \(warning.message)") }

    if plan.totalBytes > budget {
        var running: Int64 = 0
        plan.items = plan.items.filter { item in
            if item.isDirectoryPlaceholder { return true }
            guard running + item.totalBytes <= budget else { return false }
            running += item.totalBytes
            return true
        }
        print("trimmed to \(plan.fileCount) files, \(ByteFormat.short(plan.totalBytes))")
    }

    let queue = TransferQueue(storeURL: URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("porterctl-tree.json"))
    let engine = TransferEngine(queue: queue, resolver: SingleTransportResolver(transport: transport),
                                maximumConcurrency: 3)
    let started = Date()
    await engine.enqueue(plan.items)

    while true {
        try await Task.sleep(for: .seconds(1))
        let items = await queue.orderedItems
        let busy = items.contains { $0.state == .queued || $0.state.isActive }
        let done = items.filter { $0.state == .completed }.count
        let moved = items.reduce(Int64(0)) { $0 + ($1.state == .completed ? $1.totalBytes : $1.bytesTransferred) }
        FileHandle.standardError.write(Data("\r  \(done)/\(items.count)  \(ByteFormat.short(moved))".utf8))
        if !busy {
            FileHandle.standardError.write(Data("\n".utf8))
            let elapsed = Date().timeIntervalSince(started)
            let files = items.filter { !$0.isDirectoryPlaceholder }
            let verified = files.filter { $0.verifiedChecksum != nil }.count
            let failed = files.filter { $0.state == .failed }
            print("finished in \(ByteFormat.duration(elapsed))  (\(ByteFormat.rate(Double(moved) / max(elapsed, 0.001))))")
            print("files: \(files.count)   completed: \(files.filter { $0.state == .completed }.count)   verified: \(verified)   failed: \(failed.count)")
            for failure in failed.prefix(5) { print("  FAILED \(failure.displayPath): \(failure.errorMessage ?? "?")") }
            break
        }
    }
    await queue.flush()

case "checksum":
    guard arguments.count > 1 else { fail("usage: porterctl checksum <remote-path>") }
    let (transport, _) = try await resolveTransport()
    let checksum = try await transport.checksum(RemotePath(arguments[1]), algorithm: .sha256)
    print(checksum?.description ?? "device has no checksum tool")

default:
    print("""
    porterctl \u{2014} read-only diagnostics for Porter

      devices              List every device, with USB interface classes
      volumes              Storage volumes, free space, and filesystem type
      ls <path>            List a directory on the device
      biggest <path>       Find the largest files under a path
      pull <remote> <local>  Copy one file off the device, verified
      checksum <path>      Ask the device to hash a file
      resume-test <remote> <local>  Interrupt a copy partway, then resume it
      pull-tree <remote-dir> <local-dir> [maxBytes]  Plan and copy a whole folder

    Nothing in this tool writes to the device.
    """)
}

struct SingleTransportResolver: TransportResolver {
    let transport: ADBTransport
    func transport(for deviceID: DeviceID) async throws -> any DeviceTransport { transport }
}

extension URL {
    func appendingToName(_ suffix: String) -> URL {
        deletingLastPathComponent().appendingPathComponent(lastPathComponent + suffix)
    }
}

extension String {
    func padded(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
