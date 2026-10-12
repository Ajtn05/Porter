import Foundation

/// Each pane keeps its own sort field across navigation and app launches.
enum SortField: String, CaseIterable, Identifiable, Codable {
    case name, size, modified, kind
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: return "Name"
        case .size: return "Size"
        case .modified: return "Date Modified"
        case .kind: return "Kind"
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
    var columnWidths: [String: Double] = [:]

    private enum CodingKeys: String, CodingKey {
        case viewMode, sortField, sortAscending, showHiddenFiles, showThumbnails, columnWidths
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        viewMode = try values.decodeIfPresent(ViewMode.self, forKey: .viewMode) ?? .list
        sortField = try values.decodeIfPresent(SortField.self, forKey: .sortField) ?? .name
        sortAscending = try values.decodeIfPresent(Bool.self, forKey: .sortAscending) ?? true
        showHiddenFiles = try values.decodeIfPresent(Bool.self, forKey: .showHiddenFiles) ?? false
        showThumbnails = try values.decodeIfPresent(Bool.self, forKey: .showThumbnails) ?? true
        columnWidths = try values.decodeIfPresent([String: Double].self, forKey: .columnWidths) ?? [:]
    }

    static func load(_ key: String) -> Self {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }

    func save(_ key: String) {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: key) }
    }
}
