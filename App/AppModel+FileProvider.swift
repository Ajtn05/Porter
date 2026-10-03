import FileProvider
import PorterKit

extension AppModel {
    /// Registers the selected phone as a Finder domain. The extension remains
    /// read-only until the Finder surface has earned a full transport matrix.
    func showSelectedDeviceInFinder() {
        guard let device = selectedDevice, device.readiness.isBrowsable else { return }
        let identifier = PorterFileProviderDomainRegistry.register(deviceID: device.id.rawValue)
        guard PorterFileProviderDomainRegistry.deviceID(for: identifier) == device.id.rawValue,
              PorterFileProviderFileBridge.directories() != nil else {
            finderDomainMessage = "Finder access needs a signed Porter build with its App Group enabled."
            return
        }
        let name = device.displayName
        NSFileProviderManager.getDomainsWithCompletionHandler { [weak self] domains, lookupError in
            if let lookupError {
                Task { @MainActor in self?.finderDomainMessage = lookupError.localizedDescription }
                return
            }
            let domain = NSFileProviderDomain(
                identifier: NSFileProviderDomainIdentifier(rawValue: identifier),
                displayName: name
            )
            if domains.contains(where: { $0.identifier == domain.identifier }) {
                Task { @MainActor in
                    self?.finderDomainMessage = "\(name) is already available in Finder for browsing and copying from the phone. Keep Porter open while you use it."
                }
                return
            }
            NSFileProviderManager.add(domain) { [weak self] error in
                Task { @MainActor in
                    if let error {
                        self?.finderDomainMessage = error.localizedDescription
                    } else {
                        self?.finderDomainMessage = "\(name) is now available in Finder for browsing and copying from the phone. Keep Porter open while you use it."
                    }
                }
            }
        }
    }

    /// Reimport the folder Porter just refreshed, including changes made on
    /// the phone outside Porter. Finder may already have a materialized copy.
    func refreshFinderFolder(for deviceID: DeviceID, path: RemotePath) {
        let identifier = PorterFileProviderDomainRegistry.identifier(for: deviceID.rawValue)
        guard PorterFileProviderDomainRegistry.deviceID(for: identifier) == deviceID.rawValue else {
            return
        }
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: identifier),
            displayName: "Porter"
        )
        guard let manager = NSFileProviderManager(for: domain) else { return }
        let itemIdentifier = path == .root
            ? NSFileProviderItemIdentifier.rootContainer
            : PorterFileProviderItemIdentifier.item(for: path.string)
        manager.reimportItems(below: itemIdentifier) { error in
            guard error == nil else { return }
            let domain = NSFileProviderDomain(
                identifier: NSFileProviderDomainIdentifier(rawValue: identifier),
                displayName: "Porter"
            )
            NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet) { _ in }
        }
    }
}
