import AppKit
import PorterKit
import SwiftUI
import UniformTypeIdentifiers

/// AppKit supplies column resizing, range selection, type selection, and
/// responder focus consistently with other macOS file browsers.
struct NativeFileTable: NSViewRepresentable {
    let rows: [FileRow]
    @Binding var selection: Set<String>
    @Binding var preferences: PanePreferences
    let pane: BrowserPane
    let scrollAnchor: String?
    let scrollRevision: UUID
    let onScroll: (String?) -> Void
    let onActivate: () -> Void
    let onCommand: (BrowserCommand) -> Void
    let onOpen: (String) -> Void
    let copyAcrossTitle: String
    var dragProvider: ((String) -> URL?)?
    var remoteDragProvider: ((Set<String>) -> RemoteFileDrag?)?
    var remoteFolderDrop: (([RemoteFileDrag], String) -> Bool)?
    var localFolderDrop: (([URL], String) -> Bool)?
    var remoteDrop: (([RemoteFileDrag]) -> Bool)?
    var localDrop: (([URL]) -> Bool)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.isUpdating = true
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let table = BrowserTableView()
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.rowHeight = 26
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.style = .inset
        table.focusRingType = .none
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openClickedRow(_:))
        table.onActivate = { context.coordinator.parent.onActivate() }
        table.onCommand = { context.coordinator.parent.onCommand($0) }
        table.menuProvider = { context.coordinator.menu(for: $0) }
        table.setAccessibilityLabel(pane == .mac ? "Mac files" : "Android files")

        for field in [SortField.name, .modified, .size, .kind] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(field.rawValue))
            column.title = field.title
            column.minWidth = field == .name ? 120 : 70
            column.maxWidth = 1200
            let fallback: Double = field == .name ? 220 : (field == .size ? 90 : 150)
            column.width = max(column.minWidth, min(column.maxWidth,
                CGFloat(preferences.columnWidths[field.rawValue] ?? fallback)))
            column.resizingMask = .userResizingMask
            column.sortDescriptorPrototype = NSSortDescriptor(key: field.rawValue, ascending: true)
            table.addTableColumn(column)
        }
        table.registerForDraggedTypes([.fileURL, Coordinator.remoteType])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.frame = NSRect(x: 0, y: 0,
            width: table.tableColumns.reduce(0) { $0 + $1.width + table.intercellSpacing.width }, height: 0)
        scroll.documentView = table
        context.coordinator.table = table
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator,
            selector: #selector(Coordinator.scrolled(_:)),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        context.coordinator.isUpdating = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? BrowserTableView else { return }
        let coordinator = context.coordinator
        let restore = coordinator.lastScrollRevision != scrollRevision
        let oldAnchor = coordinator.visibleAnchor()
        let rowsChanged = coordinator.parent.rows != rows || coordinator.lastScrollRevision == nil
        coordinator.isUpdating = true
        coordinator.parent = self
        if rowsChanged { table.reloadData() }
        let indexes = IndexSet(rows.indices.filter { selection.contains(rows[$0].id) })
        if table.selectedRowIndexes != indexes { table.selectRowIndexes(indexes, byExtendingSelection: false) }
        let sort = NSSortDescriptor(key: preferences.sortField.rawValue, ascending: preferences.sortAscending)
        if table.sortDescriptors != [sort] { table.sortDescriptors = [sort] }
        coordinator.lastScrollRevision = scrollRevision
        coordinator.isUpdating = false

        if restore || rowsChanged {
            let anchor = restore ? scrollAnchor : oldAnchor
            let revision = scrollRevision
            let token = UUID()
            coordinator.scrollToken = token
            coordinator.isRestoringScroll = true
            Task { @MainActor [weak coordinator] in
                await Task.yield()
                guard let coordinator, coordinator.parent.scrollRevision == revision,
                      coordinator.scrollToken == token else { return }
                coordinator.restoreScroll(anchor)
                coordinator.isRestoringScroll = false
            }
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        coordinator.table?.delegate = nil
        coordinator.table?.dataSource = nil
        coordinator.table?.onActivate = nil
        coordinator.table?.onCommand = nil
        coordinator.table?.menuProvider = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        static let remoteType = NSPasteboard.PasteboardType("app.porter.remote-files")
        var parent: NativeFileTable
        weak var table: BrowserTableView?
        var isUpdating = false
        var lastScrollRevision: UUID?
        var scrollToken = UUID()
        var isRestoringScroll = false

        init(_ parent: NativeFileTable) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard parent.rows.indices.contains(row), let tableColumn else { return nil }
            let file = parent.rows[row]
            let identifier = tableColumn.identifier
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
                ?? makeCell(identifier: identifier, includesIcon: identifier.rawValue == "name")
            guard let label = cell.textField else { return cell }
            label.textColor = identifier.rawValue == "name" ? .labelColor : .secondaryLabelColor
            cell.alphaValue = file.isHidden ? 0.55 : 1
            switch SortField(rawValue: identifier.rawValue) {
            case .name:
                label.stringValue = file.name
                if let url = file.localURL { cell.imageView?.image = NSWorkspace.shared.icon(forFile: url.path) }
                else if file.isDirectory { cell.imageView?.image = NSWorkspace.shared.icon(for: .folder) }
                else if let type = UTType(filenameExtension: file.fileExtension) {
                    cell.imageView?.image = NSWorkspace.shared.icon(for: type)
                } else { cell.imageView?.image = NSWorkspace.shared.icon(for: .data) }
            case .modified:
                label.stringValue = file.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—"
            case .size:
                label.stringValue = file.isDirectory ? "—" : ByteFormat.short(file.size)
                label.alignment = .right
                label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            case .kind: label.stringValue = file.kind
            case nil: return nil
            }
            label.toolTip = label.stringValue
            return cell
        }

        private func makeCell(identifier: NSUserInterfaceItemIdentifier, includesIcon: Bool) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = includesIcon ? .byTruncatingMiddle : .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4)
            ])
            if includesIcon {
                let icon = NSImageView()
                icon.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(icon)
                cell.imageView = icon
                NSLayoutConstraint.activate([
                    icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: 18),
                    icon.heightAnchor.constraint(equalToConstant: 18),
                    label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6)
                ])
            } else { label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4).isActive = true }
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdating, let table else { return }
            parent.onActivate()
            parent.selection = Set(table.selectedRowIndexes.compactMap {
                parent.rows.indices.contains($0) ? parent.rows[$0].id : nil
            })
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isUpdating, let sort = tableView.sortDescriptors.first,
                  let key = sort.key, let field = SortField(rawValue: key) else { return }
            parent.onActivate()
            var preferences = parent.preferences
            preferences.sortField = field
            preferences.sortAscending = sort.ascending
            parent.preferences = preferences
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard !isUpdating, let table else { return }
            var preferences = parent.preferences
            for column in table.tableColumns { preferences.columnWidths[column.identifier.rawValue] = column.width }
            if preferences != parent.preferences { parent.preferences = preferences }
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            parent.rows.indices.contains(row) ? parent.rows[row].name : nil
        }

        @objc func openClickedRow(_ sender: NSTableView) {
            guard parent.rows.indices.contains(sender.clickedRow) else { return }
            parent.onActivate()
            parent.onOpen(parent.rows[sender.clickedRow].id)
        }

        func menu(for row: Int) -> NSMenu? {
            guard parent.rows.indices.contains(row), let table else { return nil }
            parent.onActivate()
            if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            let menu = NSMenu()
            let actions: [(String, Int)] = [("Open", 0), (parent.copyAcrossTitle, 1), ("Quick Look", 2), ("Rename…", 3)]
            for (title, tag) in actions {
                let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
                item.target = self
                item.tag = tag
                item.representedObject = parent.rows[row].id
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let delete = NSMenuItem(title: parent.pane == .mac ? "Move to Trash" : "Delete…",
                                    action: #selector(menuAction(_:)), keyEquivalent: "")
            delete.target = self
            delete.tag = 4
            menu.addItem(delete)
            return menu
        }

        @objc private func menuAction(_ item: NSMenuItem) {
            switch item.tag {
            case 0: if let id = item.representedObject as? String { parent.onOpen(id) }
            case 1: parent.onCommand(.copyAcross)
            case 2:
                if let id = item.representedObject as? String { parent.selection = [id] }
                parent.onCommand(.quickLook)
            case 3:
                if let id = item.representedObject as? String { parent.selection = [id] }
                parent.onCommand(.rename)
            case 4: parent.onCommand(.delete)
            default: break
            }
        }

        func visibleAnchor() -> String? {
            guard let table else { return nil }
            let range = table.rows(in: table.visibleRect)
            guard range.location != NSNotFound, parent.rows.indices.contains(range.location) else { return nil }
            return parent.rows[range.location].id
        }

        @objc func scrolled(_ notification: Notification) {
            guard !isUpdating, !isRestoringScroll else { return }
            let anchor = visibleAnchor()
            if anchor != parent.scrollAnchor { parent.onScroll(anchor) }
        }

        func restoreScroll(_ anchor: String?) {
            guard let table, let clip = table.enclosingScrollView?.contentView else { return }
            isUpdating = true
            let index = anchor.flatMap { id in parent.rows.firstIndex { $0.id == id } } ?? 0
            let y = parent.rows.isEmpty ? 0 : table.rect(ofRow: index).minY
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
            table.enclosingScrollView?.reflectScrolledClipView(clip)
            isUpdating = false
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard parent.rows.indices.contains(row) else { return nil }
            let file = parent.rows[row]
            if let url = parent.dragProvider?(file.id) { return url as NSURL }
            let ids = tableView.selectedRowIndexes.contains(row) ? parent.selection : [file.id]
            // One payload carries the entire remote selection; additional
            // pasteboard items would make a multi-row drop fetch it repeatedly.
            if tableView.selectedRowIndexes.contains(row), row != tableView.selectedRowIndexes.first { return nil }
            guard let payload = parent.remoteDragProvider?(ids), let data = try? JSONEncoder().encode(payload) else { return nil }
            let item = NSPasteboardItem()
            item.setData(data, forType: Self.remoteType)
            return item
        }

        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard accepts(info.draggingPasteboard) else { return [] }
            if operation == .on, parent.rows.indices.contains(row), parent.rows[row].isDirectory {
                tableView.setDropRow(row, dropOperation: .on)
            } else { tableView.setDropRow(-1, dropOperation: .on) }
            return .copy
        }

        private func accepts(_ pasteboard: NSPasteboard) -> Bool {
            if pasteboard.availableType(from: [Self.remoteType]) != nil { return parent.remoteDrop != nil }
            return parent.localDrop != nil && pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            parent.onActivate()
            let folder = parent.rows.indices.contains(row) && parent.rows[row].isDirectory ? parent.rows[row].id : nil
            let pasteboard = info.draggingPasteboard
            if let data = pasteboard.data(forType: Self.remoteType),
               let payload = try? JSONDecoder().decode(RemoteFileDrag.self, from: data) {
                if let folder { return parent.remoteFolderDrop?([payload], folder) ?? false }
                return parent.remoteDrop?([payload]) ?? false
            }
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            guard !urls.isEmpty else { return false }
            if let folder { return parent.localFolderDrop?(urls, folder) ?? false }
            return parent.localDrop?(urls) ?? false
        }
    }
}

@MainActor
final class BrowserTableView: NSTableView {
    var onActivate: (() -> Void)?
    var onCommand: ((BrowserCommand) -> Void)?
    var menuProvider: ((Int) -> NSMenu?)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onActivate?() }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onActivate?()
        return menuProvider?(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty, event.keyCode == 36 { onCommand?(.rename) }
        else if modifiers.isEmpty, event.keyCode == 49 { onCommand?(.quickLook) }
        else { super.keyDown(with: event) }
    }
}
