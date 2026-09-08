import PorterKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Identifies an in-app drag of files that live on the phone. Declared in
    /// Info.plist so the drag carries a real type rather than opaque bytes.
    static let porterRemoteFiles = UTType(exportedAs: "app.porter.remote-files")
}

/// The payload for dragging device files into the Mac pane.
///
/// Only paths travel; the bytes are fetched by the transfer engine once the drop
/// lands, which is what keeps dragging a 4 GB video instant.
struct RemoteFileDrag: Codable, Transferable, Sendable {
    var deviceID: String
    var paths: [String]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .porterRemoteFiles)
    }
}

struct DualPaneBrowser: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HSplitView {
            MacPane()
                .frame(minWidth: 280)
            DevicePane()
                .frame(minWidth: 280)
        }
    }
}

// MARK: - Mac side

struct MacPane: View {
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false
    @State private var renaming: LocalFile?
    @State private var isCreatingFolder = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(
                title: "This Mac",
                icon: "laptopcomputer",
                canGoUp: model.localDirectory.path != "/",
                onGoUp: { model.localGoUp() },
                trailing: { AnyView(EmptyView()) }
            )

            LocalBreadcrumbBar(directory: model.localDirectory) { model.open(localDirectory: $0) }

            FileTable(
                rows: model.localEntries.map(FileRow.init),
                selection: Binding(get: { model.localSelection }, set: { model.localSelection = $0 }),
                viewMode: model.viewMode,
                onOpen: { id in
                    guard let file = model.localEntries.first(where: { $0.id == id }) else { return }
                    if file.isDirectory { model.open(localDirectory: file.url) }
                    else { NSWorkspace.shared.open(file.url) }
                },
                onRename: { id in renaming = model.localEntries.first { $0.id == id } },
                onDelete: { model.trashSelectedOnMac() },
                onCopyAcross: { model.copySelectionToDevice() },
                copyAcrossTitle: "Copy to Device",
                dragProvider: { id in
                    model.localEntries.first { $0.id == id }?.url
                }
            )
            .dropDestination(for: RemoteFileDrag.self) { payload, _ in
                guard let drag = payload.first,
                      let device = model.devices.first(where: { $0.id.rawValue == drag.deviceID }) else { return false }
                let files = model.deviceEntries.filter { drag.paths.contains($0.path.string) }
                model.copyToMac(files, from: device, into: model.localDirectory)
                return true
            } isTargeted: { isTargeted = $0 }
            .overlay { DropHighlight(isActive: isTargeted) }
        }
        .background(.background)
        .onReceive(NotificationCenter.default.publisher(for: .newFolderRequested)) { _ in
            isCreatingFolder = true
        }
        .sheet(item: $renaming) { file in
            RenameSheet(currentName: file.name) { model.renameOnMac(file, to: $0) }
        }
        .sheet(isPresented: $isCreatingFolder) {
            RenameSheet(title: "New Folder", currentName: "untitled folder", confirmTitle: "Create") {
                model.createFolderOnMac(named: $0)
            }
        }
    }
}

// MARK: - Device side

struct DevicePane: View {
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false
    @State private var renaming: RemoteFile?
    @State private var isConfirmingDelete = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(
                title: model.selectedDevice?.displayName ?? "Device",
                icon: "iphone",
                canGoUp: model.devicePath != model.selectedVolume?.rootPath,
                onGoUp: { model.deviceGoUp() },
                trailing: {
                    AnyView(
                        Group {
                            if model.isLoadingDevice {
                                ProgressView().controlSize(.small)
                            }
                        }
                    )
                }
            )

            RemoteBreadcrumbBar(
                path: model.devicePath,
                root: model.selectedVolume?.rootPath ?? .root,
                rootLabel: model.selectedVolume?.displayName ?? "Device"
            ) { path in
                Task { await model.open(devicePath: path) }
            }

            if let error = model.deviceError {
                InlineErrorBanner(message: error) {
                    Task { await model.refreshDevicePane() }
                }
            }

            FileTable(
                rows: model.deviceEntries.map(FileRow.init),
                selection: Binding(get: { model.deviceSelection }, set: { model.deviceSelection = $0 }),
                viewMode: model.viewMode,
                onOpen: { id in
                    guard let file = model.deviceEntries.first(where: { $0.id == id }), file.isDirectory else { return }
                    Task { await model.open(devicePath: file.path) }
                },
                onRename: { id in renaming = model.deviceEntries.first { $0.id == id } },
                onDelete: { isConfirmingDelete = true },
                onCopyAcross: { model.copySelectionToMac() },
                copyAcrossTitle: "Copy to Mac",
                remoteDragProvider: { ids in
                    guard let deviceID = model.selectedDeviceID else { return nil }
                    return RemoteFileDrag(deviceID: deviceID.rawValue, paths: Array(ids))
                }
            )
            .dropDestination(for: URL.self) { urls, _ in
                model.copyToDevice(urls, into: model.devicePath)
                return true
            } isTargeted: { isTargeted = $0 }
            .overlay { DropHighlight(isActive: isTargeted) }
        }
        .background(.background)
        .sheet(item: $renaming) { file in
            RenameSheet(currentName: file.name) { model.renameOnDevice(file, to: $0) }
        }
        .confirmationDialog(
            "Delete \(model.deviceSelectionDescription)?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { model.deleteSelectedOnDevice() }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Android has no Trash we can put things in, so this really is final.
            Text("This cannot be undone. Deleted files do not go to a Trash on the phone.")
        }
    }
}

// MARK: - Shared chrome

struct PaneHeader: View {
    let title: String
    let icon: String
    let canGoUp: Bool
    let onGoUp: () -> Void
    let trailing: () -> AnyView

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onGoUp) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(!canGoUp)
            .help("Go to enclosing folder")

            Label(title, systemImage: icon)
                .font(.headline)
                .lineLimit(1)

            Spacer()
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct DropHighlight: View {
    let isActive: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .padding(4)
            .opacity(isActive ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: isActive)
            .allowsHitTesting(false)
    }
}

struct InlineErrorBanner: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Retry", action: onRetry)
                .buttonStyle(.link)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }
}
