import PorterKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Finder-style selection preview, confined to the Android pane.
struct AndroidPreviewSidebar: View {
    @Environment(AppModel.self) private var model
    @State private var image: NSImage?
    @State private var isLoading = false
    @State private var error: String?
    @State private var quickLookURL: URL?
    @State private var temporaryURL: URL?
    @State private var quickLookTask: Task<Void, Never>?
    @State private var quickLookRequest = UUID()
    @State private var isOpeningQuickLook = false

    private var selected: [RemoteFile] {
        model.deviceEntries.filter { model.deviceSelection.contains($0.id) }
    }

    private var selectionRevision: String {
        "\(model.selectedDeviceID?.rawValue ?? ""): \(selected.first?.id ?? ""): \(selected.count): \(model.previewGeneration)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Preview").font(.headline).foregroundStyle(.secondary)
                if selected.count == 1, let file = selected.first {
                    preview(file)
                    Text(file.name).font(.headline).textSelection(.enabled)
                    Divider()
                    detail("Kind", file.isDirectory ? "Folder" : (UTType(filenameExtension: file.fileExtension)?.localizedDescription ?? "File"))
                    if !file.isDirectory { detail("Size", ByteFormat.short(file.size)) }
                    if let date = file.modified {
                        detail("Modified", date.formatted(date: .abbreviated, time: .shortened))
                    }
                    detail("Where", file.path.parent?.string ?? "/")
                    if !file.isDirectory {
                        Button(isOpeningQuickLook ? "Cancel Quick Look" : "Quick Look") {
                            if isOpeningQuickLook { cancelQuickLook() }
                            else { openQuickLook(file) }
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else if selected.count > 1 {
                    Image(systemName: "doc.on.doc").font(.system(size: 56)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 30)
                    Text("\(selected.count) items selected").font(.headline)
                    detail("Files", "\(selected.filter { !$0.isDirectory }.count)")
                    detail("Folders", "\(selected.filter(\.isDirectory).count)")
                    detail("File size", ByteFormat.short(selected.filter { !$0.isDirectory }.reduce(0) { $0 + $1.size }))
                } else {
                    Image(systemName: "doc.viewfinder").font(.system(size: 56)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity).padding(.vertical, 30)
                    Text("Select a file to see its preview and details.")
                        .foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.bar)
        .quickLookPreview($quickLookURL)
        .onChange(of: quickLookURL) { _, url in if url == nil { removeTemporaryPreview() } }
        .onChange(of: selectionRevision) { _, _ in
            cancelQuickLook()
            quickLookURL = nil
            removeTemporaryPreview()
        }
        .task(id: "\(selectionRevision):\(model.summary.isRunning):\(model.isLoadingDevice)") {
            image = nil
            error = nil
            isLoading = false
            guard selected.count == 1, let file = selected.first, !file.isDirectory,
                  FileRow(file).supportsThumbnail,
                  (model.selectedDevice?.transport == .mtp ||
                   (file.size > 0 && file.size <= PreviewThumbnailStore.automaticFileLimit)),
                  !model.summary.isRunning, !model.isLoadingDevice else { return }
            isLoading = true
            do {
                let thumbnail = try await model.thumbnail(for: FileRow(file), isIcon: false)
                guard !Task.isCancelled else { return }
                image = thumbnail
            } catch {
                if !Task.isCancelled && !(error is CancellationError) { self.error = error.localizedDescription }
            }
            if !Task.isCancelled { isLoading = false }
        }
        .onDisappear {
            cancelQuickLook()
            quickLookURL = nil
            removeTemporaryPreview()
        }
    }

    @ViewBuilder
    private func preview(_ file: RemoteFile) -> some View {
        if let image {
            Image(nsImage: image).resizable().scaledToFit()
                .frame(maxWidth: .infinity).frame(height: 200)
                .accessibilityLabel("Preview of \(file.name)")
        } else if isLoading {
            ProgressView("Loading preview…").frame(maxWidth: .infinity).frame(height: 160)
        } else {
            Image(systemName: FileRow(file).symbolName).font(.system(size: 64))
                .foregroundStyle(file.isDirectory ? Color.accentColor : .secondary)
                .frame(maxWidth: .infinity).frame(height: 140)
            if !file.isDirectory {
                Text(model.summary.isRunning ? "Automatic previews pause during transfers." :
                     file.size > PreviewThumbnailStore.automaticFileLimit ? "Use Quick Look to preview this larger file." :
                     "Use Quick Look for a full preview.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled)
        }
    }

    private func openQuickLook(_ file: RemoteFile) {
        cancelQuickLook()
        quickLookURL = nil
        removeTemporaryPreview()
        let request = UUID()
        quickLookRequest = request
        isOpeningQuickLook = true
        error = nil
        quickLookTask = Task {
            do {
                let url = try await model.preparePreview(for: file.id)
                if Task.isCancelled || request != quickLookRequest {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                } else {
                    temporaryURL = url
                    quickLookURL = url
                }
            } catch {
                if !Task.isCancelled && request == quickLookRequest { self.error = error.localizedDescription }
            }
            if request == quickLookRequest {
                isOpeningQuickLook = false
                quickLookTask = nil
            }
        }
    }

    private func cancelQuickLook() {
        quickLookRequest = UUID()
        quickLookTask?.cancel()
        quickLookTask = nil
        isOpeningQuickLook = false
    }

    private func removeTemporaryPreview() {
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL.deletingLastPathComponent()) }
        temporaryURL = nil
    }
}
