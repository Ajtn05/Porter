import PorterKit
import QuickLook
import SwiftUI

/// One row, whichever side of the window it is on.
struct FileRow: Identifiable, Hashable {
    var id: String
    var name: String
    var size: Int64
    var modified: Date?
    var isDirectory: Bool
    var isHidden: Bool
    var fileExtension: String

    init(_ file: LocalFile) {
        self.id = file.id
        self.name = file.name
        self.size = file.size
        self.modified = file.modified
        self.isDirectory = file.isDirectory
        self.isHidden = file.isHidden
        self.fileExtension = (file.name as NSString).pathExtension.lowercased()
    }

    init(_ file: RemoteFile) {
        self.id = file.id
        self.name = file.name
        self.size = file.size
        self.modified = file.modified
        self.isDirectory = file.isDirectory
        self.isHidden = file.isHidden
        self.fileExtension = file.fileExtension
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
}

struct FileTable: View {
    let rows: [FileRow]
    @Binding var selection: Set<String>
    let viewMode: ViewMode
    let onOpen: (String) -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void
    let onCopyAcross: () -> Void
    let copyAcrossTitle: String
    /// Supplied by the Mac pane: a real file URL, so rows drag to Finder too.
    var dragProvider: ((String) -> URL?)?
    /// Supplied by the device pane: a path list the Mac pane knows how to fetch.
    var remoteDragProvider: ((Set<String>) -> RemoteFileDrag?)?

    @State private var previewURL: URL?

    var body: some View {
        Group {
            switch viewMode {
            case .list: listView
            case .grid: gridView
            }
        }
        .quickLookPreview($previewURL)
        .background {
            // Hidden shortcut hosts: Finder's keys work without a menu open.
            VStack {
                Button("Delete") { onDelete() }
                    .keyboardShortcut(.delete, modifiers: .command)
                Button("Copy Across") { onCopyAcross() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private var listView: some View {
        List(selection: $selection) {
            ForEach(rows) { row in
                FileRowView(row: row, style: .list)
                    .tag(row.id)
                    .contentShape(.rect)
                    .onTapGesture(count: 2) { onOpen(row.id) }
                    .contextMenu { menu(for: row) }
                    .modifier(RowDragModifier(row: row, selection: selection,
                                              dragProvider: dragProvider,
                                              remoteDragProvider: remoteDragProvider))
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .onKeyPress(.space) {
            preview()
            return .handled
        }
        .onKeyPress(.return) {
            if let single = selection.first, selection.count == 1 { onOpen(single) }
            return .handled
        }
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 12) {
                ForEach(rows) { row in
                    FileRowView(row: row, style: .grid)
                        .padding(6)
                        .background {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selection.contains(row.id) ? Color.accentColor.opacity(0.22) : .clear)
                        }
                        .contentShape(.rect)
                        .onTapGesture { selection = [row.id] }
                        .onTapGesture(count: 2) { onOpen(row.id) }
                        .contextMenu { menu(for: row) }
                        .modifier(RowDragModifier(row: row, selection: selection,
                                                  dragProvider: dragProvider,
                                                  remoteDragProvider: remoteDragProvider))
                }
            }
            .padding(12)
        }
        .onKeyPress(.space) {
            preview()
            return .handled
        }
    }

    @ViewBuilder
    private func menu(for row: FileRow) -> some View {
        Button("Open") { onOpen(row.id) }
        Button(copyAcrossTitle) {
            if !selection.contains(row.id) { selection = [row.id] }
            onCopyAcross()
        }
        Divider()
        Button("Quick Look") {
            if !selection.contains(row.id) { selection = [row.id] }
            preview()
        }
        Button("Rename\u{2026}") { onRename(row.id) }
        Divider()
        Button("Delete", role: .destructive) {
            if !selection.contains(row.id) { selection = [row.id] }
            onDelete()
        }
    }

    /// Quick Look works directly for anything already on the Mac. Device files
    /// have no local URL to preview, so the device pane leaves `dragProvider`
    /// nil and the key press does nothing rather than opening an empty window.
    private func preview() {
        guard let id = selection.first, let url = dragProvider?(id) else { return }
        previewURL = url
    }
}

/// Drag support differs per pane, so it is a modifier rather than a branch
/// inside the row view.
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

struct FileRowView: View {
    let row: FileRow
    enum Style { case list, grid }
    let style: Style

    var body: some View {
        switch style {
        case .list:
            HStack(spacing: 8) {
                Image(systemName: row.symbolName)
                    .foregroundStyle(row.isDirectory ? Color.accentColor : .secondary)
                    .frame(width: 18)
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
                Image(systemName: row.symbolName)
                    .font(.system(size: 34))
                    .foregroundStyle(row.isDirectory ? Color.accentColor : .secondary)
                    .frame(height: 42)
                Text(row.name)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .opacity(row.isHidden ? 0.55 : 1)
            }
            .frame(width: 92)
        }
    }
}
