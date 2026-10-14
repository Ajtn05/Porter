import Foundation

enum BrowserFileName {
    static func validationMessage(for name: String) -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a name." }
        if name == "." || name == ".." { return "Choose a name other than \u{201C}.\u{201D} or \u{201C}..\u{201D}." }
        if name.contains("/") || name.contains("\0") { return "Names cannot contain a slash or a null character." }
        return nil
    }
}

struct LocalFileFailure: Identifiable {
    let url: URL
    let reason: String
    var id: URL { url }

    init(url: URL, error: any Error) {
        self.url = url
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: error.code) {
            case .fileWriteFileExists:
                reason = "An item with this name already exists. Choose another name."
            case .fileReadNoPermission, .fileWriteNoPermission:
                reason = "Porter does not have permission to change this item. Check the folder\u{2019}s permissions in Finder or choose a writable folder."
            case .fileNoSuchFile, .fileReadNoSuchFile:
                reason = "This item or its containing folder is no longer available. Refresh the folder and try again."
            case .fileWriteOutOfSpace:
                reason = "The disk is full. Free some space and try again."
            case .fileWriteVolumeReadOnly:
                reason = "This disk is read-only. Choose a writable disk."
            default:
                reason = [error.localizedDescription, error.localizedRecoverySuggestion].compactMap { $0 }.joined(separator: " ")
            }
        } else {
            reason = [error.localizedDescription, error.localizedRecoverySuggestion].compactMap { $0 }.joined(separator: " ")
        }
    }
}

struct LocalTrashReport: Identifiable {
    let id = UUID()
    let completedCount: Int
    let failures: [LocalFileFailure]
}

struct LocalFileOperations {
    var moveToTrash: (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    func createFolder(named name: String, in directory: URL) throws {
        let destination = directory.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    }

    func rename(_ file: LocalFile, to name: String) throws {
        let destination = file.url.deletingLastPathComponent().appendingPathComponent(name)
        try FileManager.default.moveItem(at: file.url, to: destination)
    }

    func trash(_ files: [LocalFile]) -> LocalTrashReport {
        var completedCount = 0
        var failures: [LocalFileFailure] = []
        for file in files {
            do {
                try moveToTrash(file.url)
                completedCount += 1
            } catch {
                failures.append(LocalFileFailure(url: file.url, error: error))
            }
        }
        return LocalTrashReport(completedCount: completedCount, failures: failures)
    }
}
