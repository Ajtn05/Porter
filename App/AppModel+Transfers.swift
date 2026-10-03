import PorterKit
import Foundation

/// A conflict waiting on the user, plus the continuation the planner is parked on.
@MainActor
final class PendingConflict: Identifiable {
    let id = UUID()
    let context: ConflictContext
    let remaining: Int
    private var continuation: CheckedContinuation<ConflictDecision, Never>?

    init(context: ConflictContext, remaining: Int,
         continuation: CheckedContinuation<ConflictDecision, Never>) {
        self.context = context
        self.remaining = remaining
        self.continuation = continuation
    }

    func answer(_ resolution: ConflictResolution, applyToAll: Bool) {
        continuation?.resume(returning: ConflictDecision(resolution: resolution, applyToAll: applyToAll))
        continuation = nil
    }

    /// Dismissing the sheet without a choice skips the remaining conflicts.
    func cancel() {
        continuation?.resume(returning: ConflictDecision(resolution: .skip, applyToAll: true))
        continuation = nil
    }
}

/// Bridges the planner's `async` question to a SwiftUI sheet.
struct InteractiveConflictResolver: ConflictResolving {
    let model: AppModel

    func resolve(_ context: ConflictContext) async -> ConflictDecision {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                model.pendingConflict = PendingConflict(
                    context: context, remaining: 0, continuation: continuation
                )
            }
        }
    }
}

extension AppModel {

    // MARK: - Copying

    /// Copies the device-pane selection into the current Mac directory.
    func copySelectionToMac() {
        let selected = deviceEntries.filter { deviceSelection.contains($0.id) }
        guard !selected.isEmpty, let device = selectedDevice else { return }
        copyToMac(selected, from: device, into: localDirectory)
    }

    func copyToMac(_ files: [RemoteFile], from device: Device, into destination: URL) {
        Task {
            do {
                let transport = try await coordinator.transport(for: device.id)
                let plan = try await TransferPlanner().planPull(
                    sources: files, from: transport, device: device.id,
                    toLocalDirectory: destination,
                    conflicts: InteractiveConflictResolver(model: self),
                    includeHidden: androidView.showHiddenFiles
                )
                await present(plan)
            } catch {
                await MainActor.run { self.reportPlanFailure(error) }
            }
        }
    }

    /// Copies the Mac-pane selection into the current device directory.
    func copySelectionToDevice() {
        let urls = localEntries.filter { localSelection.contains($0.id) }.map(\.url)
        guard !urls.isEmpty else { return }
        copyToDevice(urls, into: devicePath)
    }

    func copyToDevice(_ urls: [URL], into destination: RemotePath) {
        guard let device = selectedDevice else { return }
        Task {
            do {
                let transport = try await coordinator.transport(for: device.id)
                let plan = try await TransferPlanner().planPush(
                    sources: urls, to: destination, on: transport, device: device.id,
                    volume: selectedVolume,
                    conflicts: InteractiveConflictResolver(model: self),
                    includeHidden: macView.showHiddenFiles
                )
                await present(plan)
            } catch {
                await MainActor.run { self.reportPlanFailure(error) }
            }
        }
    }

    /// Surfaces the plan's warnings, then enqueues its items.
    ///
    /// A blocking warning - insufficient space, or a file over the volume's
    /// per-file limit - stops the batch rather than letting it fail partway.
    private func present(_ plan: TransferPlan) async {
        await MainActor.run {
            self.planWarnings = plan.warnings
            self.showWarnings = !plan.warnings.isEmpty
        }
        guard !plan.isBlocked, !plan.items.isEmpty else { return }
        await engine.enqueue(plan.items)
        await MainActor.run { self.isDrawerExpanded = true }
    }

    @MainActor
    private func reportPlanFailure(_ error: any Error) {
        let message = (error as? TransferError)?.errorDescription ?? error.localizedDescription
        planWarnings = [.skippedUnreadable(path: "this copy", reason: message)]
        showWarnings = true
    }

    // MARK: - Transfer controls

    func pauseAll() { Task { await engine.pauseAll() } }
    func resumeAll() { Task { await engine.resumeAll() } }
    func pause(_ id: UUID) { Task { await engine.pause(id) } }
    func resume(_ id: UUID) { Task { await engine.resume(id) } }
    func cancel(_ id: UUID) { Task { await engine.cancel(id) } }

    func clearFinished() {
        Task {
            await engine.queue.clearCompleted()
            let items = await engine.queue.orderedItems
            await MainActor.run { self.replaceTransferItems(items) }
        }
    }

    // MARK: - File operations

    func createFolderOnDevice(named name: String) {
        guard let device = selectedDevice, !name.isEmpty else { return }
        Task {
            do {
                let transport = try await coordinator.transport(for: device.id)
                try await transport.createDirectory(devicePath.appending(name))
                await refreshDevicePane()
            } catch {
                await MainActor.run { self.reportPlanFailure(error) }
            }
        }
    }

    func createFolderOnMac(named name: String) {
        guard !name.isEmpty else { return }
        let url = localDirectory.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        refreshLocalPane()
    }

    func renameOnDevice(_ file: RemoteFile, to name: String) {
        guard let device = selectedDevice, !name.isEmpty, name != file.name else { return }
        Task {
            do {
                let transport = try await coordinator.transport(for: device.id)
                guard let parent = file.path.parent else { return }
                try await transport.move(from: file.path, to: parent.appending(name))
                await refreshDevicePane()
            } catch {
                await MainActor.run { self.reportPlanFailure(error) }
            }
        }
    }

    func renameOnMac(_ file: LocalFile, to name: String) {
        guard !name.isEmpty, name != file.name else { return }
        let destination = file.url.deletingLastPathComponent().appendingPathComponent(name)
        try? FileManager.default.moveItem(at: file.url, to: destination)
        refreshLocalPane()
    }

    /// Deletes the device-pane selection. Irreversible: Android exposes no
    /// Trash, so callers must confirm first.
    func deleteSelectedOnDevice() {
        let doomed = deviceEntries.filter { deviceSelection.contains($0.id) }
        guard let device = selectedDevice, !doomed.isEmpty else { return }
        Task {
            do {
                let transport = try await coordinator.transport(for: device.id)
                for file in doomed {
                    try await transport.remove(file.path, recursive: file.isDirectory)
                }
                await refreshDevicePane()
            } catch {
                await MainActor.run { self.reportPlanFailure(error) }
            }
        }
    }

    /// Moves the Mac-pane selection to the Trash.
    func trashSelectedOnMac() {
        let doomed = localEntries.filter { localSelection.contains($0.id) }
        for file in doomed {
            try? FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
        }
        refreshLocalPane()
    }

    var deviceSelectionDescription: String {
        let files = deviceEntries.filter { deviceSelection.contains($0.id) }
        if files.count == 1 { return "\u{201C}\(files[0].name)\u{201D}" }
        return "\(files.count) items"
    }
}
