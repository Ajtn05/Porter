import Foundation
import UniformTypeIdentifiers

func browserFileKind(name: String, isDirectory: Bool) -> String {
    if isDirectory { return "Folder" }
    let fileExtension = (name as NSString).pathExtension
    return UTType(filenameExtension: fileExtension)?.localizedDescription
        ?? (fileExtension.isEmpty ? "Document" : "\(fileExtension.uppercased()) document")
}

enum BrowserPane: String {
    case mac, android
}

enum BrowserCommand {
    case newFolder, rename, open, quickLook, delete, copyAcross, copy, paste, selectAll
}

struct BrowserCommandRequest {
    let pane: BrowserPane
    let command: BrowserCommand
}

extension Notification.Name {
    static let browserCommandRequested = Notification.Name("app.porter.browserCommand")
}

struct BrowserLocation<Path: Hashable>: Equatable {
    var path: Path
    var selection: Set<String> = []
    var scrollAnchor: String?
}

/// History commits after enumeration succeeds, so failed device requests do
/// not consume Back or Forward entries.
struct BrowserHistory<Path: Hashable> {
    private(set) var current: BrowserLocation<Path>?
    private(set) var previous: [BrowserLocation<Path>] = []
    private(set) var next: [BrowserLocation<Path>] = []

    var backDestination: BrowserLocation<Path>? { previous.last }
    var forwardDestination: BrowserLocation<Path>? { next.last }

    mutating func update(selection: Set<String>, scrollAnchor: String?) {
        current?.selection = selection
        current?.scrollAnchor = scrollAnchor
    }

    mutating func visit(_ path: Path) {
        guard current?.path != path else { return }
        if let current { previous.append(current) }
        if previous.count > 100 { previous.removeFirst(previous.count - 100) }
        current = BrowserLocation(path: path)
        next = []
    }

    @discardableResult
    mutating func goBack() -> BrowserLocation<Path>? {
        guard let destination = previous.popLast() else { return nil }
        if let current { next.append(current) }
        current = destination
        return destination
    }

    @discardableResult
    mutating func goForward() -> BrowserLocation<Path>? {
        guard let destination = next.popLast() else { return nil }
        if let current { previous.append(current) }
        current = destination
        return destination
    }

    mutating func reset() { self = Self() }
}
