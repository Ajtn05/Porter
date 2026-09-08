import Foundation

/// Asked, once per collision, what to do. Implemented by the UI; the planner
/// handles "apply to all" so every call site does not have to.
public protocol ConflictResolving: Sendable {
    func resolve(_ context: ConflictContext) async -> ConflictDecision
}

/// Always answers the same way. Used by tests, by the File Provider extension
/// (which has no UI to ask with), and by watched-folder sync.
public struct FixedConflictResolver: ConflictResolving {
    public let decision: ConflictDecision
    public init(_ resolution: ConflictResolution) {
        self.decision = ConflictDecision(resolution: resolution, applyToAll: true)
    }
    public func resolve(_ context: ConflictContext) async -> ConflictDecision { decision }
}

public enum PlanWarning: Hashable, Sendable {
    case insufficientSpace(needed: Int64, available: Int64, volume: String, wasVerified: Bool)
    case freeSpaceUnverifiable(volume: String, reported: Int64?)
    case fileTooLargeForFilesystem(name: String, size: Int64, limit: Int64, filesystem: String)
    case renamed(FilenameSanitizer.Change)
    case skippedUnreadable(path: String, reason: String)

    public var isBlocking: Bool {
        switch self {
        case .insufficientSpace, .fileTooLargeForFilesystem: return true
        default: return false
        }
    }

    public var message: String {
        switch self {
        case .insufficientSpace(let needed, let available, let volume, let wasVerified):
            let qualifier = wasVerified ? "" : " (as reported by the device)"
            return "\(ByteFormat.short(needed)) will not fit in the \(ByteFormat.short(available)) free on \(volume)\(qualifier)."
        case .freeSpaceUnverifiable(let volume, let reported):
            let reportedText = reported.map { " It claims \(ByteFormat.short($0)) free." } ?? ""
            return "\(volume) does not report free space reliably.\(reportedText)"
        case .fileTooLargeForFilesystem(let name, let size, let limit, let filesystem):
            return "\u{201C}\(name)\u{201D} is \(ByteFormat.short(size)), over the \(ByteFormat.short(limit)) limit for \(filesystem)."
        case .renamed(let change):
            return "\u{201C}\(change.original)\u{201D} was saved as \u{201C}\(change.sanitized)\u{201D} \u{2014} \(change.reason)."
        case .skippedUnreadable(let path, let reason):
            return "Skipped \(path): \(reason)"
        }
    }
}

public struct TransferPlan: Sendable {
    public var batchID: UUID
    public var items: [TransferItem]
    public var warnings: [PlanWarning]

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.totalBytes } }
    public var fileCount: Int { items.filter { !$0.isDirectoryPlaceholder }.count }
    public var isBlocked: Bool { warnings.contains(where: \.isBlocking) }

    public init(batchID: UUID = UUID(), items: [TransferItem] = [], warnings: [PlanWarning] = []) {
        self.batchID = batchID
        self.items = items
        self.warnings = warnings
    }
}

/// Turns a drag-and-drop into a checked, ordered list of files to move.
///
/// Everything that can go wrong before a single byte moves is decided here: not
/// enough room, a file too big for the card's filesystem, a name that is legal
/// on one side and not the other, a collision the user has to rule on. Finding
/// these up front is what stops a 20 GB copy from dying at 90%.
public struct TransferPlanner: Sendable {
    // FileManager is not marked Sendable, but the read-only enumeration and
    // attribute lookups used here are documented as thread-safe on the shared
    // instance, and the planner never mutates it.
    nonisolated(unsafe) private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - Device to Mac

    public func planPull(
        sources: [RemoteFile],
        from transport: any DeviceTransport,
        device: DeviceID,
        toLocalDirectory destination: URL,
        conflicts resolver: any ConflictResolving,
        includeHidden: Bool = true
    ) async throws -> TransferPlan {
        var plan = TransferPlan()
        let sanitizer = FilenameSanitizer(destination: .macOS)
        var blanketDecision: ConflictResolution?

        for source in sources {
            try Task.checkCancellation()
            guard let parent = source.path.parent else { continue }

            var entries: [RemoteFile] = [source]
            if source.kind == .directory {
                entries.append(contentsOf: try await transport.walk(source.path, includeHidden: includeHidden))
            }

            for entry in entries {
                guard entry.kind != .symlink, entry.kind != .other else {
                    plan.warnings.append(.skippedUnreadable(
                        path: entry.path.string,
                        reason: entry.kind == .symlink ? "it is a link, not a file" : "it is not a regular file"
                    ))
                    continue
                }
                guard includeHidden || !entry.isHidden else { continue }

                let relative = entry.path.relative(to: parent) ?? RemotePath(entry.name)
                let (safeComponents, changes) = sanitizer.sanitize(components: relative.components)
                plan.warnings.append(contentsOf: changes.map { PlanWarning.renamed($0) })

                var localURL = destination
                for component in safeComponents { localURL.appendPathComponent(component) }

                var resolution: ConflictResolution?
                if entry.kind != .directory, fileManager.fileExists(atPath: localURL.path) {
                    let decision = try await decide(
                        blanket: &blanketDecision,
                        resolver: resolver,
                        context: localConflictContext(localURL: localURL, source: entry)
                    )
                    if decision == .skip { continue }
                    if decision == .replaceIfNewer,
                       let localDate = modificationDate(of: localURL),
                       let remoteDate = entry.modified,
                       remoteDate <= localDate.addingTimeInterval(1) { continue }
                    resolution = decision
                }

                plan.items.append(TransferItem(
                    batchID: plan.batchID,
                    direction: .pull,
                    deviceID: device,
                    remotePath: entry.path,
                    localURL: localURL,
                    displayPath: safeComponents.joined(separator: "/"),
                    totalBytes: entry.kind == .directory ? 0 : entry.size,
                    isDirectoryPlaceholder: entry.kind == .directory,
                    sourceModified: entry.modified,
                    conflictResolution: resolution
                ))
            }
        }

        // Enough room on the Mac?
        let needed = plan.totalBytes
        if let available = localFreeSpace(at: destination), needed > available {
            plan.warnings.append(.insufficientSpace(
                needed: needed, available: available,
                volume: destination.path, wasVerified: true
            ))
        }
        return orderedDirectoriesFirst(plan)
    }

    // MARK: - Mac to device

    public func planPush(
        sources: [URL],
        to destination: RemotePath,
        on transport: any DeviceTransport,
        device: DeviceID,
        volume: StorageVolume?,
        conflicts resolver: any ConflictResolving,
        includeHidden: Bool = true
    ) async throws -> TransferPlan {
        var plan = TransferPlan()
        let sanitizer = FilenameSanitizer(
            destination: (volume?.filesystem == .fat32 || volume?.filesystem == .exfat) ? .androidFAT : .androidPOSIX
        )
        var blanketDecision: ConflictResolution?
        let sizeLimit = volume?.filesystem.maximumFileSize

        for source in sources {
            try Task.checkCancellation()
            let root = source.deletingLastPathComponent()
            for local in try localEntries(under: source, includeHidden: includeHidden) {
                let relativeComponents = relativeComponents(of: local.url, under: root)
                let (safeComponents, changes) = sanitizer.sanitize(components: relativeComponents)
                plan.warnings.append(contentsOf: changes.map { PlanWarning.renamed($0) })

                var remotePath = destination
                for component in safeComponents { remotePath = remotePath.appending(component) }

                if !local.isDirectory, let limit = sizeLimit, local.size > limit {
                    // FAT32 physically cannot hold this. Blocking, not a warning
                    // to click past: the copy would fail partway regardless.
                    plan.warnings.append(.fileTooLargeForFilesystem(
                        name: local.url.lastPathComponent, size: local.size,
                        limit: limit, filesystem: volume?.filesystem.displayName ?? "this volume"
                    ))
                    continue
                }

                var resolution: ConflictResolution?
                if !local.isDirectory, let existing = try? await transport.stat(remotePath), existing.kind == .file {
                    let decision = try await decide(
                        blanket: &blanketDecision,
                        resolver: resolver,
                        context: ConflictContext(
                            name: remotePath.name,
                            destinationPath: remotePath.string,
                            sourceSize: local.size,
                            destinationSize: existing.size,
                            sourceModified: local.modified,
                            destinationModified: existing.modified
                        )
                    )
                    if decision == .skip { continue }
                    if decision == .replaceIfNewer, let remoteDate = existing.modified,
                       let localDate = local.modified, localDate <= remoteDate.addingTimeInterval(1) { continue }
                    if decision == .keepBoth {
                        let siblings = Set(((try? await transport.list(remotePath.parent ?? destination)) ?? []).map(\.name))
                        let unique = ConflictNaming.uniqueName(for: remotePath.name, existing: siblings)
                        remotePath = (remotePath.parent ?? destination).appending(unique)
                    }
                    resolution = decision
                }

                plan.items.append(TransferItem(
                    batchID: plan.batchID,
                    direction: .push,
                    deviceID: device,
                    remotePath: remotePath,
                    localURL: local.url,
                    displayPath: safeComponents.joined(separator: "/"),
                    totalBytes: local.isDirectory ? 0 : local.size,
                    isDirectoryPlaceholder: local.isDirectory,
                    sourceModified: local.modified,
                    conflictResolution: resolution
                ))
            }
        }

        if let volume {
            let report = (try? await transport.freeSpace(for: volume))
                ?? FreeSpaceReport(reportedFreeBytes: volume.freeBytes, totalBytes: volume.totalBytes,
                                   isTrustworthy: volume.freeSpaceIsTrustworthy)
            let needed = plan.totalBytes
            if let available = report.bestEstimate {
                if needed > available {
                    plan.warnings.append(.insufficientSpace(
                        needed: needed, available: available,
                        volume: volume.displayName, wasVerified: report.verifiedFreeBytes != nil
                    ))
                } else if !report.isTrustworthy, needed > available / 2 {
                    // MTP devices routinely report stale free space. When the
                    // copy is large relative to what they claim, say so rather
                    // than discovering it at 90%.
                    plan.warnings.append(.freeSpaceUnverifiable(
                        volume: volume.displayName, reported: report.reportedFreeBytes
                    ))
                }
            } else {
                plan.warnings.append(.freeSpaceUnverifiable(volume: volume.displayName, reported: nil))
            }
        }
        return orderedDirectoriesFirst(plan)
    }

    // MARK: - Helpers

    private func decide(
        blanket: inout ConflictResolution?,
        resolver: any ConflictResolving,
        context: ConflictContext
    ) async throws -> ConflictResolution {
        if let blanket { return blanket }
        let decision = await resolver.resolve(context)
        if decision.applyToAll { blanket = decision.resolution }
        return decision.resolution
    }

    /// Directories before the files inside them, so a placeholder never races
    /// the first file that needs it to exist.
    private func orderedDirectoriesFirst(_ plan: TransferPlan) -> TransferPlan {
        var plan = plan
        plan.items.sort { lhs, rhs in
            if lhs.isDirectoryPlaceholder != rhs.isDirectoryPlaceholder {
                return lhs.isDirectoryPlaceholder
            }
            return lhs.displayPath.localizedStandardCompare(rhs.displayPath) == .orderedAscending
        }
        return plan
    }

    private struct LocalEntry {
        var url: URL
        var size: Int64
        var modified: Date?
        var isDirectory: Bool
    }

    private func localEntries(under root: URL, includeHidden: Bool) throws -> [LocalEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        let values = try root.resourceValues(forKeys: Set(keys))

        if values.isDirectory != true {
            return [LocalEntry(url: root, size: Int64(values.fileSize ?? 0),
                               modified: values.contentModificationDate, isDirectory: false)]
        }

        var results = [LocalEntry(url: root, size: 0, modified: values.contentModificationDate, isDirectory: true)]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !includeHidden { options.insert(.skipsHiddenFiles) }

        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: keys, options: options) else {
            return results
        }
        for case let url as URL in enumerator {
            let entryValues = try url.resourceValues(forKeys: Set(keys))
            results.append(LocalEntry(
                url: url,
                size: Int64(entryValues.fileSize ?? 0),
                modified: entryValues.contentModificationDate,
                isDirectory: entryValues.isDirectory ?? false
            ))
        }
        return results
    }

    private func relativeComponents(of url: URL, under root: URL) -> [String] {
        let rootComponents = root.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        guard urlComponents.count > rootComponents.count,
              Array(urlComponents.prefix(rootComponents.count)) == rootComponents else {
            return [url.lastPathComponent]
        }
        return Array(urlComponents.dropFirst(rootComponents.count))
    }

    private func localConflictContext(localURL: URL, source: RemoteFile) -> ConflictContext {
        let values = try? localURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return ConflictContext(
            name: localURL.lastPathComponent,
            destinationPath: localURL.path,
            sourceSize: source.size,
            destinationSize: Int64(values?.fileSize ?? 0),
            sourceModified: source.modified,
            destinationModified: values?.contentModificationDate
        )
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func localFreeSpace(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
