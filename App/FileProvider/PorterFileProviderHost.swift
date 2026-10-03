import Foundation
import PorterKit

/// Services the sandboxed File Provider through its App-Group request queue.
///
/// The host app owns ADB process launching and USB access. The extension only
/// writes encoded requests into the document group, so no transport objects or
/// unauthenticated listener are exposed outside Porter.
final class PorterFileProviderHost {
    private let coordinator: DeviceCoordinator
    private var requestTask: Task<Void, Never>?

    init(coordinator: DeviceCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        guard let directories = PorterFileProviderFileBridge.directories() else {
            // An unsigned development app has no App-Group container. Finder
            // stays unavailable, but ordinary Porter browsing must still run.
            return
        }
        Self.removeAbandonedFiles(in: [
            directories.requests, directories.responses,
            directories.downloads, directories.cancellations, directories.progress
        ])
        requestTask?.cancel()
        let coordinator = coordinator
        requestTask = Task { @MainActor [coordinator, directories] in
            await Self.serve(
                coordinator: coordinator,
                directories: directories
            )
        }
    }

    deinit {
        requestTask?.cancel()
    }

    private static func serve(
        coordinator: DeviceCoordinator,
        directories: (requests: URL, responses: URL, downloads: URL,
                      cancellations: URL, progress: URL)
    ) async {
        while !Task.isCancelled {
            let requestURLs = ((try? FileManager.default.contentsOfDirectory(
                at: directories.requests,
                includingPropertiesForKeys: nil
            )) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

            for requestURL in requestURLs {
                guard !Task.isCancelled else { return }
                let requestID = requestURL.deletingPathExtension().lastPathComponent
                let cancellationURL = directories.cancellations.appendingPathComponent(requestID)
                guard let requestData = try? Data(contentsOf: requestURL) else {
                    try? FileManager.default.removeItem(at: requestURL)
                    continue
                }
                try? FileManager.default.removeItem(at: requestURL)
                Task { @MainActor [coordinator, directories, requestID, requestData, cancellationURL] in
                    await serveOne(
                        requestID: requestID, requestData: requestData,
                        cancellationURL: cancellationURL,
                        coordinator: coordinator, directories: directories
                    )
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private static func serveOne(
        requestID: String,
        requestData: Data,
        cancellationURL: URL,
        coordinator: DeviceCoordinator,
        directories: (requests: URL, responses: URL, downloads: URL,
                      cancellations: URL, progress: URL)
    ) async {
        if FileManager.default.fileExists(atPath: cancellationURL.path) {
            try? FileManager.default.removeItem(at: cancellationURL)
            return
        }

        let reply: PorterFileProviderBridgeReply
        do {
            let request = try JSONDecoder().decode(PorterFileProviderRequest.self, from: requestData)
            let response = try await response(
                for: request, coordinator: coordinator,
                downloads: directories.downloads, cancellationURL: cancellationURL,
                progressURL: directories.progress.appendingPathComponent(requestID)
            )
            reply = PorterFileProviderBridgeReply(
                responseData: try JSONEncoder().encode(response)
            )
        } catch {
            reply = PorterFileProviderBridgeReply(errorDescription: error.localizedDescription)
        }

        if FileManager.default.fileExists(atPath: cancellationURL.path) {
            if let data = reply.responseData,
               let response = try? JSONDecoder().decode(PorterFileProviderResponse.self, from: data),
               case .downloadedFile(let name, _) = response {
                try? FileManager.default.removeItem(at: directories.downloads.appendingPathComponent(name))
            }
            try? FileManager.default.removeItem(at: cancellationURL)
            return
        }
        let responseURL = directories.responses.appendingPathComponent("\(requestID).json")
        if let data = try? JSONEncoder().encode(reply) {
            try? data.write(to: responseURL, options: .atomic)
        }
    }

    private static func response(
        for request: PorterFileProviderRequest,
        coordinator: DeviceCoordinator,
        downloads: URL,
        cancellationURL: URL,
        progressURL: URL
    ) async throws -> PorterFileProviderResponse {
        let domainIdentifier: String
        switch request {
        case .volumes(let identifier), .list(let identifier, _), .item(let identifier, _),
                .download(let identifier, _):
            domainIdentifier = identifier
        }
        guard let rawDeviceID = PorterFileProviderDomainRegistry.deviceID(for: domainIdentifier) else {
            throw PorterFileProviderBridgeError.hostUnavailable
        }

        let transport = try await coordinator.transport(for: DeviceID(rawDeviceID))
        switch request {
        case .volumes:
            let volumes = try await transport.volumes()
            let records = volumes.map { volume in
                PorterFileProviderRecord(
                    path: volume.rootPath.string,
                    name: volume.displayName,
                    parentPath: nil,
                    size: 0,
                    modified: nil,
                    isDirectory: true
                )
            }
            return .items(records)

        case .list(_, let path):
            let directory = RemotePath(path)
            let files = try await transport.list(directory)
            let records = files.map { file in
                record(for: file, parentPath: directory.string)
            }
            return .items(records)

        case .item(_, let path):
            let file = try await transport.stat(RemotePath(path))
            return .item(file.map { record(for: $0, parentPath: $0.path.parent?.string) })

        case .download(_, let path):
            let outputURL = downloads.appendingPathComponent(UUID().uuidString)
            let downloadTask = Task { () throws -> Int64 in
                let didPull = try await transport.fastPull(
                    RemotePath(path), to: outputURL, progress: { _ in }
                )
                if !didPull {
                    guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    let handle = try FileHandle(forWritingTo: outputURL)
                    defer { try? handle.close() }
                    let stream = try await transport.readStream(RemotePath(path))
                    for try await chunk in stream {
                        try Task.checkCancellation()
                        try handle.write(contentsOf: chunk)
                    }
                }
                try Task.checkCancellation()
                let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
                return (attributes[.size] as? NSNumber)?.int64Value ?? 0
            }
            let poller = Task {
                var lastReported: Int64 = -1
                while !Task.isCancelled {
                    if FileManager.default.fileExists(atPath: cancellationURL.path) {
                        downloadTask.cancel()
                        return
                    }
                    if let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
                       let size = (attributes[.size] as? NSNumber)?.int64Value,
                       size != lastReported {
                        try? Data(String(size).utf8).write(to: progressURL, options: .atomic)
                        lastReported = size
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            do {
                let size = try await withTaskCancellationHandler {
                    try await downloadTask.value
                } onCancel: {
                    downloadTask.cancel()
                }
                if FileManager.default.fileExists(atPath: cancellationURL.path) {
                    throw CancellationError()
                }
                poller.cancel()
                await poller.value
                try? FileManager.default.removeItem(at: progressURL)
                return .downloadedFile(name: outputURL.lastPathComponent, size: size)
            } catch {
                downloadTask.cancel()
                poller.cancel()
                await poller.value
                try? FileManager.default.removeItem(at: progressURL)
                try? FileManager.default.removeItem(at: outputURL)
                throw error
            }
        }
    }

    private static func removeAbandonedFiles(in directories: [URL]) {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for directory in directories {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            for file in files {
                guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified < cutoff else { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private static func record(for file: RemoteFile, parentPath: String?) -> PorterFileProviderRecord {
        PorterFileProviderRecord(
            path: file.path.string,
            name: file.name,
            parentPath: parentPath,
            size: file.size,
            modified: file.modified,
            isDirectory: file.isDirectory
        )
    }
}
