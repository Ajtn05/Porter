import Foundation

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
        let clipboardChecks = try await ClipboardChecks.run(in: root)
        print("Clipboard checks: \(clipboardChecks) passed")
    }
}
