import PorterKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// One row, whichever side of the window it is on.
struct FileRow: Identifiable, Hashable {
    var id: String
    var name: String
    var size: Int64
    var modified: Date?
    var isDirectory: Bool
    var isHidden: Bool
    var fileExtension: String
    var localURL: URL?

    init(_ file: LocalFile) {
        self.id = file.id
        self.name = file.name
        self.size = file.size
        self.modified = file.modified
        self.isDirectory = file.isDirectory
        self.isHidden = file.isHidden
        self.fileExtension = (file.name as NSString).pathExtension.lowercased()
        self.localURL = file.url
    }

    init(_ file: RemoteFile) {
        self.id = file.id
        self.name = file.name
        self.size = file.size
        self.modified = file.modified
        self.isDirectory = file.isDirectory
        self.isHidden = file.isHidden
        self.fileExtension = file.fileExtension
        self.localURL = nil
    }

    var supportsThumbnail: Bool {
        guard let type = UTType(filenameExtension: fileExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .pdf)
            || type.conforms(to: .plainText)
            || ["doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key"].contains(fileExtension)
    }

    var symbolName: String {
        if isDirectory { return "folder.fill" }
        switch fileExtension {
        case "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "dng", "raw":
            return "photo"
        case "mp4", "mov", "mkv", "avi", "webm", "3gp":
            return "film"
        case "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus":
            return "music.note"
        case "pdf": return "doc.richtext"
        case "zip", "gz", "tar", "7z", "rar": return "doc.zipper"
        case "apk": return "shippingbox"
        case "txt", "md", "log", "json", "xml", "csv": return "doc.plaintext"
        default: return "doc"
        }
    }

    var kind: String { browserFileKind(name: name, isDirectory: isDirectory) }
}

struct FileTable: View {
    let rows: [FileRow]
    @Binding var selection: Set<String>
    @Binding var preferences: PanePreferences
    let pane: BrowserPane
    let isActive: Bool
    let onActivate: () -> Void
    let scrollAnchor: String?
    let scrollRevision: UUID
    let onScroll: (String?) -> Void
    let onOpen: (String) -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void
    let onCopyAcross: () -> Void
    let copyAcrossTitle: String
    /// Supplied by the Mac pane. Vends a file URL, so rows also drag to Finder.
    var dragProvider: ((String) -> URL?)?
    /// Supplied by the device pane. Vends the path list the Mac pane fetches.
    var remoteDragProvider: ((Set<String>) -> RemoteFileDrag?)?
    /// Lets a device drag land on a folder in the Mac pane rather than only
    /// in the directory currently being shown.
    var remoteFolderDrop: (([RemoteFileDrag], String) -> Bool)?
    /// Lets a Mac drag land on a folder in the device pane rather than only
    /// in the directory currently being shown.
    var localFolderDrop: (([URL], String) -> Bool)?
    var remoteDrop: (([RemoteFileDrag]) -> Bool)?
    var localDrop: (([URL]) -> Bool)?
    /// Fetches a device file to a temporary URL for Quick Look on demand.
    var previewProvider: ((String) async throws -> URL)?

    var thumbnailProvider: ((FileRow) async throws -> NSImage?)?
    var thumbnailRevision = ""

    @State private var previewURL: URL?
    @State private var temporaryPreviewURL: URL?
    @State private var previewTask: Task<Void, Never>?
    @State private var previewRequestID = UUID()
    @State private var isPreparingPreview = false
    @State private var previewError: String?
    @FocusState private var gridIsFocused: Bool

    var body: some View {
        Group {
            switch preferences.viewMode {
            case .list: listView
            case .grid: gridView
            }
        }
        .quickLookPreview($previewURL)
        .onChange(of: previewURL) { _, newValue in
            if newValue == nil { cleanupTemporaryPreview() }
        }
        .onDisappear {
            cancelPreviewFetch()
            cleanupTemporaryPreview()
        }
        .overlay {
            if isPreparingPreview {
                VStack(spacing: 10) {
                    ProgressView("Preparing preview…")
                    Button("Cancel") { cancelPreviewFetch() }
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .alert("Couldn’t preview file", isPresented: Binding(
            get: { previewError != nil },
            set: { if !$0 { previewError = nil } }
        )) {
            Button("OK", role: .cancel) { previewError = nil }
        } message: {
            Text(previewError ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserCommandRequested)) { notification in
            guard let request = notification.object as? BrowserCommandRequest,
                  request.pane == pane else { return }
            perform(request.command)
        }
    }

    private var listView: some View {
        NativeFileTable(rows: rows, selection: $selection, preferences: $preferences,
                        pane: pane, scrollAnchor: scrollAnchor, scrollRevision: scrollRevision,
                        onScroll: onScroll, onActivate: onActivate, onCommand: perform,
                        onOpen: open, copyAcrossTitle: copyAcrossTitle,
                        dragProvider: dragProvider, remoteDragProvider: remoteDragProvider,
                        remoteFolderDrop: remoteFolderDrop, localFolderDrop: localFolderDrop,
                        remoteDrop: remoteDrop, localDrop: localDrop)
    }

    private var gridView: some View {
        ScrollViewReader { proxy in
          GeometryReader { geometry in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(rows) { row in
                        FileRowView(row: row, style: .grid, thumbnailProvider: thumbnailProvider,
                                    thumbnailRevision: "\(thumbnailRevision):\(selection.contains(row.id))")
                            .padding(6)
                            .background {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(selection.contains(row.id)
                                        ? (isActive ? Color.accentColor : .secondary).opacity(0.22) : .clear)
                            }
                            .contentShape(.rect)
                            .onTapGesture {
                                onActivate()
                                gridIsFocused = true
                                if NSEvent.modifierFlags.contains(.command) {
                                    if selection.contains(row.id) { selection.remove(row.id) }
                                    else { selection.insert(row.id) }
                                } else { selection = [row.id] }
                            }
                            .onTapGesture(count: 2) { open(row.id) }
                            .id(row.id)
                            .background {
                                GeometryReader { cell in
                                    Color.clear.preference(key: BrowserScrollAnchors.self,
                                        value: [row.id: cell.frame(in: .named(pane.rawValue))])
                                }
                            }
                            .contextMenu { menu(for: row) }
                            .modifier(RowDragModifier(row: row, selection: selection,
                                                      dragProvider: dragProvider,
                                                      remoteDragProvider: remoteDragProvider))
                            .modifier(FolderDropModifier(
                                row: row,
                                remoteFolderDrop: remoteFolderDrop,
                                localFolderDrop: localFolderDrop
                            ))
                    }
                }
                // A split view can measure an adaptive grid at its single-column
                // ideal width. Supply the viewport width before it chooses columns.
                .frame(width: max(0, geometry.size.width - 24), alignment: .topLeading)
                .padding(12)
            }
            .coordinateSpace(name: pane.rawValue)
            .onPreferenceChange(BrowserScrollAnchors.self) { positions in
                let firstVisible = positions.filter { $0.value.maxY > 0 }
                    .min { $0.value.minY < $1.value.minY }?.key
                if firstVisible != scrollAnchor { onScroll(firstVisible) }
            }
            .onAppear { restoreGridScroll(proxy) }
            .onChange(of: scrollRevision) { _, _ in restoreGridScroll(proxy) }
            .frame(width: geometry.size.width, height: geometry.size.height)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focused($gridIsFocused)
        .onChange(of: gridIsFocused) { _, focused in if focused { onActivate() } }
        .onKeyPress(.space) {
            preview()
            return .handled
        }
        .onKeyPress(.return) {
            perform(.rename)
            return .handled
        }
    }

    private func restoreGridScroll(_ proxy: ScrollViewProxy) {
        if let id = scrollAnchor ?? rows.first?.id { proxy.scrollTo(id, anchor: .top) }
    }

    private func perform(_ command: BrowserCommand) {
        switch command {
        case .open:
            if selection.count == 1, let id = selection.first { open(id) }
        case .rename:
            if selection.count == 1, let id = selection.first { onRename(id) }
        case .quickLook: preview()
        case .delete: if !selection.isEmpty { onDelete() }
        case .copyAcross: if !selection.isEmpty { onCopyAcross() }
        case .selectAll: selection = Set(rows.map(\.id))
        case .newFolder: break
        }
    }

    @ViewBuilder
    private func menu(for row: FileRow) -> some View {
        Button("Open") { open(row.id) }
        Button(copyAcrossTitle) {
            if !selection.contains(row.id) { selection = [row.id] }
            onCopyAcross()
        }
        Divider()
        Button("Quick Look") {
            selection = [row.id]
            preview(id: row.id)
        }
        .disabled(row.isDirectory && dragProvider == nil)
        Button("Rename\u{2026}") { onRename(row.id) }
        Divider()
        Button("Delete", role: .destructive) {
            if !selection.contains(row.id) { selection = [row.id] }
            onDelete()
        }
    }

    private func preview() {
        guard selection.count == 1, let id = selection.first else { return }
        preview(id: id)
    }

    private func open(_ id: String) {
        if previewProvider != nil,
           let row = rows.first(where: { $0.id == id }),
           !row.isDirectory {
            selection = [id]
            preview(id: id)
        } else {
            onOpen(id)
        }
    }

    private func preview(id: String) {
        guard let row = rows.first(where: { $0.id == id }),
              !row.isDirectory || dragProvider != nil else { return }

        cancelPreviewFetch()
        previewURL = nil
        cleanupTemporaryPreview()
        if let url = dragProvider?(id) {
            previewURL = url
            return
        }
        guard let previewProvider else { return }
        let requestID = UUID()
        previewRequestID = requestID
        isPreparingPreview = true
        previewTask = Task {
            do {
                let url = try await previewProvider(id)
                if Task.isCancelled || previewRequestID != requestID {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                } else {
                    temporaryPreviewURL = url
                    previewURL = url
                }
            } catch is CancellationError {
                // The user canceled the fetch.
            } catch {
                if !Task.isCancelled && previewRequestID == requestID {
                    previewError = error.localizedDescription
                }
            }
            if previewRequestID == requestID {
                isPreparingPreview = false
                previewTask = nil
            }
        }
    }

    private func cancelPreviewFetch() {
        previewRequestID = UUID()
        previewTask?.cancel()
        previewTask = nil
        isPreparingPreview = false
    }

    private func cleanupTemporaryPreview() {
        guard let url = temporaryPreviewURL else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        temporaryPreviewURL = nil
    }
}

private struct BrowserScrollAnchors: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Applies the pane's drag behaviour. A modifier rather than a branch inside
/// the row view, because the two panes drag different payload types.
private struct RowDragModifier: ViewModifier {
    let row: FileRow
    let selection: Set<String>
    let dragProvider: ((String) -> URL?)?
    let remoteDragProvider: ((Set<String>) -> RemoteFileDrag?)?

    func body(content: Content) -> some View {
        if let dragProvider, let url = dragProvider(row.id) {
            content.draggable(url)
        } else if let remoteDragProvider {
            let ids = selection.contains(row.id) ? selection : [row.id]
            if let payload = remoteDragProvider(ids) {
                content.draggable(payload)
            } else {
                content
            }
        } else {
            content
        }
    }
}

/// Makes folders precise drop destinations. The enclosing pane remains a
/// destination too, so dropping into its empty space continues to copy into
/// the directory currently being viewed.
private struct FolderDropModifier: ViewModifier {
    let row: FileRow
    let remoteFolderDrop: (([RemoteFileDrag], String) -> Bool)?
    let localFolderDrop: (([URL], String) -> Bool)?
    @State private var isTargeted = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if row.isDirectory, let remoteFolderDrop {
            content
                .dropDestination(for: RemoteFileDrag.self) { payloads, _ in
                    remoteFolderDrop(payloads, row.id)
                } isTargeted: {
                    isTargeted = $0
                }
                .overlay { FolderDropHighlight(isActive: isTargeted) }
        } else if row.isDirectory, let localFolderDrop {
            content
                .dropDestination(for: URL.self) { urls, _ in
                    localFolderDrop(urls, row.id)
                } isTargeted: {
                    isTargeted = $0
                }
                .overlay { FolderDropHighlight(isActive: isTargeted) }
        } else {
            content
        }
    }
}

private struct FolderDropHighlight: View {
    let isActive: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .padding(2)
            .opacity(isActive ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: isActive)
            .allowsHitTesting(false)
    }
}

struct FileRowView: View {
    let row: FileRow
    enum Style { case list, grid }
    let style: Style
    var thumbnailProvider: ((FileRow) async throws -> NSImage?)?
    var thumbnailRevision = ""
    @State private var thumbnail: NSImage?

    var body: some View {
        switch style {
        case .list:
            HStack(spacing: 8) {
                fileIcon(size: 18)
                Text(row.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .opacity(row.isHidden ? 0.55 : 1)
                Spacer(minLength: 12)
                if !row.isDirectory {
                    Text(ByteFormat.short(row.size))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let modified = row.modified {
                    Text(modified, format: .dateTime.year().month().day())
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .frame(width: 96, alignment: .trailing)
                }
            }
            .padding(.vertical, 1)

        case .grid:
            VStack(spacing: 4) {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().scaledToFit()
                            .frame(width: 80, height: 72)
                    } else { fileIcon(size: 64).frame(height: 72) }
                }
                .task(id: "\(row.id):\(row.size):\(row.modified?.timeIntervalSince1970 ?? 0):\(thumbnailRevision)") {
                    thumbnail = nil
                    guard let thumbnailProvider else { return }
                    let image = try? await thumbnailProvider(row)
                    if !Task.isCancelled { thumbnail = image }
                }
                Text(row.name)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .opacity(row.isHidden ? 0.55 : 1)
            }
            .frame(width: 92)
        }
    }

    @ViewBuilder
    private func fileIcon(size: CGFloat) -> some View {
        if let url = row.localURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
        } else if !row.isDirectory,
                  let type = UTType(filenameExtension: row.fileExtension) {
            Image(nsImage: NSWorkspace.shared.icon(for: type))
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: row.symbolName)
                .font(.system(size: size * 0.8))
                .foregroundStyle(row.isDirectory ? Color.accentColor : .secondary)
                .frame(width: size, height: size)
        }
    }
}
