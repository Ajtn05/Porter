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
    }
}

struct BrowserToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItemGroup {
            Picker("View", selection: Binding(get: { model.viewMode }, set: { model.viewMode = $0 })) {
                Image(systemName: "list.bullet").tag(ViewMode.list)
                Image(systemName: "square.grid.2x2").tag(ViewMode.grid)
            }
            .pickerStyle(.segmented)
            .help("Switch between list and icon view")

            Menu {
                Picker("Sort By", selection: Binding(get: { model.sortField }, set: { model.sortField = $0 })) {
                    ForEach(SortField.allCases) { field in
                        Text(field.title).tag(field)
                    }
                }
                Divider()
                Toggle("Ascending", isOn: Binding(get: { model.sortAscending }, set: { model.sortAscending = $0 }))
                Toggle("Show Hidden Files", isOn: Binding(
                    get: { model.showHiddenFiles }, set: { model.showHiddenFiles = $0 }
                ))
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }

            Button {
                Task { await model.refreshBothPanes() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh both panes")
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
