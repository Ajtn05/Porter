import Foundation

public enum PhotoImportError: LocalizedError, Hashable, Sendable {
    case sourceChanged(RemotePath)
    case collidingNames

    public var errorDescription: String? {
        switch self {
        case .sourceChanged(let path):
            return "\(path.string) is no longer a photo or video. Scan again before importing."
        case .collidingNames:
            return "Two selected files would use the same Mac path. Select one of them or import them into separate destination folders."
        }
    }
}

public enum PhotoImportMediaKind: Sendable {
    case photo, video

    public static func kind(of file: RemoteFile) -> Self? {
        guard file.kind == .file else { return nil }
        switch file.fileExtension {
        case "jpg", "jpeg", "heic", "heif", "png", "gif", "webp", "avif", "bmp", "tif", "tiff",
             "dng", "raw", "arw", "cr2", "cr3", "nef", "orf", "rw2", "raf", "srw": return .photo
        case "mp4", "mov", "m4v", "3gp", "3g2", "mkv", "avi", "webm", "mts", "m2ts": return .video
        default: return nil
        }
    }
}

public struct PhotoImportScan: Sendable {
    public let root: RemotePath
    public let files: [RemoteFile]
    public var photoCount: Int { files.filter { PhotoImportMediaKind.kind(of: $0) == .photo }.count }
    public var videoCount: Int { files.count - photoCount }
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    public func plan(selectedPaths: Set<RemotePath>, from transport: any DeviceTransport,
                     device: DeviceID, to destination: URL,
                     existingFiles: ConflictResolution = .keepBoth) async throws -> TransferPlan {
        try Task.checkCancellation()
        var selected: [RemoteFile] = []
        for file in files where selectedPaths.contains(file.path) {
            try Task.checkCancellation()
            guard let current = try await transport.stat(file.path) else { throw TransferError.notFound(file.path) }
            guard current.path == file.path, PhotoImportMediaKind.kind(of: current) != nil else {
                throw PhotoImportError.sourceChanged(file.path)
            }
            selected.append(current)
        }
        var plan = try await TransferPlanner().planPull(
            sources: selected, from: transport, device: device, toLocalDirectory: destination,
            conflicts: FixedConflictResolver(existingFiles), includeHidden: false,
            relativeTo: root.parent ?? root
        )
        // Review and final placement are separated by the user's confirmation.
        // Apply the chosen policy even if a destination appears after review.
        var destinations: Set<String> = []
        for index in plan.items.indices {
            let path = plan.items[index].localURL.path.precomposedStringWithCanonicalMapping.lowercased()
            guard destinations.insert(path).inserted else {
                throw PhotoImportError.collidingNames
            }
            plan.items[index].conflictResolution = existingFiles
        }
        return plan
    }
}

public struct PhotoImportScanner: Sendable {
    public init() {}

    public func scan(_ root: RemotePath, using transport: any DeviceTransport,
                     includeVideos: Bool = true) async throws -> PhotoImportScan {
        try Task.checkCancellation()
        guard let folder = try await transport.stat(root) else { throw TransferError.notFound(root) }
        guard folder.isDirectory else { throw TransferError.notADirectory(root) }
        let entries = try await transport.walk(root, includeHidden: false)
        try Task.checkCancellation()
        var seen: Set<RemotePath> = []
        let files = entries.filter { file in
            guard file.path.isDescendant(of: root), !file.path.components.contains(".."),
                  let kind = PhotoImportMediaKind.kind(of: file),
                  includeVideos || kind == .photo else { return false }
            return seen.insert(file.path).inserted
        }.sorted { $0.path.string.localizedStandardCompare($1.path.string) == .orderedAscending }
        return PhotoImportScan(root: root, files: files)
    }
}
