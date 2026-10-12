import SwiftUI

private struct PorterBrowserFocus: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var porterBrowser: Bool? {
        get { self[PorterBrowserFocus.self] }
        set { self[PorterBrowserFocus.self] = newValue }
    }
}
