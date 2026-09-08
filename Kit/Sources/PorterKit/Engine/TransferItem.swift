import Foundation

public enum TransferDirection: String, Sendable, Codable {
    /// Device to Mac.
    case pull
    /// Mac to device.
    case push
}

public enum TransferState: String, Sendable, Codable {
    case queued
    case running
    /// All bytes moved; checksums are being compared before the file is placed.
    case verifying
    case paused
    case completed
    case failed
    case cancelled
    /// The destination already held this file and Skip was chosen.
    case skipped

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .skipped: return true
        default: return false
        }
    }

    public var isActive: Bool {
        self == .running || self == .verifying
    }
}

/// One file's worth of work.
///
/// Directories are represented by the files inside them, plus a placeholder item
/// per directory so that empty folders are still created at the destination.
public struct TransferItem: Identifiable, Sendable, Codable, Hashable {
    public var id: UUID
    public var batchID: UUID
    public var direction: TransferDirection
    public var deviceID: DeviceID

    public var remotePath: RemotePath
    public var localURL: URL
    /// The path relative to the dragged root, as shown in the transfer drawer:
    /// `DCIM/Camera/IMG_0421.jpg` rather than the full path.
    public var displayPath: String

    public var totalBytes: Int64
    public var bytesTransferred: Int64
    public var state: TransferState
    public var isDirectoryPlaceholder: Bool

    public var sourceModified: Date?
    public var conflictResolution: ConflictResolution?
    /// Set when the name was changed to be legal at the destination.
    public var sanitizationNote: String?
    public var verifiedChecksum: Checksum?
    public var errorMessage: String?
    public var attempts: Int
    public var enqueuedAt: Date
    public var finishedAt: Date?

    public init(
        id: UUID = UUID(),
        batchID: UUID,
        direction: TransferDirection,
        deviceID: DeviceID,
        remotePath: RemotePath,
        localURL: URL,
        displayPath: String,
        totalBytes: Int64,
        bytesTransferred: Int64 = 0,
        state: TransferState = .queued,
        isDirectoryPlaceholder: Bool = false,
        sourceModified: Date? = nil,
        conflictResolution: ConflictResolution? = nil,
        sanitizationNote: String? = nil,
        verifiedChecksum: Checksum? = nil,
        errorMessage: String? = nil,
        attempts: Int = 0,
        enqueuedAt: Date = Date(),
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.batchID = batchID
        self.direction = direction
        self.deviceID = deviceID
        self.remotePath = remotePath
        self.localURL = localURL
        self.displayPath = displayPath
        self.totalBytes = totalBytes
        self.bytesTransferred = bytesTransferred
        self.state = state
        self.isDirectoryPlaceholder = isDirectoryPlaceholder
        self.sourceModified = sourceModified
        self.conflictResolution = conflictResolution
        self.sanitizationNote = sanitizationNote
        self.verifiedChecksum = verifiedChecksum
        self.errorMessage = errorMessage
        self.attempts = attempts
        self.enqueuedAt = enqueuedAt
        self.finishedAt = finishedAt
    }

    public var fractionComplete: Double {
        guard totalBytes > 0 else { return state == .completed ? 1 : 0 }
        return Swift.min(1, Double(bytesTransferred) / Double(totalBytes))
    }

    public var name: String {
        direction == .pull ? remotePath.name : localURL.lastPathComponent
    }

    /// Suffix for the sidecar that holds in-flight bytes.
    ///
    /// A partial copy never occupies the final name. An interrupted transfer
    /// leaves a `.porterpart` file, which the app recognises on relaunch and no
    /// other program will mistake for the finished file.
    public static let partialSuffix = ".porterpart"

    public var localPartialURL: URL {
        localURL.deletingLastPathComponent()
            .appendingPathComponent(localURL.lastPathComponent + Self.partialSuffix)
    }

    public var remotePartialPath: RemotePath {
        guard let parent = remotePath.parent else {
            return RemotePath(remotePath.name + Self.partialSuffix)
        }
        return parent.appending(remotePath.name + Self.partialSuffix)
    }
}

/// Aggregate figures for the drawer and the menu bar.
public struct TransferSummary: Sendable, Hashable {
    public var totalItems: Int
    public var completedItems: Int
    public var failedItems: Int
    public var totalBytes: Int64
    public var transferredBytes: Int64
    public var bytesPerSecond: Double
    public var estimatedTimeRemaining: TimeInterval?
    public var isRunning: Bool
    public var isPaused: Bool

    public init(totalItems: Int = 0, completedItems: Int = 0, failedItems: Int = 0,
                totalBytes: Int64 = 0, transferredBytes: Int64 = 0, bytesPerSecond: Double = 0,
                estimatedTimeRemaining: TimeInterval? = nil, isRunning: Bool = false, isPaused: Bool = false) {
        self.totalItems = totalItems
        self.completedItems = completedItems
        self.failedItems = failedItems
        self.totalBytes = totalBytes
        self.transferredBytes = transferredBytes
        self.bytesPerSecond = bytesPerSecond
        self.estimatedTimeRemaining = estimatedTimeRemaining
        self.isRunning = isRunning
        self.isPaused = isPaused
    }

    public var fractionComplete: Double {
        guard totalBytes > 0 else { return totalItems > 0 ? Double(completedItems) / Double(totalItems) : 0 }
        return Swift.min(1, Double(transferredBytes) / Double(totalBytes))
    }
}
