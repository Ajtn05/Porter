import AppKit
import Foundation

// Command-line checks exercise state and scheduling without starting the app,
// contacting a phone, invoking Quick Look, or interacting with the desktop.
@MainActor
private final class Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private struct CheckFailed: Error { let message: String }
private struct PreviewFailed: Error {}

@main
@MainActor
struct BrowserStateChecks {
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailed(message: message) }
    }

    static func main() async throws {
        var passed = 0
        let image = NSImage(size: NSSize(width: 32, height: 32))
        let limit = PreviewThumbnailStore.automaticFileLimit

        // Regression: pane preferences and their stored representations must
        // remain independent when one side changes mode, sorting, or filtering.
        var android = PanePreferences()
        let mac = PanePreferences()
        android.viewMode = .grid
        android.sortField = .modified
        android.sortAscending = false
        android.showHiddenFiles = true
        android.showThumbnails = false
        let restored = try JSONDecoder().decode(PanePreferences.self, from: JSONEncoder().encode(android))
        try check(restored == android && mac.viewMode == .list && !mac.showHiddenFiles && mac.showThumbnails,
                  "Pane preferences did not remain independent or survive encoding")
        passed += 1

        let cache = PreviewThumbnailStore()
        let began = Gate(), release = Gate(), secondBegan = Gate()
        var downloads = 0
        let first = Task {
            try await cache.image(key: "shared", remoteSize: 1, isIcon: true) {
                downloads += 1
                began.open()
                await release.wait()
                return image
            }
        }
        await began.wait()
        let second = Task {
            secondBegan.open()
            return try await cache.image(key: "shared", remoteSize: 1, isIcon: false) {
                downloads += 1
                return image
            }
        }
        await secondBegan.wait()
        release.open()
        let firstImage = try await first.value, secondImage = try await second.value
        try check(downloads == 1 && firstImage === secondImage, "Selection and icon fetched the same file twice")
        passed += 1

        let serial = PreviewThumbnailStore()
        let firstStarted = Gate(), unblock = Gate(), queued = Gate()
        var order: [Int] = []
        let remote1 = Task {
            try await serial.image(key: "one", remoteSize: 1, isIcon: true) {
                order.append(1)
                firstStarted.open()
                await unblock.wait()
                order.append(2)
                return image
            }
        }
        await firstStarted.wait()
        let remote2 = Task {
            queued.open()
            return try await serial.image(key: "two", remoteSize: 1, isIcon: true) {
                order.append(3)
                return image
            }
        }
        await queued.wait()
        try check(order == [1], "Background remote requests overlapped")
        unblock.open()
        _ = try await remote1.value
        _ = try await remote2.value
        try check(order == [1, 2, 3], "Remote request ordering failed")
        passed += 1

        let budget = PreviewThumbnailStore()
        var budgetDownloads = 0
        for index in 0..<5 {
            _ = try await budget.image(key: "budget\(index)", remoteSize: limit, isIcon: true) {
                budgetDownloads += 1
                return image
            }
        }
        try check(budgetDownloads == 4, "Icon requests exceeded the folder download budget")
        _ = try await budget.image(key: "budget0", remoteSize: limit, isIcon: true) {
            budgetDownloads += 1
            return image
        }
        try check(budgetDownloads == 4, "Cached icons were not available after exhausting the budget")
        _ = try await budget.image(key: "selected", remoteSize: limit, isIcon: false) {
            budgetDownloads += 1
            return image
        }
        try check(budgetDownloads == 5, "Selection preview was blocked by the icon budget")
        passed += 1

        _ = try await budget.image(key: "tooLarge", remoteSize: limit + 1, isIcon: false) {
            budgetDownloads += 1
            return image
        }
        _ = try await budget.image(key: "unknownSize", remoteSize: 0, isIcon: true) {
            budgetDownloads += 1
            return image
        }
        try check(budgetDownloads == 5, "Large or unknown files were fetched automatically")
        passed += 1

        let misses = PreviewThumbnailStore()
        var attempts = 0
        for _ in 0..<2 {
            _ = try await misses.image(key: "unsupported", remoteSize: 1, isIcon: true) {
                attempts += 1
                return nil
            }
            do {
                _ = try await misses.image(key: "failed", remoteSize: 1, isIcon: true) {
                    attempts += 1
                    throw PreviewFailed()
                }
            } catch is PreviewFailed {}
        }
        try check(attempts == 2, "Unsupported or failed thumbnails were downloaded repeatedly")
        passed += 1

        let cancellation = PreviewThumbnailStore()
        let started = Gate(), finishOld = Gate(), newStarted = Gate(), finishNew = Gate(), enqueued = Gate()
        var queuedLoads = 0, replacementLoads = 0
        let old = Task {
            try await cancellation.image(key: "same", remoteSize: 1, isIcon: true) {
                started.open()
                await finishOld.wait()
                return image
            }
        }
        await started.wait()
        let canceledQueue = Task {
            enqueued.open()
            return try await cancellation.image(key: "queued", remoteSize: 1, isIcon: true) {
                queuedLoads += 1
                return image
            }
        }
        await enqueued.wait()
        cancellation.reset()
        let replacementEnqueued = Gate()
        let replacement = Task {
            replacementEnqueued.open()
            return try await cancellation.image(key: "same", remoteSize: 1, isIcon: true) {
                replacementLoads += 1
                newStarted.open()
                await finishNew.wait()
                return image
            }
        }
        await replacementEnqueued.wait()
        finishOld.open()
        do { _ = try await old.value; throw CheckFailed(message: "Reset returned a stale thumbnail") }
        catch is CancellationError {}
        do { _ = try await canceledQueue.value; throw CheckFailed(message: "Reset left a queued fetch active") }
        catch is CancellationError {}
        await newStarted.wait()
        let duplicateEnqueued = Gate()
        let duplicate = Task {
            duplicateEnqueued.open()
            return try await cancellation.image(key: "same", remoteSize: 1, isIcon: false) {
                replacementLoads += 1
                return image
            }
        }
        await duplicateEnqueued.wait()
        finishNew.open()
        _ = try await replacement.value
        _ = try await duplicate.value
        try check(queuedLoads == 0 && replacementLoads == 1,
                  "A canceled request removed its replacement or started a queued fetch")
        passed += 1

        let modes = PreviewThumbnailStore()
        let iconStarted = Gate(), completeIcon = Gate(), selectionJoined = Gate(), otherQueued = Gate()
        var otherDownloads = 0
        let icon = Task {
            try await modes.image(key: "selectedIcon", remoteSize: 1, isIcon: true) {
                iconStarted.open()
                await completeIcon.wait()
                return image
            }
        }
        await iconStarted.wait()
        let selection = Task {
            selectionJoined.open()
            return try await modes.image(key: "selectedIcon", remoteSize: 1, isIcon: false) {
                throw CheckFailed(message: "Selection failed to join the icon request")
            }
        }
        await selectionJoined.wait()
        let otherIcon = Task {
            otherQueued.open()
            return try await modes.image(key: "otherIcon", remoteSize: 1, isIcon: true) {
                otherDownloads += 1
                return image
            }
        }
        await otherQueued.wait()
        modes.cancelIconRequests()
        completeIcon.open()
        _ = try await icon.value
        _ = try await selection.value
        do { _ = try await otherIcon.value; throw CheckFailed(message: "Hidden icon view kept fetching") }
        catch is CancellationError {}
        try check(otherDownloads == 0, "Turning icon previews off canceled selection or fetched hidden icons")
        passed += 1

        let visits = PreviewThumbnailStore()
        var visitDownloads = 0
        _ = try await visits.image(key: "stableFingerprint", remoteSize: 1, isIcon: true) {
            visitDownloads += 1
            return image
        }
        visits.reset(keepingImages: true)
        _ = try await visits.image(key: "stableFingerprint", remoteSize: 1, isIcon: true) {
            visitDownloads += 1
            return image
        }
        try check(visitDownloads == 1, "Revisiting a folder downloaded a cached thumbnail again")
        visits.reset()
        _ = try await visits.image(key: "stableFingerprint", remoteSize: 1, isIcon: true) {
            visitDownloads += 1
            return image
        }
        try check(visitDownloads == 2, "Explicit refresh did not invalidate thumbnail content")
        passed += 1

        let native = PreviewThumbnailStore()
        var nativeDownloads = 0
        _ = try await native.image(key: "largeOriginal", remoteSize: limit * 10, isIcon: true, nativeThumbnail: true) {
            nativeDownloads += 1
            return image
        }
        try check(nativeDownloads == 1 && native.reserveIconBytes(64 * 1024 * 1024),
                  "A native thumbnail was blocked by original-file size or spent the fallback budget")
        passed += 1

        let fallbacks = PreviewThumbnailStore()
        var fallbackDownloads = 0
        _ = try await fallbacks.image(key: "noNative", remoteSize: 1, isIcon: true, nativeThumbnail: true) { nil }
        _ = try await fallbacks.image(key: "noNative", remoteSize: 1, isIcon: false, nativeThumbnail: true) {
            fallbackDownloads += 1
            return image
        }
        let fallbackImage = try await fallbacks.image(key: "noNative", remoteSize: 1, isIcon: true, nativeThumbnail: true) {
            fallbackDownloads += 1
            return nil
        }
        try check(fallbackDownloads == 1 && fallbackImage === image,
                  "A fast-icon miss prevented the selection preview from supplying a cached image")
        passed += 1

        print("Browser state checks: \(passed) passed")
    }
}
