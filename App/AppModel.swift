import AppKit
import PorterKit
import Observation
import SwiftUI

struct MTPConflict: Identifiable {
    let locationID: Int
    let phoneName: String
    let ownerName: String
    let ownerPID: Int?

    var id: Int { locationID }
    var isSystemOwner: Bool { ownerName == "ptpcamerad" }

    /// Only offer a quit action for a verified, ordinary app. A reused PID or
    /// a system daemon must never turn an MTP prompt into an unrelated quit.
    var runningApp: NSRunningApplication? {
        guard !isSystemOwner, let ownerPID, ownerPID > 0,
              ownerPID <= Int(Int32.max),
              let app = NSRunningApplication(processIdentifier: pid_t(ownerPID)),
              !app.isTerminated, app.bundleURL != nil else { return nil }
        let names = [app.executableURL?.lastPathComponent, app.localizedName]
            .compactMap { $0 }
        guard names.contains(where: { $0.caseInsensitiveCompare(ownerName) == .orderedSame }) else {
            return nil
        }
        return app
    }
}

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
    private var deviceBrowseGeneration: UInt64 = 0
    private var volumeLoadToken: UUID?
    private var loadingVolumesFor: DeviceID?

    // Mac pane
    var localDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads", isDirectory: true)
    private(set) var localEntries: [LocalFile] = []
    var localSelection: Set<String> = []

    // Independent pane preferences
    var macView = PanePreferences.load("macBrowser") {
        didSet {
            macView.save("macBrowser")
            if macView.showHiddenFiles != oldValue.showHiddenFiles { refreshLocalPane() }
            else { localEntries = sorted(localEntries) }
        }
    }
    var androidView = PanePreferences.load("androidBrowser") {
        didSet {
            androidView.save("androidBrowser")
            if androidView.showHiddenFiles != oldValue.showHiddenFiles {
                Task { await refreshDevicePane() }
            } else { deviceEntries = sorted(deviceEntries) }
            if !androidView.showThumbnails || androidView.viewMode != .grid {
                previewThumbnails.cancelIconRequests()
            }
        }
    }
    var showMacPreview = UserDefaults.standard.bool(forKey: "showMacPreview") {
        didSet { UserDefaults.standard.set(showMacPreview, forKey: "showMacPreview") }
    }
    var showAndroidPreview = UserDefaults.standard.object(forKey: "showAndroidPreview") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showAndroidPreview, forKey: "showAndroidPreview") }
    }
    let previewThumbnails = PreviewThumbnailStore()
    let localThumbnails = PreviewThumbnailStore()
    var previewGeneration = UUID()
    var previewSession = UUID()
    var downloadIconFallbacks = UserDefaults.standard.bool(forKey: "downloadIconFallbacks") {
        didSet {
            UserDefaults.standard.set(downloadIconFallbacks, forKey: "downloadIconFallbacks")
            previewThumbnails.cancelIconRequests()
            previewThumbnails.clearUnavailable()
        }
    }

    // Transfers
    private(set) var transferItems: [TransferItem] = []
    private(set) var summary = TransferSummary()
    var isDrawerExpanded = true

    // Sheets
    var pendingConflict: PendingConflict?
    var planWarnings: [PlanWarning] = []
    var showWarnings = false
    var finderDomainMessage: String?
    private(set) var mtpConflicts: [MTPConflict] = []
    private(set) var mtpQuitError: String?
    private var promptedMTPLocations: Set<Int> = []
    private var observedUSBLocations: Set<Int> = []

    let coordinator: DeviceCoordinator
    let engine: TransferEngine
    private let queue: TransferQueue
    private let fileProviderHost: PorterFileProviderHost
    private var eventTask: Task<Void, Never>?
    private var deviceTask: Task<Void, Never>?

    init() {
        let queue = TransferQueue()
        let coordinator = DeviceCoordinator()
        self.queue = queue
        self.coordinator = coordinator
        self.engine = TransferEngine(queue: queue, resolver: coordinator,
                                     maximumConcurrency: min(8, max(1, UserDefaults.standard.object(forKey: "maximumConcurrency") as? Int ?? 3)),
                                     verifiesChecksums: UserDefaults.standard.object(forKey: "verifyChecksums") as? Bool ?? true)
        self.fileProviderHost = PorterFileProviderHost(coordinator: coordinator)
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
        // Arm the MTP claim before loading saved state or starting the File
        // Provider, since claiming is decided as the USB interface appears.
        MTPInterfaceClaimer.shared.start(onAttempt: { [weak self] attempt in
            Task { @MainActor [weak self] in self?.handleMTPAttempt(attempt) }
        })
        fileProviderHost.start()
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
        let previouslySelected = selectedDevice
        self.devices = devices
        let connectedLocations = Set(devices.compactMap { $0.usb?.locationID })
        // The claimer can report a loss before discovery publishes its first
        // device snapshot. Only a location previously seen by discovery can
        // now be treated as detached.
        let detachedLocations = observedUSBLocations.subtracting(connectedLocations)
        promptedMTPLocations.subtract(detachedLocations)
        mtpConflicts.removeAll { detachedLocations.contains($0.locationID) }
        observedUSBLocations = connectedLocations

        if let previouslySelected,
           let updated = devices.first(where: { $0.id == previouslySelected.id }),
           updated.transport != previouslySelected.transport {
            selectedDeviceID = nil
            selectDevice(updated.id)
            return
        }

        // Auto-select the first browsable device so plugging in a phone is
        // enough to start browsing.
        if let current = selectedDeviceID, devices.contains(where: { $0.id == current }) {
            if selectedDevice?.readiness.isBrowsable == true && volumes.isEmpty {
                Task { await loadVolumes() }
            }
            return
        }
        selectedDeviceID = devices.first { $0.readiness.isBrowsable }?.id ?? devices.first?.id
        deviceBrowseGeneration &+= 1
        volumeLoadToken = nil
        loadingVolumesFor = nil
        volumes = []
        selectedVolumeID = nil
        invalidatePreviewThumbnails(clearCache: true)
        deviceEntries = []
        devicePath = .root
        deviceError = nil
        isLoadingDevice = false
        if selectedDevice?.readiness.isBrowsable == true {
            Task { await loadVolumes() }
        }
    }

    var currentMTPConflict: MTPConflict? { mtpConflicts.first }

    private func handleMTPAttempt(_ attempt: MTPInterfaceClaimer.Attempt) {
        // Only an exclusive-access refusal warrants asking the user to close
        // something. Other USB failures have their own connection errors.
        guard attempt.blockedByAnotherProcess,
              !promptedMTPLocations.contains(attempt.locationID) else { return }
        promptedMTPLocations.insert(attempt.locationID)
        mtpConflicts.append(MTPConflict(
            locationID: attempt.locationID,
            phoneName: attempt.productName ?? "your phone",
            ownerName: attempt.lostTo ?? "Another app or service",
            ownerPID: attempt.ownerPID
        ))
    }

    func dismissMTPConflict(locationID: Int) {
        mtpConflicts.removeAll { $0.locationID == locationID }
        mtpQuitError = nil
    }

    func quitMTPConflictOwner(_ conflict: MTPConflict) {
        guard let app = conflict.runningApp else {
            mtpQuitError = "That app is no longer available to quit. Close it manually if it is still running, then reconnect the phone."
            return
        }
        let name = conflict.ownerName
        if !app.terminate() {
            mtpQuitError = "Could not ask \(name) to quit. Quit it yourself, then reconnect the phone."
            return
        }
        // A polite quit lets the other app save its work. On completion the
        // phone can be reconnected, so Porter's armed claimer gets first access.
        dismissMTPConflict(locationID: conflict.locationID)
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
            if summary.isRunning && !self.summary.isRunning { previewThumbnails.cancelPending() }
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
        deviceBrowseGeneration &+= 1
        volumeLoadToken = nil
        loadingVolumesFor = nil
        volumes = []
        selectedVolumeID = nil
        invalidatePreviewThumbnails(clearCache: true)
        deviceEntries = []
        deviceSelection = []
        devicePath = .root
        deviceError = nil
        isLoadingDevice = false
        Task { await loadVolumes() }
    }

    func loadVolumes() async {
        guard let device = selectedDevice, device.readiness.isBrowsable else {
            volumes = []
            return
        }
        guard loadingVolumesFor != device.id else { return }
        deviceBrowseGeneration &+= 1
        let generation = deviceBrowseGeneration
        let token = UUID()
        volumeLoadToken = token
        loadingVolumesFor = device.id
        // Enumeration costs several device round trips, including reading
        // `mount` to see through the FUSE layer, so it needs a loading state.
        isLoadingDevice = true
        deviceError = nil
        defer {
            if volumeLoadToken == token {
                volumeLoadToken = nil
                loadingVolumesFor = nil
            }
            if deviceBrowseGeneration == generation { isLoadingDevice = false }
        }
        do {
            let transport = try await coordinator.transport(for: device.id)
            let loaded = try await transport.volumes()
            guard selectedDeviceID == device.id, deviceBrowseGeneration == generation else { return }
            volumes = loaded
            if selectedVolumeID == nil || !loaded.contains(where: { $0.id == selectedVolumeID }) {
                selectedVolumeID = loaded.first?.id
            }
            deviceError = nil
            if let root = selectedVolume?.rootPath {
                await open(devicePath: root, generation: generation)
            }
        } catch {
            if selectedDeviceID == device.id, deviceBrowseGeneration == generation {
                deviceError = describe(error)
            }
        }
    }

    func selectVolume(_ id: String) {
        selectedVolumeID = id
        guard let volume = selectedVolume else { return }
        Task { await open(devicePath: volume.rootPath) }
    }

    func open(devicePath path: RemotePath) async {
        invalidatePreviewThumbnails()
        deviceBrowseGeneration &+= 1
        await open(devicePath: path, generation: deviceBrowseGeneration)
    }

    private func open(devicePath path: RemotePath, generation: UInt64) async {
        guard let device = selectedDevice else { return }
        isLoadingDevice = true
        deviceError = nil
        defer {
            if deviceBrowseGeneration == generation { isLoadingDevice = false }
        }
        do {
            let transport = try await coordinator.transport(for: device.id)
            let entries = try await transport.list(path)
            guard selectedDeviceID == device.id, deviceBrowseGeneration == generation else { return }
            devicePath = path
            deviceEntries = sorted(entries)
            deviceSelection = []
            deviceError = nil
        } catch {
            guard selectedDeviceID == device.id, deviceBrowseGeneration == generation else { return }
            deviceError = describe(error)
            // A transient failure usually means the screen locked mid-request.
            // Drop the transport so a retry reconnects instead of reusing it.
            if (error as? TransferError)?.isTransient == true {
                await coordinator.invalidateTransport(for: device.id)
            }
        }
    }

    func refreshDevicePane() async {
        invalidatePreviewThumbnails(clearCache: true)
        let deviceID = selectedDeviceID
        let path = devicePath
        await open(devicePath: devicePath)
        if deviceError == nil, let deviceID, selectedDeviceID == deviceID, devicePath == path {
            refreshFinderFolder(for: deviceID, path: path)
        }
    }

    func deviceGoUp() {
        guard let parent = devicePath.parent,
              let root = selectedVolume?.rootPath,
              devicePath != root else { return }
        Task { await open(devicePath: parent) }
    }

    // MARK: - Local browsing

    func refreshLocalPane() {
        localEntries = sorted(LocalFile.contents(of: localDirectory, includeHidden: macView.showHiddenFiles))
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

    private func sorted(_ files: [RemoteFile]) -> [RemoteFile] {
        let visible = androidView.showHiddenFiles ? files : files.filter { !$0.isHidden }
        return visible.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return precedes(lhs.name, rhs.name, lhs.size, rhs.size, lhs.modified, rhs.modified,
                            lhs.id, rhs.id, preferences: androidView)
        }
    }

    private func sorted(_ files: [LocalFile]) -> [LocalFile] {
        files.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return precedes(lhs.name, rhs.name, lhs.size, rhs.size, lhs.modified, rhs.modified,
                            lhs.id, rhs.id, preferences: macView)
        }
    }

    private func precedes(_ lhsName: String, _ rhsName: String,
                          _ lhsSize: Int64, _ rhsSize: Int64,
                          _ lhsDate: Date?, _ rhsDate: Date?,
                          _ lhsID: String, _ rhsID: String,
                          preferences: PanePreferences) -> Bool {
        var order = lhsName.localizedStandardCompare(rhsName)
        switch preferences.sortField {
        case .name: break
        case .size:
            if lhsSize != rhsSize { order = lhsSize < rhsSize ? .orderedAscending : .orderedDescending }
        case .modified:
            let lhs = lhsDate ?? .distantPast, rhs = rhsDate ?? .distantPast
            if lhs != rhs { order = lhs < rhs ? .orderedAscending : .orderedDescending }
        }
        if order == .orderedSame { order = lhsID.compare(rhsID) }
        return order == (preferences.sortAscending ? .orderedAscending : .orderedDescending)
    }

    private func describe(_ error: any Error) -> String {
        guard let transferError = error as? TransferError else { return error.localizedDescription }
        if let suggestion = transferError.recoverySuggestion {
            return "\(transferError.errorDescription ?? "") \(suggestion)"
        }
        return transferError.errorDescription ?? error.localizedDescription
    }
}
