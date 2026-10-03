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
