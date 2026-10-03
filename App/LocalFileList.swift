import PorterKit
import Foundation

/// A row in the Mac pane. Mirrors `RemoteFile` so both panes can share views.
struct LocalFile: Identifiable, Hashable, Sendable {
    var url: URL
    var size: Int64
    var modified: Date?
    var isDirectory: Bool

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var isHidden: Bool { name.hasPrefix(".") }

    /// True for the sidecar an interrupted transfer leaves behind. Those are
    /// filtered out of the pane so a partial copy never looks like a real file.
    var isPartialTransfer: Bool { name.hasSuffix(TransferItem.partialSuffix) }

    static func contents(of directory: URL, includeHidden: Bool) -> [LocalFile] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants, .skipsPackageDescendants]
        if !includeHidden { options.insert(.skipsHiddenFiles) }

        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: options
        )) ?? []

        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return LocalFile(
                url: url,
                size: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate,
                isDirectory: values.isDirectory ?? false
            )
        }
        .filter { !$0.isPartialTransfer }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
