import SwiftUI
import SystemKit

/// A sidebar destination. String-backed so the last page survives relaunch.
enum Page: Hashable {
    case module(ModuleID)
    case settings
    case diagnostics

    init(rawValue: String) {
        switch rawValue {
        case "settings": self = .settings
        case "diagnostics": self = .diagnostics
        default: self = .module(ModuleID(rawValue: rawValue) ?? .dashboard)
        }
    }

    var rawValue: String {
        switch self {
        case .module(let id): id.rawValue
        case .settings: "settings"
        case .diagnostics: "diagnostics"
        }
    }
}

/// Navigates the main window to a page. Compares equal always: the closure only writes a
/// stored selection, so a new instance must not invalidate every view that reads it.
struct PageNavigator: Equatable {
    var go: (Page) -> Void = { _ in }
    static func == (lhs: PageNavigator, rhs: PageNavigator) -> Bool { true }
}

extension EnvironmentValues {
    /// A no-op where there is no window (popovers, snapshots).
    @Entry var openPage = PageNavigator()
}
