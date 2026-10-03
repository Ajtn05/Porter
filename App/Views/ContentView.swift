import PorterKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            DeviceSidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if let device = model.selectedDevice, device.readiness.isBrowsable {
                    DualPaneBrowser()
                } else {
                    ConnectionGuideView(device: model.selectedDevice)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                TransferDrawer()
            }
            .toolbar { BrowserToolbar() }
        }
        .sheet(item: $model.pendingConflict) { conflict in
            ConflictSheet(conflict: conflict)
        }
        .sheet(isPresented: $model.showWarnings) {
            WarningsSheet(warnings: model.planWarnings)
        }
        .alert(
            "Finder",
            isPresented: Binding(
                get: { model.finderDomainMessage != nil },
                set: { if !$0 { model.finderDomainMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.finderDomainMessage = nil }
        } message: {
            Text(model.finderDomainMessage ?? "")
        }
        .sheet(item: Binding(
            get: { model.currentMTPConflict },
            set: { if $0 == nil, let current = model.currentMTPConflict {
                model.dismissMTPConflict(locationID: current.locationID)
            } }
        )) { conflict in
            MTPConflictSheet(conflict: conflict)
        }
    }
}

private struct MTPConflictSheet: View {
    @Environment(AppModel.self) private var model
    let conflict: MTPConflict

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("MTP connection in use", systemImage: "cable.connector")
                .font(.title2.bold())

            if conflict.isSystemOwner {
                Text("macOS opened \(conflict.phoneName) for camera import before Porter could claim MTP. Keep Porter running, then unplug and reconnect the phone. macOS does not let Porter close this system service.")
            } else if conflict.runningApp != nil {
                Text("\(conflict.ownerName) is using \(conflict.phoneName)'s MTP connection. Ask it to quit, then unplug and reconnect the phone so Porter can claim MTP first.")
            } else {
                Text("\(conflict.ownerName) is using \(conflict.phoneName)'s MTP connection. Close that service, then unplug and reconnect the phone so Porter can claim MTP first.")
            }

            if let error = model.mtpQuitError {
                Text(error).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Later") { model.dismissMTPConflict(locationID: conflict.locationID) }
                if conflict.runningApp != nil {
                    Button("Quit \(conflict.ownerName)") {
                        model.quitMTPConflictOwner(conflict)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

struct BrowserToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                Task { await model.refreshBothPanes() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh both panes")

            Button {
                model.showSelectedDeviceInFinder()
            } label: {
                Label("Add to Finder", systemImage: "folder.badge.plus")
            }
            .disabled(model.selectedDevice?.readiness.isBrowsable != true)
            .help("Make this phone available in Finder")
        }
    }
}

struct DeviceSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: Binding(
            get: { model.selectedDeviceID },
            set: { if let id = $0 { model.selectDevice(id) } }
        )) {
            Section("Devices") {
                if model.devices.isEmpty {
                    Text("No device connected")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(model.devices) { device in
                    DeviceRow(device: device)
                        .tag(device.id)
                }
            }

            if let device = model.selectedDevice, device.readiness.isBrowsable, !model.volumes.isEmpty {
                Section("Storage") {
                    ForEach(model.volumes) { volume in
                        VolumeRow(volume: volume, isSelected: volume.id == model.selectedVolumeID)
                            .contentShape(.rect)
                            .onTapGesture { model.selectVolume(volume.id) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct DeviceRow: View {
    let device: Device

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: device.readiness.isBrowsable ? "iphone" : "iphone.slash")
                .foregroundStyle(device.readiness.isBrowsable ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.displayName)
                    .lineLimit(1)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusText: String {
        switch device.readiness {
        case .ready: return device.transport.displayName
        case .chargingOnly: return "Charging only"
        case .unauthorized: return "Waiting for you to allow access"
        case .locked: return "Locked"
        case .offline: return "Not responding"
        }
    }
}

struct VolumeRow: View {
    let volume: StorageVolume
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: volume.isRemovable ? "sdcard" : "internaldrive")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(volume.displayName).lineLimit(1)
                if let free = volume.freeBytes, let total = volume.totalBytes {
                    Text("\(ByteFormat.short(free)) free of \(ByteFormat.short(total))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
