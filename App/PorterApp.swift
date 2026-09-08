import PorterKit
import SwiftUI

@main
struct PorterApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        Window("Porter", id: "main") {
            ContentView()
                .environment(model)
                .task { model.start() }
                .frame(minWidth: 860, minHeight: 540)
        }
        .windowToolbarStyle(.unified)
        .commands { PorterCommands(model: model) }

        // Progress without keeping the window open.
        MenuBarExtra {
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

/// Finder's shortcuts, because this is a file browser and muscle memory is real.
struct PorterCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Folder") { NotificationCenter.default.post(name: .newFolderRequested, object: nil) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .toolbar) {
            Picker("View", selection: Binding(get: { model.viewMode }, set: { model.viewMode = $0 })) {
                Text("as List").tag(ViewMode.list)
                Text("as Icons").tag(ViewMode.grid)
            }
            .pickerStyle(.inline)

            Toggle("Show Hidden Files", isOn: Binding(
                get: { model.showHiddenFiles },
                set: { model.showHiddenFiles = $0 }
            ))
            .keyboardShortcut(".", modifiers: [.command, .shift])

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
            // A number beats a spinner: it tells you whether to wait.
            Label("\(Int(summary.fractionComplete * 100))%", systemImage: "arrow.up.arrow.down.circle.fill")
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "arrow.up.arrow.down.circle")
        }
    }
}
