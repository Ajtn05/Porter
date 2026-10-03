import AppKit
import QuickLookThumbnailing
import ImageIO

/// A bounded image cache that survives folder visits. Remote bytes are never retained
/// after Quick Look has generated a thumbnail. Only one remote fetch runs at a time.
@MainActor
final class PreviewThumbnailStore {
    static let automaticFileLimit: Int64 = 16 * 1024 * 1024
    private let images = NSCache<NSString, NSImage>()
    private var unavailable: Set<String> = []
    private struct Pending {
        let token: UUID
        var isIcon: Bool
        let task: Task<NSImage?, Error>
    }
    private var pending: [String: Pending] = [:]
    private var failures: [String: any Error] = [:]
    private var tail: Task<Void, Never>?
    private var iconBytesRemaining: Int64 = 64 * 1024 * 1024

    init() {
        images.totalCostLimit = 64 * 1024 * 1024
        images.countLimit = 256
    }

    func reset(keepingImages: Bool = false) {
        cancelPending()
        unavailable.removeAll()
        failures.removeAll()
        if !keepingImages { images.removeAllObjects() }
        iconBytesRemaining = 64 * 1024 * 1024
        // Preserve the tail until the canceled reader releases the USB pipe.
    }

    func clearUnavailable() {
        unavailable.removeAll()
        failures.removeAll()
    }

    func cancelPending() {
        pending.values.forEach { $0.task.cancel() }
        pending.removeAll()
    }

    func cancelIconRequests() {
        let keys = pending.filter { $0.value.isIcon }.map(\.key)
        for key in keys {
            pending[key]?.task.cancel()
            pending[key] = nil
        }
    }

    func reserveIconBytes(_ count: Int64) -> Bool {
        guard count >= 0, count <= iconBytesRemaining else { return false }
        iconBytesRemaining -= count
        return true
    }

    func image(key: String, remoteSize: Int64?, isIcon: Bool, nativeThumbnail: Bool = false,
               load: @escaping @MainActor () async throws -> NSImage?) async throws -> NSImage? {
        if let image = images.object(forKey: key as NSString) { return image }
        if unavailable.contains("\(key):\(isIcon)") { return nil }
        if let error = failures[key] { throw error }
        if let request = pending[key] {
            // Selection keeps a shared fetch alive if icon view is turned off.
            if !isIcon { pending[key]?.isIcon = false }
            return try await request.task.value
        }
        if !nativeThumbnail, let remoteSize {
            guard remoteSize > 0, remoteSize <= Self.automaticFileLimit else { return nil }
            if isIcon, !reserveIconBytes(remoteSize) { return nil }
        }
        let previous = remoteSize == nil ? nil : tail
        let task = Task { @MainActor in
            await previous?.value
            try Task.checkCancellation()
            do {
                let image = try await load()
                try Task.checkCancellation()
                if let image {
                    images.setObject(image, forKey: key as NSString, cost: max(1, Int(image.size.width * image.size.height * 4)))
                } else { unavailable.insert("\(key):\(pending[key]?.isIcon ?? isIcon)") }
                return image
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if !(error is CancellationError) { failures[key] = error }
                throw error
            }
        }
        let token = UUID()
        pending[key] = Pending(token: token, isIcon: isIcon, task: task)
        if remoteSize != nil { tail = Task { _ = try? await task.value } }
        defer {
            // A reset can install a new request under the same local-file key.
            if pending[key]?.token == token { pending[key] = nil }
        }
        return try await task.value
    }

    static func renderData(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    static func render(_ url: URL) async throws -> NSImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 512, height: 512),
                                                  scale: 1, representationTypes: .thumbnail)
        let generator = QLThumbnailGenerator.shared
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                generator.generateBestRepresentation(for: request) { representation, error in
                    if let representation { continuation.resume(returning: representation.nsImage) }
                    else if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: nil) }
                }
            }
        } onCancel: {
            generator.cancel(request)
        }
    }
}
