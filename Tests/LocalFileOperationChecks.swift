import Foundation

private struct LocalOperationCheckFailed: Error { let message: String }

@MainActor
enum LocalFileOperationChecks {
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw LocalOperationCheckFailed(message: message) }
    }

    static func run(in root: URL) throws -> Int {
        let manager = FileManager.default
        let directory = root.appendingPathComponent("File operations", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = AppModel()
        model.localDirectory = directory
        model.refreshLocalPane()
        var passed = 0

        try check(model.createFolderOnMac(named: "Photos") == nil
                  && model.localEntries.contains { $0.name == "Photos" && $0.isDirectory },
                  "Successful folder creation failed or did not refresh the pane")
        let marker = directory.appendingPathComponent("Photos/keep.jpg")
        try Data([1]).write(to: marker)
        let duplicateFolder = model.createFolderOnMac(named: "Photos")
        try check(duplicateFolder?.contains("already exists") == true && manager.fileExists(atPath: marker.path),
                  "Creating an existing folder appeared to succeed or changed its contents")
        passed += 1

        let first = directory.appendingPathComponent("first.txt")
        let second = directory.appendingPathComponent("second.txt")
        try Data([2]).write(to: first)
        try Data([3]).write(to: second)
        model.refreshLocalPane()
        model.localSelection = [first.path]
        guard let file = model.localEntries.first(where: { $0.url == first }) else {
            throw LocalOperationCheckFailed(message: "Rename fixture was not enumerated")
        }
        let collision = model.renameOnMac(file, to: second.lastPathComponent)
        try check(collision?.contains("already exists") == true && model.localSelection == [first.path]
                  && (try Data(contentsOf: first)) == Data([2]) && (try Data(contentsOf: second)) == Data([3]),
                  "Failed rename lost its source, overwrote its destination, or cleared selection")
        passed += 1

        let renamed = directory.appendingPathComponent("renamed.txt")
        try check(model.renameOnMac(file, to: renamed.lastPathComponent) == nil
                  && !manager.fileExists(atPath: first.path)
                  && model.localEntries.contains { $0.url == renamed },
                  "Successful rename failed or did not refresh the pane")
        guard let renamedFile = model.localEntries.first(where: { $0.url == renamed }) else {
            throw LocalOperationCheckFailed(message: "Renamed fixture was not enumerated")
        }
        try check(model.renameOnMac(renamedFile, to: "RENAMED.txt") == nil
                  && model.localEntries.contains { $0.name == "RENAMED.txt" },
                  "A rename changing only letter case was rejected")
        passed += 1

        for invalidName in ["", " ", ".", "..", "../outside", "nested/file", "bad\0name"] {
            try check(model.createFolderOnMac(named: invalidName) != nil
                      && model.renameOnMac(renamedFile, to: invalidName) != nil,
                      "An invalid name was passed to a Mac file operation")
        }
        try check(!manager.fileExists(atPath: root.appendingPathComponent("outside").path),
                  "An invalid folder name escaped the current directory")
        passed += 1

        model.localDirectory = directory.appendingPathComponent("Missing parent", isDirectory: true)
        let missingParent = model.createFolderOnMac(named: "Child")
        try check(missingParent?.contains("no longer available") == true,
                  "Missing-parent folder creation did not produce an actionable error")
        let deleted = model.renameOnMac(file, to: "missing.txt")
        try check(deleted?.contains("no longer available") == true && deleted?.contains("first.txt") == true,
                  "A stale rename source failed without naming the missing item")
        passed += 1

        let trashSource = root.appendingPathComponent("Trash sources", isDirectory: true)
        let fixtureTrash = root.appendingPathComponent("Fixture Trash", isDirectory: true)
        try manager.createDirectory(at: trashSource, withIntermediateDirectories: true)
        try manager.createDirectory(at: fixtureTrash, withIntermediateDirectories: true)
        let denied = trashSource.appendingPathComponent("a-denied.txt")
        let accepted = trashSource.appendingPathComponent("b-accepted.txt")
        let readOnly = trashSource.appendingPathComponent("c-readonly.txt")
        for url in [denied, accepted, readOnly] { try Data([4]).write(to: url) }
        var attempted: [URL] = []
        var denyChanges = true
        let operations = LocalFileOperations(moveToTrash: { url in
            attempted.append(url)
            if denyChanges && url == denied { throw CocoaError(.fileWriteNoPermission) }
            if denyChanges && url == readOnly { throw CocoaError(.fileWriteVolumeReadOnly) }
            // Successful test moves stay inside the workspace instead of
            // changing the user's real Trash.
            try manager.moveItem(at: url, to: fixtureTrash.appendingPathComponent(url.lastPathComponent))
        })
        let trashModel = AppModel(localFileOperations: operations)
        trashModel.localDirectory = trashSource
        trashModel.refreshLocalPane()
        trashModel.localSelection = [denied.path, accepted.path, readOnly.path]
        trashModel.trashSelectedOnMac()
        guard let report = trashModel.localTrashReport else {
            throw LocalOperationCheckFailed(message: "Trash failures were not presented")
        }
        try check(report.completedCount == 1 && Set(report.failures.map(\.url)) == [denied, readOnly]
                  && attempted == [denied, accepted, readOnly]
                  && trashModel.localSelection == [denied.path, readOnly.path]
                  && manager.fileExists(atPath: fixtureTrash.appendingPathComponent(accepted.lastPathComponent).path),
                  "Trash stopped on failure, lost failure details, or failed to preserve the remaining selection")
        try check(report.failures.first(where: { $0.url == denied })?.reason.contains("permission") == true
                  && report.failures.first(where: { $0.url == readOnly })?.reason.contains("read-only") == true,
                  "Trash errors did not identify permission and read-only failures")
        passed += 1

        denyChanges = false
        trashModel.trashSelectedOnMac()
        try check(trashModel.localTrashReport == nil && trashModel.localSelection.isEmpty
                  && trashModel.localEntries.isEmpty && attempted.count == 5,
                  "Retry kept a stale Trash error or retried files already moved")
        passed += 1

        let fullDisk = LocalFileFailure(url: denied, error: CocoaError(.fileWriteOutOfSpace))
        let customError = NSError(domain: "FixtureError", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The fixture operation failed.", NSLocalizedRecoverySuggestionErrorKey: "Try the fixture again."])
        let custom = LocalFileFailure(url: denied, error: customError)
        try check(fullDisk.reason.contains("disk is full") && custom.reason.contains("Try the fixture again."),
                  "Error formatting dropped recovery guidance")
        passed += 1
        return passed
    }
}
