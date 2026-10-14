import Foundation
import PorterKit

private struct BrowserCheckFailed: Error { let message: String }

@main
@MainActor
struct AppBrowserChecks {
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw BrowserCheckFailed(message: message) }
    }

    static func main() async throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: manager.currentDirectoryPath)
            .appendingPathComponent("build/browser-fixture-\(UUID().uuidString)", isDirectory: true)
        let child = root.appendingPathComponent("Photos", isDirectory: true)
        try manager.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let photo = root.appendingPathComponent("photo.jpg")
        let trip = child.appendingPathComponent("trip.jpg")
        try Data([1]).write(to: photo)
        try Data([2]).write(to: trip)

        let model = AppModel()
        model.localDirectory = root
        model.refreshLocalPane()
        model.localSelection = [photo.path]
        model.localScrollAnchor = photo.path
        model.open(localDirectory: child)
        try check(model.localSelection.isEmpty && model.localHistory.backDestination?.path == root,
                  "Opening a folder kept the previous selection or failed to save its location")
        model.localSelection = [trip.path]
        model.localScrollAnchor = trip.path
        model.goBack(in: .mac)
        try check(model.localDirectory == root && model.localSelection == [photo.path]
                  && model.localScrollAnchor == photo.path,
                  "App Back lost the saved selection or scroll position")
        model.refreshLocalPane()
        try check(model.localSelection == [photo.path] && model.localHistory.forwardDestination?.path == child,
                  "A pane refresh cleared selection or Forward history")
        model.goForward(in: .mac)
        try check(model.localDirectory == child && model.localSelection == [trip.path]
                  && model.localScrollAnchor == trip.path,
                  "App Forward lost the saved selection or scroll position")
        try manager.removeItem(at: trip)
        model.refreshLocalPane()
        try check(model.localSelection.isEmpty, "Refresh retained the selection of a deleted file")
        model.goBack(in: .mac)
        model.localGoUp()
        try check(model.localHistory.forwardDestination == nil && model.localDirectory == root.deletingLastPathComponent(),
                  "Navigating to a new parent kept an obsolete Forward branch")
        print("App browser checks: 6 passed")
        let recoveryRoot = root.appendingPathComponent("Recovery")
        let recoveryChild = recoveryRoot.appendingPathComponent("Child")
        try manager.createDirectory(at: recoveryChild, withIntermediateDirectories: true)
        let recoveryPhoto = recoveryRoot.appendingPathComponent("photo.jpg")
        try Data([3]).write(to: recoveryPhoto)
        let recoveryModel = AppModel()
        recoveryModel.localDirectory = recoveryRoot
        recoveryModel.refreshLocalPane()
        recoveryModel.localSelection = [recoveryPhoto.path]
        let missing = recoveryRoot.appendingPathComponent("Missing")
        recoveryModel.open(localDirectory: missing)
        try check(recoveryModel.localDirectory == recoveryRoot && recoveryModel.localError != nil
                  && recoveryModel.localSelection == [recoveryPhoto.path] && recoveryModel.localHistory.backDestination == nil,
                  "A failed folder load discarded the last good location or selection")
        try manager.createDirectory(at: missing, withIntermediateDirectories: true)
        recoveryModel.retryLocalNavigation()
        try check(recoveryModel.localDirectory == missing && recoveryModel.localError == nil,
                  "Retry did not reopen the failed destination")
        recoveryModel.goBack(in: .mac)
        recoveryModel.open(localDirectory: recoveryChild)
        try manager.removeItem(at: recoveryChild)
        recoveryModel.refreshLocalPane()
        recoveryModel.goBack(in: .mac)
        recoveryModel.goForward(in: .mac)
        try check(recoveryModel.localDirectory == recoveryRoot && recoveryModel.localSelection == [recoveryPhoto.path]
                  && recoveryModel.localHistory.forwardDestination?.path == recoveryChild && recoveryModel.localError != nil,
                  "Failed Forward navigation moved history or dropped the saved selection")
        let lastEntries = recoveryModel.localEntries
        try manager.removeItem(at: recoveryRoot)
        recoveryModel.refreshLocalPane()
        try check(recoveryModel.localError != nil && recoveryModel.localEntries == lastEntries
                  && recoveryModel.localSelection == [recoveryPhoto.path],
                  "A failed refresh presented an empty folder or lost the selection")
        print("Browser recovery checks: 4 passed")
        let clipboardChecks = try await ClipboardChecks.run(in: root)
        print("Clipboard checks: \(clipboardChecks) passed")
        let operationChecks = try LocalFileOperationChecks.run(in: root)
        print("Local file operation checks: \(operationChecks) passed")
        let photoImportChecks = try await PhotoImportChecks.run(in: root)
        print("Photo import checks: \(photoImportChecks) passed")
        let conflictModel = AppModel()
        let context = ConflictContext(name: "photo.jpg", destinationPath: "/photos/photo.jpg",
            sourceSize: 3, destinationSize: 3, sourceModified: nil, destinationModified: nil)
        let firstRequest = Task { await conflictModel.resolveConflict(context) }
        while conflictModel.pendingConflict == nil { await Task.yield() }
        let firstConflict = conflictModel.pendingConflict!
        let secondRequest = Task { await conflictModel.resolveConflict(context) }
        while conflictModel.waitingConflicts.isEmpty { await Task.yield() }
        try check(conflictModel.pendingConflict?.id == firstConflict.id && conflictModel.waitingConflicts.count == 1,
                  "A concurrent plan replaced an unanswered conflict")
        firstConflict.answer(.keepBoth, applyToAll: false)
        firstConflict.cancel()
        conflictModel.pendingConflict = nil
        conflictModel.conflictSheetDismissed()
        let firstDecision = await firstRequest.value
        try check(firstDecision.resolution == .keepBoth && conflictModel.pendingConflict?.id != firstConflict.id,
                  "Answering a conflict lost its decision or did not advance the next request")
        conflictModel.pendingConflict?.cancel()
        conflictModel.pendingConflict = nil
        conflictModel.conflictSheetDismissed()
        let secondDecision = await secondRequest.value
        try check(secondDecision.resolution == .skip && secondDecision.applyToAll
                  && conflictModel.pendingConflict == nil && !conflictModel.isConflictPresented,
                  "Dismissing a conflict left its planner suspended")
        print("Conflict prompt checks: 3 passed")
    }
}
