import Foundation

/// Each pane keeps its own sort field across navigation and app launches.
enum SortField: String, CaseIterable, Identifiable, Codable {
    case name, size, modified
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: return "Name"
        case .size: return "Size"
        case .modified: return "Date Modified"
        }
    }
}

enum ViewMode: Int, CaseIterable, Identifiable, Codable {
    case list = 1
    case grid = 2
    var id: Int { rawValue }
}

/// Independent, persisted browser preferences for each side of the window.
struct PanePreferences: Codable, Equatable {
    var viewMode: ViewMode = .list
    var sortField: SortField = .name
    var sortAscending = true
    var showHiddenFiles = false
    var showThumbnails = true

    static func load(_ key: String) -> Self {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }

    func save(_ key: String) {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: key) }
    }
}
