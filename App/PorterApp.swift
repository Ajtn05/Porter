import PorterKit
import SwiftUI

@main
struct PorterApp: App {
    @State private var model = AppModel()
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    var body: some Scene {
        Window("Porter", id: "main") {
            ContentView()
                .environment(model)
                .task { model.start() }
                // Height only. A minWidth here lands on the split view's
                // detail column rather than on the window, so the sidebar's
                // width is added on top of it and the total always exceeds the
                // window by however wide the sidebar is. The width minimum
                // belongs to the columns themselves: the sidebar declares it in
                // ContentView, and each pane in DualPaneBrowser.
                .frame(minHeight: 540)
        }
        // The column minimums are only a hint until this is set. A Window scene
        // defaults to .automatic resizability, which lets the window be dragged
        // narrower than its content needs, and SwiftUI then centres and clips
        // rather than compressing: the sidebar slides off the left edge while
        // the transfer drawer's buttons run off the right.
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1180, height: 720)
        .windowToolbarStyle(.unified)
        .commands { PorterCommands(model: model) }

        // Reports transfer progress while the main window is closed.
        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarContent()
                .environment(model)
        } label: {
            MenuBarLabel(summary: model.summary)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// Menu commands, keyed to match Finder's shortcuts.
struct PorterCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Folder") { NotificationCenter.default.post(name: .newFolderRequested, object: nil) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .toolbar) {
            Menu("This Mac") {
                PaneViewMenu(preferences: Binding(get: { model.macView }, set: { model.macView = $0 }))
                Toggle("Show Preview", isOn: Binding(get: { model.showMacPreview }, set: { model.showMacPreview = $0 }))
            }
            Menu("Android") {
                PaneViewMenu(preferences: Binding(get: { model.androidView }, set: { model.androidView = $0 }))
                Toggle("Show Preview", isOn: Binding(get: { model.showAndroidPreview }, set: { model.showAndroidPreview = $0 }))
            }

            Divider()
            Button("Refresh") { Task { await model.refreshBothPanes() } }
                .keyboardShortcut("r", modifiers: .command)
        }
        CommandMenu("Transfer") {
            Button(model.summary.isPaused ? "Resume All" : "Pause All") {
                model.summary.isPaused ? model.resumeAll() : model.pauseAll()
            }
            .disabled(model.transferItems.isEmpty)

            Button("Clear Finished") { model.clearFinished() }
                .disabled(model.transferItems.isEmpty)
        }
    }
}

extension Notification.Name {
    static let newFolderRequested = Notification.Name("app.porter.newFolder")
}

struct MenuBarLabel: View {
    let summary: TransferSummary

    var body: some View {
        if summary.isRunning {
            // A percentage, rather than an indeterminate spinner.
            Label("\(Int(summary.fractionComplete * 100))%", systemImage: "arrow.up.arrow.down.circle.fill")
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "arrow.up.arrow.down.circle")
        }
    }
}
