import Foundation
import PorterKit
import Security

/// Persists the non-secret address book for paired Wi-Fi phones.
///
/// A phone's bearer token never enters the JSON preferences file. It stays in
/// the user's login Keychain, keyed by the fingerprint-derived device ID, so a
/// copied preferences file cannot grant access to a phone on the local network.
actor WiFiDeviceRegistry {
    private struct Record: Codable, Sendable {
        var id: DeviceID
        var name: String
        var host: String
        var port: Int
        var certificateFingerprint: String
    }

    private static let preferencesKey = "paired-wifi-devices-v1"
    private var records: [DeviceID: Record]

    init() {
        let data = UserDefaults.standard.data(forKey: Self.preferencesKey)
        let saved = data.flatMap { try? JSONDecoder().decode([Record].self, from: $0) } ?? []
        records = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
    }

    func wirelessDevices() -> [DeviceMerge.WirelessDevice] {
        records.values.compactMap { record in
            guard WiFiKeychain.token(for: record.id) != nil else { return nil }
            return DeviceMerge.WirelessDevice(id: record.id, name: record.name, host: record.host)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func connection(for deviceID: DeviceID) -> WiFiConnection? {
        guard let record = records[deviceID],
              let token = WiFiKeychain.token(for: deviceID) else { return nil }
        return WiFiConnection(
            host: record.host,
            port: record.port,
            credentials: WiFiCredentials(token: token, certificateFingerprint: record.certificateFingerprint)
        )
    }

    @discardableResult
    func savePairing(host: String, result: WiFiPairingResult) throws -> DeviceID {
        let fingerprint = result.credentials.certificateFingerprint ?? ""
        guard let token = result.credentials.token, fingerprint.count == 64 else {
            throw TransferError.pairingFailed("the phone returned incomplete pairing credentials")
        }

        // The certificate persists on the phone, which makes this ID stable
        // across DHCP address changes without relying on restricted hardware
        // serial-number APIs on Android.
        let id = DeviceID("wifi-\(fingerprint.prefix(24))")
        try WiFiKeychain.save(token: token, for: id)
        records[id] = Record(
            id: id,
            name: result.deviceName.isEmpty ? "Android phone" : result.deviceName,
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: 53317,
            certificateFingerprint: fingerprint.lowercased()
        )
        persist()
        return id
    }

    private func persist() {
        let values = records.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        UserDefaults.standard.set(try? JSONEncoder().encode(values), forKey: Self.preferencesKey)
    }
}

/// The small Keychain surface the pairing registry needs.
private enum WiFiKeychain {
    private static let service = "app.porter.wifi"

    static func token(for deviceID: DeviceID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceID.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(token: String, for deviceID: DeviceID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceID.rawValue
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw TransferError.pairingFailed("the Mac Keychain could not save this phone's pairing token")
        }
    }
}
