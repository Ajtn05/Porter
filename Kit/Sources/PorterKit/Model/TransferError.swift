import Foundation

/// Errors surfaced to the user.
///
/// Each case carries enough context for the presenter to name the specific
/// blocker and, where one exists, the step that clears it.
public enum TransferError: Error, Hashable, Sendable {
    case deviceNotFound(DeviceID)
    case deviceNotReady(DeviceID, DeviceReadiness)
    case transportUnavailable(TransportKind, reason: String)
    case toolMissing(name: String, hint: String)
    case notADirectory(RemotePath)
    case notFound(RemotePath)
    case permissionDenied(RemotePath)
    case alreadyExists(RemotePath)
    case deviceDisconnected(during: String)
    case deviceStalled(reason: String)
    case insufficientSpace(needed: Int64, available: Int64, volume: String)
    case fileTooLargeForFilesystem(size: Int64, limit: Int64, filesystem: String)
    case checksumMismatch(path: String, expected: String, actual: String)
    case truncated(path: String, expected: Int64, actual: Int64)
    case cancelled
    case commandFailed(command: String, exitCode: Int32, stderr: String)
    case protocolError(String)
    case pairingFailed(String)
    case unsupported(operation: String, transport: TransportKind)
}

extension TransferError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .deviceNotFound(let id):
            return "The device \(id.rawValue) is no longer connected."
        case .deviceNotReady(_, let readiness):
            switch readiness {
            case .chargingOnly:
                return "This phone is connected but set to charge only, so it is not sharing any files."
            case .unauthorized:
                return "This phone has not yet trusted this Mac for USB debugging."
            case .locked:
                return "This phone is locked, so it stopped responding mid-request."
            case .offline:
                return "This device is not reachable right now."
            case .ready:
                return "This device reported a problem even though it looks ready."
            }
        case .transportUnavailable(let kind, let reason):
            return "\(kind.displayName) is unavailable: \(reason)"
        case .toolMissing(let name, let hint):
            return "\(name) is missing. \(hint)"
        case .notADirectory(let path):
            return "\(path.string) is not a folder."
        case .notFound(let path):
            return "\(path.string) does not exist on the device."
        case .permissionDenied(let path):
            return "Android would not let this Mac read \(path.string)."
        case .alreadyExists(let path):
            return "\(path.string) already exists."
        case .deviceDisconnected(let during):
            return "The device disconnected during \(during)."
        case .deviceStalled(let reason):
            return "The device stopped responding: \(reason)"
        case .insufficientSpace(let needed, let available, let volume):
            return "\(ByteFormat.short(needed)) will not fit in the \(ByteFormat.short(available)) free on \(volume)."
        case .fileTooLargeForFilesystem(let size, let limit, let filesystem):
            return "\(ByteFormat.short(size)) is larger than the \(ByteFormat.short(limit)) maximum file size on \(filesystem)."
        case .checksumMismatch(let path, _, _):
            return "\(path) did not match its checksum after copying, so the copy was discarded."
        case .truncated(let path, let expected, let actual):
            return "\(path) stopped at \(ByteFormat.short(actual)) of \(ByteFormat.short(expected))."
        case .cancelled:
            return "Cancelled."
        case .commandFailed(let command, let code, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "`\(command)` failed with code \(code)\(detail.isEmpty ? "" : ": \(detail)")"
        case .protocolError(let message):
            return "The device sent something unexpected: \(message)"
        case .pairingFailed(let message):
            return "Pairing failed: \(message)"
        case .unsupported(let operation, let transport):
            return "\(operation) is not supported over \(transport.displayName)."
        }
    }

    /// A concrete next step, shown beneath the message. Nil when the message
    /// itself is all there is to say.
    public var recoverySuggestion: String? {
        switch self {
        case .deviceNotReady(_, .chargingOnly):
            return "On the phone, pull down the notification shade, tap the USB notification, and choose File Transfer."
        case .deviceNotReady(_, .unauthorized):
            return "Unlock the phone and tap Allow on the \u{201C}Allow USB debugging?\u{201D} prompt."
        case .deviceNotReady(_, .locked), .deviceStalled:
            return "Unlock the phone and keep the screen on, then retry."
        case .toolMissing(_, let hint):
            return hint
        case .insufficientSpace:
            return "Free up space on the device or copy fewer files."
        case .fileTooLargeForFilesystem:
            return "Copy this file to internal storage instead, or reformat the card as exFAT."
        case .deviceDisconnected:
            return "Reconnect the cable. The transfer will pick up where it stopped."
        default:
            return nil
        }
    }

    /// Whether retrying the same operation could succeed without user action.
    public var isTransient: Bool {
        switch self {
        case .deviceDisconnected, .deviceStalled, .deviceNotFound:
            return true
        default:
            return false
        }
    }
}
