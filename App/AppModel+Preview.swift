import AppKit
import Foundation
import PorterKit

extension AppModel {
    func invalidatePreviewThumbnails(clearCache: Bool = false) {
        previewGeneration = UUID()
        if clearCache { previewSession = UUID() }
        previewThumbnails.reset(keepingImages: !clearCache)
    }

    func thumbnail(for row: FileRow, isIcon: Bool = true) async throws -> NSImage? {
        try Task.checkCancellation()
        guard !row.isDirectory, row.supportsThumbnail else { return nil }
        if let url = row.localURL {
            guard !isIcon || (macView.showThumbnails && macView.viewMode == .grid) else { return nil }
            let key = "mac:\(row.id):\(row.size):\(row.modified?.timeIntervalSince1970 ?? 0)"
            return try await localThumbnails.image(key: key, remoteSize: nil, isIcon: isIcon) {
                try await PreviewThumbnailStore.render(url)
            }
        }
        guard !isIcon || (androidView.showThumbnails && androidView.viewMode == .grid) else { return nil }
        guard let file = deviceEntries.first(where: { $0.id == row.id }),
              let device = selectedDevice else { return nil }
        let native = device.transport == .mtp
        if !native, (row.size <= 0 || row.size > PreviewThumbnailStore.automaticFileLimit) { return nil }
        let generation = previewGeneration
        let key = "android:\(previewSession):\(device.id.rawValue):\(file.id):\(file.size):\(file.modified?.timeIntervalSince1970 ?? 0)"
        let image = try await previewThumbnails.image(key: key, remoteSize: row.size, isIcon: isIcon,
                                                       nativeThumbnail: native) { [self] in
            guard previewGeneration == generation, selectedDeviceID == device.id,
                  !summary.isRunning, !isLoadingDevice else { throw CancellationError() }
            let transport = try await coordinator.transport(for: device.id)
            if native, let data = try await transport.thumbnail(file.path),
               let image = PreviewThumbnailStore.renderData(data) { return image }
            // Native thumbnails can preview large originals. Download fallback
            // is bounded and optional for icons so a thumbnail miss stays cheap.
            guard file.size > 0, file.size <= PreviewThumbnailStore.automaticFileLimit else { return nil }
            let selected = deviceSelection.count == 1 && deviceSelection.contains(file.id)
            if native, isIcon, !selected {
                guard downloadIconFallbacks else { return nil }
                guard previewThumbnails.reserveIconBytes(file.size) else { return nil }
            }
            let url = try await RemotePreviewLoader.load(file, using: transport,
                                                       byteLimit: PreviewThumbnailStore.automaticFileLimit)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            return try await PreviewThumbnailStore.render(url)
        }
        try Task.checkCancellation()
        guard previewGeneration == generation, selectedDeviceID == device.id else { throw CancellationError() }
        return image
    }

    /// Materializes one device file only when the user invokes Quick Look.
    func preparePreview(for id: String) async throws -> URL {
        guard let file = deviceEntries.first(where: { $0.id == id }),
              !file.isDirectory,
              let device = selectedDevice else {
            throw PreviewError.unavailable
        }
        let generation = previewGeneration
        let transport = try await coordinator.transport(for: device.id)
        let url = try await RemotePreviewLoader.load(file, using: transport)
        guard selectedDeviceID == device.id, previewGeneration == generation,
              deviceEntries.contains(where: { $0 == file }) else {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            throw CancellationError()
        }
        return url
    }
}

private enum PreviewError: LocalizedError {
    case unavailable, tooLarge

    var errorDescription: String? {
        switch self {
        case .unavailable: return "The selected device file is no longer available."
        case .tooLarge: return "This file exceeds the automatic preview limit. Use Quick Look to load it."
        }
    }
}

private enum RemotePreviewLoader {
    static func load(_ file: RemoteFile, using transport: any DeviceTransport,
                     byteLimit: Int64? = nil) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PorterPreviews", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = FilenameSanitizer(destination: .macOS).sanitize(file.name).name
        let url = directory.appendingPathComponent(name, isDirectory: false)

        do {
            try Task.checkCancellation()
            // Automatic previews use a bounded stream even when fastPull exists.
            let didPull: Bool
            if byteLimit == nil { didPull = try await transport.fastPull(file.path, to: url, progress: { _ in }) }
            else { didPull = false }
            if !didPull {
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                let stream = try await transport.readStream(file.path)
                var received: Int64 = 0
                for try await chunk in stream {
                    try Task.checkCancellation()
                    received += Int64(chunk.count)
                    if let byteLimit, received > byteLimit { throw PreviewError.tooLarge }
                    try handle.write(contentsOf: chunk)
                }
            }
            try Task.checkCancellation()
            return url
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
