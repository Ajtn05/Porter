import PorterKit
import Observation
import SwiftUI

/// Observable state backing every view in the app.
///
/// Discovery, transfer, and validation live in `PorterKit`, which does not
/// depend on SwiftUI. This type adapts them into bindable state.
@MainActor
@Observable
final class AppModel {

    // Devices
    private(set) var devices: [Device] = []
    var selectedDeviceID: DeviceID?
    private(set) var volumes: [StorageVolume] = []
    var selectedVolumeID: String?

    // Device pane
    private(set) var devicePath: RemotePath = .root
    private(set) var deviceEntries: [RemoteFile] = []
    var deviceSelection: Set<String> = []
    private(set) var deviceError: String?
    private(set) var isLoadingDevice = false

    // Mac pane
    var localDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads", isDirectory: true)
    private(set) var localEntries: [LocalFile] = []
    var localSelection: Set<String> = []

    // Shared view state
    var showHiddenFiles = false { didSet { Task { await refreshBothPanes() } } }
    var sortField: SortField = .name { didSet { resort() } }
    var sortAscending = true { didSet { resort() } }
    var viewMode: ViewMode = .list

    // Transfers
    private(set) var transferItems: [TransferItem] = []
    private(set) var summary = TransferSummary()
    var isDrawerExpanded = true

    // Sheets
    var pendingConflict: PendingConflict?
    var planWarnings: [PlanWarning] = []
    var showWarnings = false

    let coordinator: DeviceCoordinator
    let engine: TransferEngine
    private let queue: TransferQueue
    private var eventTask: Task<Void, Never>?
    private var deviceTask: Task<Void, Never>?

    init() {
        let queue = TransferQueue()
        let coordinator = DeviceCoordinator()
        self.queue = queue
        self.coordinator = coordinator
        self.engine = TransferEngine(queue: queue, resolver: coordinator)
    }

    /// Replaces the item list. Exists because `transferItems` is `private(set)`
    /// and the transfer extension lives in another file.
    func replaceTransferItems(_ items: [TransferItem]) {
        transferItems = items
    }

    var selectedDevice: Device? {
        devices.first { $0.id == selectedDeviceID }
    }

    var selectedVolume: StorageVolume? {
        volumes.first { $0.id == selectedVolumeID }
    }

    // MARK: - Lifecycle

    func start() {
        Task {
            await queue.load()
            transferItems = await queue.orderedItems
            await coordinator.start()
        }
        deviceTask = Task { [coordinator] in
            for await devices in await coordinator.deviceStream() {
                await MainActor.run { self.apply(devices: devices) }
            }
        }
        eventTask = Task { [engine] in
            for await event in await engine.events() {
                await MainActor.run { self.apply(event: event) }
            }
        }
        refreshLocalPane()
    }

    func shutDown() async {
        eventTask?.cancel()
        deviceTask?.cancel()
        await coordinator.stop()
        await queue.flush()
    }

    private func apply(devices: [Device]) {
        self.devices = devices

        // Auto-select the first browsable device so plugging in a phone is
        // enough to start browsing.
        if let current = selectedDeviceID, devices.contains(where: { $0.id == current }) {
            if selectedDevice?.readiness.isBrowsable == true && volumes.isEmpty {
                Task { await loadVolumes() }
            }
            return
        }
        selectedDeviceID = devices.first { $0.readiness.isBrowsable }?.id ?? devices.first?.id
        volumes = []
        deviceEntries = []
        devicePath = .root
        if selectedDevice?.readiness.isBrowsable == true {
            Task { await loadVolumes() }
        }
    }

    private func apply(event: TransferEvent) {
        switch event {
        case .itemChanged(let item):
            if let index = transferItems.firstIndex(where: { $0.id == item.id }) {
                transferItems[index] = item
            } else {
                transferItems.append(item)
            }
            // A completed copy changes the destination, so refresh that pane.
            if item.state == .completed {
                switch item.direction {
                case .pull: refreshLocalPane()
                case .push: Task { await refreshDevicePane() }
                }
            }
        case .summaryChanged(let summary):
            self.summary = summary
            Task { transferItems = await queue.orderedItems }
        case .sanitized, .batchFinished:
            break
        }
    }

    // MARK: - Device browsing

    func selectDevice(_ id: DeviceID) {
        guard selectedDeviceID != id else { return }
        selectedDeviceID = id
        volumes = []
        deviceEntries = []
        deviceSelection = []
        devicePath = .root
        deviceError = nil
        Task { await loadVolumes() }
    }

    func loadVolumes() async {
        guard let device = selectedDevice, device.readiness.isBrowsable else {
            volumes = []
            return
        }
        // Enumeration costs several device round trips, including reading
        // `mount` to see through the FUSE layer, so it needs a loading state.
        isLoadingDevice = true
        defer { isLoadingDevice = false }
        do {
            let transport = try await coordinator.transport(for: device.id)
            let loaded = try await transport.volumes()
            volumes = loaded
            if selectedVolumeID == nil || !loaded.contains(where: { $0.id == selectedVolumeID }) {
                selectedVolumeID = loaded.first?.id
            }
            if let root = selectedVolume?.rootPath {
                await open(devicePath: root)
            }
            deviceError = nil
        } catch {
            deviceError = describe(error)
        }
    }

    func selectVolume(_ id: String) {
        selectedVolumeID = id
        guard let volume = selectedVolume else { return }
        Task { await open(devicePath: volume.rootPath) }
    }

    func open(devicePath path: RemotePath) async {
        guard let device = selectedDevice else { return }
        isLoadingDevice = true
        defer { isLoadingDevice = false }
        do {
            let transport = try await coordinator.transport(for: device.id)
            let entries = try await transport.list(path)
            devicePath = path
            deviceEntries = sorted(entries)
            deviceSelection = []
            deviceError = nil
        } catch {
            deviceError = describe(error)
            // A transient failure usually means the screen locked mid-request.
            // Drop the transport so a retry reconnects instead of reusing it.
            if (error as? TransferError)?.isTransient == true {
                await coordinator.invalidateTransport(for: device.id)
            }
        }
    }

    func refreshDevicePane() async {
        await open(devicePath: devicePath)
    }

    func deviceGoUp() {
        guard let parent = devicePath.parent,
              let root = selectedVolume?.rootPath,
              devicePath != root else { return }
        Task { await open(devicePath: parent) }
    }

    // MARK: - Local browsing

    func refreshLocalPane() {
        localEntries = sorted(LocalFile.contents(of: localDirectory, includeHidden: showHiddenFiles))
        localSelection = []
    }

    func open(localDirectory url: URL) {
        localDirectory = url
        refreshLocalPane()
    }

    func localGoUp() {
        let parent = localDirectory.deletingLastPathComponent()
        guard parent.path != localDirectory.path else { return }
        open(localDirectory: parent)
    }

    func refreshBothPanes() async {
        refreshLocalPane()
        await refreshDevicePane()
    }

    // MARK: - Sorting

    private func resort() {
        deviceEntries = sorted(deviceEntries)
        localEntries = sorted(localEntries)
    }

    private func sorted(_ files: [RemoteFile]) -> [RemoteFile] {
        let visible = showHiddenFiles ? files : files.filter { !$0.isHidden }
        return visible.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let ascending = compare(lhs.name, rhs.name, lhs.size, rhs.size, lhs.modified, rhs.modified)
            return sortAscending ? ascending : !ascending
        }
    }

    private func sorted(_ files: [LocalFile]) -> [LocalFile] {
        files.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let ascending = compare(lhs.name, rhs.name, lhs.size, rhs.size, lhs.modified, rhs.modified)
            return sortAscending ? ascending : !ascending
        }
    }

    private func compare(_ lhsName: String, _ rhsName: String,
                         _ lhsSize: Int64, _ rhsSize: Int64,
                         _ lhsDate: Date?, _ rhsDate: Date?) -> Bool {
        switch sortField {
        case .name:
            return lhsName.localizedStandardCompare(rhsName) == .orderedAscending
        case .size:
            return lhsSize < rhsSize
        case .modified:
            return (lhsDate ?? .distantPast) < (rhsDate ?? .distantPast)
        }
    }

    private func describe(_ error: any Error) -> String {
        guard let transferError = error as? TransferError else { return error.localizedDescription }
        if let suggestion = transferError.recoverySuggestion {
            return "\(transferError.errorDescription ?? "") \(suggestion)"
        }
        return transferError.errorDescription ?? error.localizedDescription
    }
}
