import PorterKit
import SwiftUI

struct RemoteBreadcrumbBar: View {
    let path: RemotePath
    let root: RemotePath
    let rootLabel: String
    let onSelect: (RemotePath) -> Void

    var body: some View {
        BreadcrumbStrip(crumbs: crumbs, onSelect: { onSelect($0.path) })
    }

    private var crumbs: [Crumb<RemotePath>] {
        // Show the path relative to the storage volume. Nobody needs to see
        // /storage/emulated/0 in front of every folder they open.
        guard let relative = path.relative(to: root) else {
            return [Crumb(label: rootLabel, path: root)]
        }
        var result = [Crumb(label: rootLabel, path: root)]
        var accumulated = root
        for component in relative.components {
            accumulated = accumulated.appending(component)
            result.append(Crumb(label: component, path: accumulated))
        }
        return result
    }
}

struct LocalBreadcrumbBar: View {
    let directory: URL
    let onSelect: (URL) -> Void

    var body: some View {
        BreadcrumbStrip(crumbs: crumbs, onSelect: { onSelect($0.path) })
    }

    private var crumbs: [Crumb<URL>] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var components: [Crumb<URL>] = []
        var current = directory

        while current.path.count > 1 {
            let isHome = current.standardizedFileURL == home.standardizedFileURL
            components.insert(Crumb(label: isHome ? "Home" : current.lastPathComponent, path: current), at: 0)
            if isHome { return components }
            current = current.deletingLastPathComponent()
        }
        components.insert(Crumb(label: "Macintosh HD", path: URL(fileURLWithPath: "/")), at: 0)
        return components
    }
}

struct Crumb<Path: Hashable>: Identifiable, Hashable {
    var label: String
    var path: Path
    var id: Path { path }
}

struct BreadcrumbStrip<Path: Hashable>: View {
    let crumbs: [Crumb<Path>]
    let onSelect: (Crumb<Path>) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(Array(crumbs.enumerated()), id: \.element.id) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        onSelect(crumb)
                    } label: {
                        Text(crumb.label)
                            .font(.callout)
                            .fontWeight(index == crumbs.count - 1 ? .semibold : .regular)
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == crumbs.count - 1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .scrollIndicators(.never)
        // The strip scrolls; the window must not grow to fit a deep path.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary)
        Divider()
    }
}
