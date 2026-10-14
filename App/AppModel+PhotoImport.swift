import PorterKit

extension AppModel {
    var canImportPhotos: Bool {
        selectedDevice?.readiness.isBrowsable == true && selectedVolume != nil
            && !isLoadingDevice && !summary.isRunning && photoImportSession == nil
    }

    func presentPhotoImport() {
        guard canImportPhotos, let device = selectedDevice, let volume = selectedVolume else { return }
        previewThumbnails.cancelPending()
        photoImportSession = PhotoImportSession(device: device, volume: volume, currentFolder: devicePath,
                                               destination: localDirectory, resolver: coordinator)
    }

    func enqueuePhotoImport(_ session: PhotoImportSession) async -> Bool {
        guard let plan = session.reviewedPlan, !plan.isBlocked, !plan.items.isEmpty, !session.isWorking else { return false }
        guard devices.contains(where: { $0.id == session.device.id && $0.readiness.isBrowsable }) else {
            session.reportError("Reconnect and unlock \(session.device.displayName) before importing.")
            return false
        }
        await engine.enqueue(plan.items)
        isDrawerExpanded = true
        return true
    }
}
