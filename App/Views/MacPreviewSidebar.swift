import PorterKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct MacPreviewSidebar: View {
    @Environment(AppModel.self) private var model
    @State private var image: NSImage?
    @State private var isLoading = false
    @State private var error: String?
    @State private var quickLookURL: URL?

    private var selected: [LocalFile] {
        model.localEntries.filter { model.localSelection.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Preview").font(.headline).foregroundStyle(.secondary)
                if selected.count == 1, let file = selected.first {
                    preview(file)
                    Text(file.name).font(.headline).textSelection(.enabled)
                    Divider()
                    detail("Kind", file.isDirectory ? "Folder" :
                           (UTType(filenameExtension: file.url.pathExtension)?.localizedDescription ?? "File"))
                    if !file.isDirectory { detail("Size", ByteFormat.short(file.size)) }
                    if let date = file.modified {
                        detail("Modified", date.formatted(date: .abbreviated, time: .shortened))
                    }
                    detail("Where", file.url.deletingLastPathComponent().path)
                    Button("Quick Look") { quickLookURL = file.url }
                        .frame(maxWidth: .infinity)
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
                    Text("Select a file to see its preview and details.").foregroundStyle(.secondary)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.bar)
        .quickLookPreview($quickLookURL)
        .onChange(of: selected) { _, _ in quickLookURL = nil }
        .task(id: selected) {
            image = nil
            error = nil
            isLoading = false
            guard selected.count == 1, let file = selected.first,
                  !file.isDirectory, FileRow(file).supportsThumbnail else { return }
            isLoading = true
            do {
                let thumbnail = try await model.thumbnail(for: FileRow(file), isIcon: false)
                if !Task.isCancelled { image = thumbnail }
            } catch {
                if !Task.isCancelled && !(error is CancellationError) { self.error = error.localizedDescription }
            }
            if !Task.isCancelled { isLoading = false }
        }
        .onDisappear { quickLookURL = nil }
    }

    @ViewBuilder
    private func preview(_ file: LocalFile) -> some View {
        if let image {
            Image(nsImage: image).resizable().scaledToFit()
                .frame(maxWidth: .infinity).frame(height: 200)
                .accessibilityLabel("Preview of \(file.name)")
        } else if isLoading {
            ProgressView("Loading preview…").frame(maxWidth: .infinity).frame(height: 160)
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                .resizable().scaledToFit()
                .frame(maxWidth: .infinity).frame(height: 140)
            if !file.isDirectory {
                Text("Use Quick Look for a full preview.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled)
        }
    }
}
