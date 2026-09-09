import Foundation

/// Talks to the device through `adb`.
///
/// Preferred whenever USB debugging is enabled: it is the only transport that
/// can seek within a file, hash a file in place, report accurate sizes, and set
/// an mtime.
public actor ADBTransport: DeviceTransport {
    public nonisolated let kind: TransportKind = .adb

    public nonisolated var capabilities: TransportCapabilities {
        TransportCapabilities(
            supportsRangedReads: true,
            supportsResumableWrites: true,
            supportsDeviceSideChecksum: true,
            supportsMtimePreservation: true,
            reportsAccurateSizes: true,
            // adb multiplexes well, but the USB endpoint is the bottleneck.
            // On USB 3 the gain flattens at four concurrent streams.
            maximumConcurrentStreams: 4
        )
    }

    private let adbURL: URL
    private let serial: String
    private var cachedDevice: Device
    private var deviceTimeZone: TimeZone = TimeZone(identifier: "UTC")!
    private var checksumTool: ChecksumAlgorithm?
    private var didProbeChecksumTool = false

    public init(adbURL: URL, serial: String, device: Device) {
        self.adbURL = adbURL
        self.serial = serial
        self.cachedDevice = device
    }

    // MARK: - Command plumbing

    private func adb(_ arguments: [String], timeout: Duration? = .seconds(30),
                     standardInput: URL? = nil) async throws -> ProcessResult {
        try await ProcessRunner.run(
            executable: adbURL,
            arguments: ["-s", serial] + arguments,
            standardInput: standardInput,
            timeout: timeout
        )
    }

    /// Runs a shell command and returns stdout, mapping the common Android
    /// failures onto `TransferError` cases.
    @discardableResult
    private func shell(_ command: String, timeout: Duration? = .seconds(30)) async throws -> String {
        let result = try await adb(["shell", command], timeout: timeout)
        guard result.succeeded else {
            throw mapFailure(command: "adb shell \(command)", result: result)
        }
        let stderr = result.stderrText
        if !stderr.isEmpty {
            try throwIfKnownShellFailure(stderr, command: command)
        }
        return result.stdoutText
    }

    private func throwIfKnownShellFailure(_ stderr: String, command: String) throws {
        let lowered = stderr.lowercased()
        if lowered.contains("permission denied") {
            throw TransferError.permissionDenied(RemotePath(extractPath(from: stderr) ?? command))
        }
        if lowered.contains("no such file or directory") {
            throw TransferError.notFound(RemotePath(extractPath(from: stderr) ?? command))
        }
    }

    private func extractPath(from message: String) -> String? {
        // Shell errors take the form "ls: /sdcard/nope: No such file or directory".
        let parts = message.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.first(where: { $0.hasPrefix("/") })
    }

    private func mapFailure(command: String, result: ProcessResult) -> TransferError {
        let stderr = result.stderrText.lowercased()
        if stderr.contains("device unauthorized") {
            return .deviceNotReady(cachedDevice.id, .unauthorized)
        }
        if stderr.contains("device offline") || stderr.contains("device not found")
            || stderr.contains("no devices/emulators found") {
            return .deviceDisconnected(during: command)
        }
        if stderr.contains("permission denied") {
            return .permissionDenied(RemotePath(extractPath(from: result.stderrText) ?? "/"))
        }
        return .commandFailed(command: command, exitCode: result.exitCode, stderr: result.stderrText)
    }

    // MARK: - Lifecycle

    public func connect() async throws {
        // The server starts implicitly on first use. Starting it here keeps
        // the first real command from paying the daemon-startup latency.
        _ = try? await ProcessRunner.run(executable: adbURL, arguments: ["start-server"], timeout: .seconds(20))

        let listing = try await ADBTransport.listDevices(adbURL: adbURL)
        guard let entry = listing.first(where: { $0.serial == serial }) else {
            throw TransferError.deviceNotFound(cachedDevice.id)
        }
        guard entry.readiness == .ready else {
            throw TransferError.deviceNotReady(cachedDevice.id, entry.readiness)
        }

        // Cache the device's time zone. `touch -t` takes local device time, so
        // an incorrect zone shifts every preserved mtime by hours.
        if let offsetText = try? await shell("date +%z", timeout: .seconds(10)) {
            deviceTimeZone = ADBTransport.timeZone(fromOffset: offsetText) ?? deviceTimeZone
        }

        let properties = (try? await shell("getprop", timeout: .seconds(15))).map(ADBParsing.parseProperties) ?? [:]
        cachedDevice.manufacturer = properties["ro.product.manufacturer"]
        cachedDevice.model = properties["ro.product.model"]
        cachedDevice.androidRelease = properties["ro.build.version.release"]
        cachedDevice.readiness = .ready
        if let model = cachedDevice.model, !model.isEmpty {
            cachedDevice.displayName = model
        }
    }

    public func disconnect() async {
        // Intentionally does not kill the adb server: the daemon is shared with
        // any other process on the Mac using it.
    }

    public func currentDevice() async throws -> Device {
        let listing = try await ADBTransport.listDevices(adbURL: adbURL)
        guard let entry = listing.first(where: { $0.serial == serial }) else {
            cachedDevice.readiness = .offline
            return cachedDevice
        }
        cachedDevice.readiness = entry.readiness
        cachedDevice.lastSeen = Date()
        return cachedDevice
    }

    /// Enumerates every device adb can currently see.
    public static func listDevices(adbURL: URL) async throws -> [ADBParsing.DeviceListing] {
        let result = try await ProcessRunner.run(
            executable: adbURL, arguments: ["devices", "-l"], timeout: .seconds(20)
        )
        guard result.succeeded else {
            throw TransferError.transportUnavailable(.adb, reason: result.stderrText)
        }
        return ADBParsing.parseDeviceList(result.stdoutText)
    }

    static func timeZone(fromOffset text: String) -> TimeZone? {
        // "+0530\n" -> 19800 seconds
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 5, let sign = trimmed.first,
              sign == "+" || sign == "-",
              let hours = Int(trimmed.dropFirst().prefix(2)),
              let minutes = Int(trimmed.suffix(2)) else { return nil }
        let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }

    // MARK: - Browsing

    public func volumes() async throws -> [StorageVolume] {
        var volumes: [StorageVolume] = []

        // Internal storage. /sdcard is a symlink chain ending here; using the
        // real path avoids the loops that break a recursive walk.
        let internalRoot = RemotePath("/storage/emulated/0")
        if try await stat(internalRoot) != nil {
            volumes.append(try await makeVolume(id: "emulated", name: "Internal storage",
                                                root: internalRoot, removable: false))
        }

        // Removable volumes appear as UUID-named directories under /storage.
        if let listing = try? await shell("ls -1 /storage 2>/dev/null") {
            for entry in listing.split(separator: "\n").map({ String($0).trimmingCharacters(in: .whitespaces) }) {
                guard !entry.isEmpty, entry != "self", entry != "emulated" else { continue }
                let root = RemotePath("/storage/\(entry)")
                guard (try? await stat(root)) != nil else { continue }
                let looksLikeCard = entry.range(of: #"^[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$"#,
                                                options: .regularExpression) != nil
                volumes.append(try await makeVolume(
                    id: entry,
                    name: looksLikeCard ? "SD card" : entry,
                    root: root,
                    removable: true
                ))
            }
        }
        // Two cards can both report the name "SD card".
        return volumes.disambiguated()
    }

    private func makeVolume(id: String, name: String, root: RemotePath, removable: Bool) async throws -> StorageVolume {
        let free = try? await freeSpaceRaw(at: root)
        let filesystem = await detectFilesystem(at: root)
        return StorageVolume(
            id: id,
            rawName: name,
            rootPath: root,
            totalBytes: free?.totalBytes,
            freeBytes: free?.availableBytes,
            isRemovable: removable,
            filesystem: filesystem,
            // adb reads the real statfs, so these figures come from the kernel.
            freeSpaceIsTrustworthy: true
        )
    }

    /// Determines what a volume is actually formatted as.
    ///
    /// Android presents user storage through a FUSE layer, so `stat -f` reports
    /// "fuse" whatever lies underneath. When the direct answer is FUSE, fall
    /// back to `mount`, which names the backing filesystem and so determines
    /// whether a file over 4 GiB will fit.
    private func detectFilesystem(at path: RemotePath) async -> StorageVolume.Filesystem {
        var direct = StorageVolume.Filesystem.unknown
        if let type = try? await shell("stat -f -c %T \(path.shellQuoted) 2>/dev/null"), !type.isEmpty {
            direct = ADBParsing.filesystem(fromStatType: type)
        }
        if direct != .unknown, direct != .fuse, direct != .sdcardfs { return direct }

        if let mounts = try? await shell("mount", timeout: .seconds(20)) {
            for candidate in ADBTransport.backingPaths(for: path) {
                let backing = ADBParsing.backingFilesystem(fromMountOutput: mounts, forPath: candidate)
                if backing != .unknown { return backing }
            }
        }
        return direct
    }

    /// Paths to check for the filesystem backing a FUSE-presented volume, most
    /// specific first.
    ///
    /// Android's storage paths are a presentation layer: `/storage/emulated/0`
    /// is the current user's slice of `/data/media`, and a card mounted at
    /// `/storage/1A2B-3C4D` lives at `/mnt/media_rw/1A2B-3C4D`. These two rules
    /// distinguish a FAT32 card, with its 4 GiB per-file limit, from internal
    /// storage on F2FS.
    static func backingPaths(for path: RemotePath) -> [String] {
        let components = path.components
        if components.count >= 3, components[0] == "storage", components[1] == "emulated" {
            return ["/data/media/\(components[2])", "/data/media", "/data"]
        }
        if components.count >= 2, components[0] == "storage", components[1] != "self" {
            return ["/mnt/media_rw/\(components[1])", path.string]
        }
        return [path.string]
    }

    public func list(_ path: RemotePath) async throws -> [RemoteFile] {
        // Primary path: one `stat` per entry in a single round trip, with
        // second-granular mtimes that can be preserved.
        let statCommand = "find \(path.shellQuoted) -maxdepth 1 -mindepth 1 -exec stat -c '%f|%s|%Y|%n' {} + 2>/dev/null"
        if let output = try? await shell(statCommand, timeout: .seconds(60)) {
            let files = ADBParsing.parseStatRecords(output)
            if !files.isEmpty { return files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
            // An empty result is ambiguous: an empty directory, or a ROM with
            // no `find`/`stat`. Confirm with the fallback before accepting it.
        }

        let listing = try await shell("ls -la \(path.shellQuoted)", timeout: .seconds(60))
        return ADBParsing.parseListing(listing, in: path)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func stat(_ path: RemotePath) async throws -> RemoteFile? {
        let output = try? await shell("stat -c '%f|%s|%Y|%n' \(path.shellQuoted) 2>/dev/null", timeout: .seconds(15))
        guard let output, let file = ADBParsing.parseStatRecords(output).first else { return nil }
        return file
    }

    public func createDirectory(_ path: RemotePath) async throws {
        let result = try await adb(["shell", "mkdir -p \(path.shellQuoted)"])
        guard result.succeeded, result.stderrText.isEmpty else {
            throw mapFailure(command: "mkdir -p \(path.string)", result: result)
        }
    }

    public func remove(_ path: RemotePath, recursive: Bool) async throws {
        // No `-f`, so deleting a path that does not exist reports an error
        // rather than succeeding silently.
        let command = recursive ? "rm -r \(path.shellQuoted)" : "rm \(path.shellQuoted)"
        let result = try await adb(["shell", command], timeout: .seconds(120))
        guard result.succeeded, result.stderrText.isEmpty else {
            throw mapFailure(command: command, result: result)
        }
    }

    public func move(from source: RemotePath, to destination: RemotePath) async throws {
        let command = "mv \(source.shellQuoted) \(destination.shellQuoted)"
        let result = try await adb(["shell", command], timeout: .seconds(120))
        guard result.succeeded, result.stderrText.isEmpty else {
            throw mapFailure(command: command, result: result)
        }
    }

    public func freeSpace(for volume: StorageVolume) async throws -> FreeSpaceReport {
        let free = try await freeSpaceRaw(at: volume.rootPath)
        return FreeSpaceReport(
            reportedFreeBytes: free?.availableBytes,
            totalBytes: free?.totalBytes,
            isTrustworthy: true
        )
    }

    private func freeSpaceRaw(at path: RemotePath) async throws -> ADBParsing.DiskFree? {
        let output = try await shell("df -k \(path.shellQuoted)", timeout: .seconds(15))
        return ADBParsing.parseDiskFree(output)
    }

    // MARK: - Bytes

    public func readStream(_ path: RemotePath, range: ByteRange) async throws -> AsyncThrowingStream<Data, any Error> {
        let command: String
        if range.offset == 0 {
            command = "cat \(path.shellQuoted)"
        } else if range.offset % TransferChunk.blockSize == 0 {
            // Block-aligned by construction, so plain `skip=` works on every
            // toybox build and `iflag=skip_bytes` is not needed.
            let blocks = range.offset / TransferChunk.blockSize
            command = "dd if=\(path.shellQuoted) bs=\(TransferChunk.blockSize) skip=\(blocks) 2>/dev/null"
        } else {
            // Unaligned resume. `tail -c +N` is 1-indexed and seeks rather
            // than scans, so it stays cheap on a multi-gigabyte file.
            command = "tail -c +\(range.offset + 1) \(path.shellQuoted)"
        }

        // `exec-out` is the binary-safe channel. `adb shell` translates
        // newlines on older devices, which corrupts every file.
        return ProcessRunner.stream(executable: adbURL, arguments: ["-s", serial, "exec-out", command])
    }

    /// Bulk path for a fresh copy, delegating to `adb pull`.
    ///
    /// Measured at roughly 2.4x the throughput of streaming through `exec-out`.
    /// The destination is the engine's `.porterpart` sidecar and the result is
    /// still checksum-verified, so the engine's guarantees are unchanged.
    ///
    /// adb draws a progress bar only when stdout is a terminal, so progress is
    /// derived from the local file's growing size instead.
    public func fastPull(
        _ path: RemotePath,
        to localURL: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> Bool {
        let pullTask = Task { [adbURL, serial] in
            try await ProcessRunner.run(
                executable: adbURL,
                arguments: ["-s", serial, "pull", path.string, localURL.path],
                timeout: nil
            )
        }

        let poller = Task {
            var lastReported: Int64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: localURL.path),
                      let size = (attributes[.size] as? NSNumber)?.int64Value else { continue }
                if size > lastReported {
                    progress(size - lastReported)
                    lastReported = size
                }
            }
        }
        defer { poller.cancel() }

        // Awaiting an unstructured task's `value` is not itself cancellable.
        // Without this handler, a pause would block here until `adb pull`
        // finished the whole file; forwarding the cancellation terminates adb.
        let result = try await withTaskCancellationHandler {
            try await pullTask.value
        } onCancel: {
            pullTask.cancel()
        }
        try Task.checkCancellation()

        guard result.succeeded else {
            throw mapFailure(command: "adb pull \(path.string)", result: result)
        }
        let combined = result.stdoutText + result.stderrText
        if combined.contains("adb: error:") {
            throw TransferError.commandFailed(command: "adb pull", exitCode: 0, stderr: combined)
        }
        return true
    }

    /// Copies many files with one `adb pull` rather than one each.
    ///
    /// `adb pull` takes a list of remote paths and a local directory, so the
    /// whole batch costs the one process and the one device round trip that a
    /// single file used to. The files land under their own names in a staging
    /// directory and are then renamed onto the sidecars the caller asked for.
    ///
    /// The staging directory is made inside the destination directory rather
    /// than in the system temporary one, so the rename out of it is a rename
    /// and not a copy onto another volume.
    public func bulkPull(_ requests: [BulkPullRequest],
                         progress: @escaping @Sendable (Int64) -> Void) async throws -> Set<RemotePath> {
        var delivered: Set<RemotePath> = []
        // Grouped by where the bytes are going, because one `adb pull` writes
        // into one directory.
        let byDestination = Dictionary(grouping: requests) { $0.localURL.deletingLastPathComponent().path }

        for group in byDestination.values {
            for batch in Self.pullBatches(group) {
                try Task.checkCancellation()
                delivered.formUnion(try await pullBatch(batch, progress: progress))
            }
        }
        return delivered
    }

    private func pullBatch(_ batch: [BulkPullRequest],
                           progress: @escaping @Sendable (Int64) -> Void) async throws -> Set<RemotePath> {
        guard let destination = batch.first?.localURL.deletingLastPathComponent() else { return [] }

        let fileManager = FileManager.default
        let staging = destination.appendingPathComponent(".porter-batch-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let pullTask = Task { [adbURL, serial] in
            try await ProcessRunner.run(
                executable: adbURL,
                arguments: ["-s", serial, "pull"] + batch.map(\.path.string) + [staging.path],
                timeout: nil
            )
        }
        // As in `fastPull`: awaiting an unstructured task is not itself
        // cancellable, and without this a pause would wait out the whole batch.
        let result = try await withTaskCancellationHandler {
            try await pullTask.value
        } onCancel: {
            pullTask.cancel()
        }
        try Task.checkCancellation()

        // A non-zero exit is not fatal to the batch. adb reports a file it
        // could not read and carries on with the rest, so what actually landed
        // in the staging directory decides; the rest are reported as not
        // delivered and the caller copies them singly.
        _ = result

        var delivered: Set<RemotePath> = []
        for request in batch {
            let staged = staging.appendingPathComponent(request.path.name)
            guard let size = (try? fileManager.attributesOfItem(atPath: staged.path))?[.size] as? NSNumber
            else { continue }

            try? fileManager.removeItem(at: request.localURL)
            do {
                try fileManager.moveItem(at: staged, to: request.localURL)
            } catch {
                continue
            }
            delivered.insert(request.path)
            progress(size.int64Value)
        }
        return delivered
    }

    /// Splits a batch into `adb pull` command lines, on the same argument
    /// budget the hashing batches use.
    ///
    /// Two files with the same name cannot share a batch: `adb pull` writes
    /// both under that name in the staging directory, so the second would
    /// overwrite the first. The repeat goes into a later batch instead.
    static func pullBatches(_ requests: [BulkPullRequest]) -> [[BulkPullRequest]] {
        let byteLimit = 8 * 1024
        let countLimit = 64

        var batches: [[BulkPullRequest]] = []
        var current: [BulkPullRequest] = []
        var names: Set<String> = []
        var length = 0

        for request in requests {
            let cost = request.path.string.utf8.count + 1
            let collides = names.contains(request.path.name)
            if !current.isEmpty && (collides || current.count >= countLimit || length + cost > byteLimit) {
                batches.append(current)
                current = []
                names = []
                length = 0
            }
            current.append(request)
            names.insert(request.path.name)
            length += cost
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    public func writeFile(
        from localURL: URL,
        to path: RemotePath,
        destinationOffset: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        if let parent = path.parent { try await createDirectory(parent) }

        if destinationOffset == 0 {
            try await push(localURL: localURL, to: path, progress: progress)
        } else {
            try await appendRemainder(of: localURL, to: path, from: destinationOffset, progress: progress)
        }
    }

    /// Bulk path for a fresh copy, delegating to `adb push`.
    ///
    /// adb prints progress only when stdout is a terminal, so the destination's
    /// size is polled instead: one cheap shell round trip per tick, for a real
    /// byte count.
    private func push(localURL: URL, to path: RemotePath, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let pushTask = Task { [adbURL, serial] in
            try await ProcessRunner.run(
                executable: adbURL,
                arguments: ["-s", serial, "push", localURL.path, path.string],
                timeout: nil
            )
        }

        let poller = Task { [weak self] in
            var lastReported: Int64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, !Task.isCancelled else { return }
                guard let size = try? await self.remoteSize(of: path) else { continue }
                if size > lastReported {
                    progress(size - lastReported)
                    lastReported = size
                }
            }
        }
        defer { poller.cancel() }

        let result = try await withTaskCancellationHandler {
            try await pushTask.value
        } onCancel: {
            pushTask.cancel()
        }
        try Task.checkCancellation()

        guard result.succeeded else {
            throw mapFailure(command: "adb push \(localURL.lastPathComponent)", result: result)
        }
        // adb reports some failures on stdout with exit code 0.
        let combined = result.stdoutText + result.stderrText
        if combined.lowercased().contains("no space left") {
            throw TransferError.insufficientSpace(needed: 0, available: 0, volume: path.parent?.string ?? "/")
        }
        if combined.contains("adb: error:") {
            throw TransferError.commandFailed(command: "adb push", exitCode: 0, stderr: combined)
        }
    }

    /// Resume path: streams only the missing bytes into `cat >>`.
    ///
    /// The local file is opened and seeked, so nothing is staged to a temporary
    /// copy on either side. `adb shell` stdin is not guaranteed byte-clean on
    /// older ROMs, but the engine's device-side checksum catches a mangled
    /// append and restarts the item from zero.
    private func appendRemainder(of localURL: URL, to path: RemotePath, from offset: Int64,
                                 progress: @escaping @Sendable (Int64) -> Void) async throws {
        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))

        let process = Process()
        process.executableURL = adbURL
        process.arguments = ["-s", serial, "shell", "cat >> \(path.shellQuoted)"]
        let inputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        try process.run()

        do {
            while true {
                try Task.checkCancellation()
                guard let chunk = try handle.read(upToCount: Int(TransferChunk.blockSize)), !chunk.isEmpty else { break }
                try inputPipe.fileHandleForWriting.write(contentsOf: chunk)
                progress(Int64(chunk.count))
            }
            try inputPipe.fileHandleForWriting.close()
        } catch {
            try? inputPipe.fileHandleForWriting.close()
            process.terminate()
            throw error
        }

        process.waitUntilExit()
        let stderr = String(decoding: (try? errorPipe.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw TransferError.commandFailed(command: "adb shell cat >> \(path.string)",
                                              exitCode: process.terminationStatus, stderr: stderr)
        }
    }

    func remoteSize(of path: RemotePath) async throws -> Int64 {
        let output = try await shell("stat -c %s \(path.shellQuoted) 2>/dev/null", timeout: .seconds(10))
        return Int64(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    public func checksum(_ path: RemotePath, algorithm: ChecksumAlgorithm) async throws -> Checksum? {
        guard let effective = try await effectiveChecksumTool(preferring: algorithm) else { return nil }
        // Hashing a large file on a phone is slow, so no timeout. Cancellation
        // still applies.
        let output = try await shell("\(effective.deviceCommand) \(path.shellQuoted)", timeout: nil)
        return ChecksumService.parseSumOutput(output, algorithm: effective)
    }

    /// Hashes a list of files with one `sha256sum` per batch rather than one
    /// per file.
    ///
    /// What this saves is the round trip and the shell Android spawns for it,
    /// which is the entire cost for anything small. The hashing is the same
    /// work either way, so the gain is proportional to how many files are in
    /// the batch and disappears once each file is large enough to dominate.
    public func checksums(_ paths: [RemotePath], algorithm: ChecksumAlgorithm) async throws -> [RemotePath: Checksum] {
        guard let effective = try await effectiveChecksumTool(preferring: algorithm) else { return [:] }

        var result: [RemotePath: Checksum] = [:]

        // A name holding a newline is indistinguishable from the break between
        // two results, so it is hashed on its own where the path is known from
        // having asked for exactly one.
        for path in paths where path.string.contains("\n") {
            try Task.checkCancellation()
            if let checksum = try await checksum(path, algorithm: algorithm) { result[path] = checksum }
        }

        for batch in Self.checksumBatches(paths.filter { !$0.string.contains("\n") }) {
            try Task.checkCancellation()
            let command = ([effective.deviceCommand] + batch.map(\.shellQuoted)).joined(separator: " ")
            // Deliberately not `shell`, which throws on a non-zero exit:
            // sha256sum exits non-zero when any one path is unreadable, and the
            // hashes of the others are on stdout and still wanted. A path that
            // produced no line is simply absent from the result.
            let output = try await adb(["shell", command], timeout: nil)
            let parsed = ChecksumService.parseSumLines(output.stdoutText, algorithm: effective)
            for path in batch where parsed[path.string] != nil {
                result[path] = parsed[path.string]
            }
        }
        return result
    }

    /// Splits paths into command lines Android's shell will accept.
    ///
    /// `adb shell` sends the command as one string and the ROM rejects an
    /// over-long one rather than splitting it. Both bounds sit far below any
    /// limit measured; the round trip is saved per batch, so raising them
    /// buys very little.
    static func checksumBatches(_ paths: [RemotePath]) -> [[RemotePath]] {
        let byteLimit = 8 * 1024
        let countLimit = 64

        var batches: [[RemotePath]] = []
        var current: [RemotePath] = []
        var length = 0

        for path in paths {
            let cost = path.shellQuoted.utf8.count + 1
            if !current.isEmpty && (current.count >= countLimit || length + cost > byteLimit) {
                batches.append(current)
                current = []
                length = 0
            }
            current.append(path)
            length += cost
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    /// The algorithm to hash with: the requested one where the device has it,
    /// and whatever it does have otherwise. Nil when it has neither.
    private func effectiveChecksumTool(preferring algorithm: ChecksumAlgorithm) async throws -> ChecksumAlgorithm? {
        if !didProbeChecksumTool {
            // Only a definitive answer is cached. Recording an interrupted
            // probe as "no hashing tool" would disable verification for the
            // rest of the session.
            checksumTool = try await probeChecksumTool()
            didProbeChecksumTool = true
        }
        guard let tool = checksumTool else { return nil }
        return (tool == algorithm) ? algorithm : tool
    }

    /// Finds a hashing tool on the device.
    ///
    /// Rethrows cancellation so the caller can distinguish a ROM with no
    /// `sha256sum` from a probe that was interrupted.
    private func probeChecksumTool() async throws -> ChecksumAlgorithm? {
        for algorithm in [ChecksumAlgorithm.sha256, .md5] {
            do {
                let output = try await shell("command -v \(algorithm.deviceCommand)", timeout: .seconds(10))
                if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return algorithm
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        return nil
    }

    public func truncate(_ path: RemotePath, to length: Int64) async throws {
        let result = try await adb(["shell", "truncate -s \(length) \(path.shellQuoted)"], timeout: .seconds(30))
        guard result.succeeded, result.stderrText.isEmpty else {
            // Some minimal ROMs ship a toybox without `truncate`. Report it as
            // unsupported so the engine falls back to restarting the file.
            throw TransferError.unsupported(operation: "Trimming a partial file", transport: .adb)
        }
        let landed = try await remoteSize(of: path)
        guard landed == length else {
            throw TransferError.protocolError("truncate left \(landed) bytes, expected \(length)")
        }
    }

    public func setModificationDate(_ date: Date, at path: RemotePath) async throws {
        // POSIX `touch -t [[CC]YY]MMDDhhmm[.ss]`, in the device's local time.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = deviceTimeZone
        formatter.dateFormat = "yyyyMMddHHmm.ss"
        let stamp = formatter.string(from: date)
        _ = try? await shell("touch -m -t \(stamp) \(path.shellQuoted)", timeout: .seconds(15))
    }
}
