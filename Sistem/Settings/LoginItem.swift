import Observation
import ServiceManagement

/// "Launch at login" through `SMAppService.mainApp`. The system owns the state, so it is
/// read back after every change and never stored. An ad-hoc signed build or a copy outside
/// /Applications can be refused; the reason is kept for the Settings row to show.
@Observable
@MainActor
final class LoginItem {
    enum State: Equatable {
        case off
        case on
        /// Registered, but the user has to allow it in System Settings → Login Items.
        case needsApproval
        /// The system cannot find a registrable app here (moved, unsigned, translocated).
        case unavailable
    }

    private(set) var state: State = .off
    private(set) var failure: String?

    init() { refresh() }

    func refresh() {
        state = switch SMAppService.mainApp.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        case .notFound: .unavailable
        default: .off
        }
    }

    var isOn: Bool { state == .on || state == .needsApproval }

    func set(_ on: Bool) {
        failure = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            failure = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
