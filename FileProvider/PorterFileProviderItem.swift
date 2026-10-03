import CryptoKit
import FileProvider
import Foundation
import UniformTypeIdentifiers

final class PorterFileProviderItem: NSObject, NSFileProviderItem {
    private let record: PorterFileProviderRecord?
    private let rootName: String?

    init(record: PorterFileProviderRecord) {
        self.record = record
        self.rootName = nil
    }

    private init(rootName: String) {
        self.record = nil
        self.rootName = rootName
    }

    static func root(named name: String) -> PorterFileProviderItem {
        PorterFileProviderItem(rootName: name)
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        guard let record else { return .rootContainer }
        return PorterFileProviderItemIdentifier.item(for: record.path)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        guard let record, let parentPath = record.parentPath else { return .rootContainer }
        return PorterFileProviderItemIdentifier.item(for: parentPath)
    }

    var filename: String { record?.name ?? rootName ?? "Porter" }

    var contentType: UTType {
        guard let record else { return .folder }
        if record.isDirectory { return .folder }
        let fileExtension = (record.name as NSString).pathExtension
        return UTType(filenameExtension: fileExtension) ?? .data
    }

    var capabilities: NSFileProviderItemCapabilities { [.allowsReading] }

    var documentSize: NSNumber? {
        record.map { NSNumber(value: $0.size) }
    }

    var contentModificationDate: Date? { record?.modified }

    var itemVersion: NSFileProviderItemVersion {
        let descriptor: String
        if let record {
            descriptor = "\(record.size):\(record.modified?.timeIntervalSince1970 ?? 0)"
        } else {
            descriptor = "root"
        }
        let digest = Data(SHA256.hash(data: Data(descriptor.utf8)))
        return NSFileProviderItemVersion(contentVersion: digest, metadataVersion: digest)
    }
}
