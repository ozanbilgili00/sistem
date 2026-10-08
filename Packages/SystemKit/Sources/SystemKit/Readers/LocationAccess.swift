import CoreLocation
import Foundation

/// Location Services permission, needed only to read the Wi-Fi network name.
///
/// Nothing here prompts by itself: creating the manager and reading its status are
/// silent, and the system dialog appears only when ``request()`` is called, which
/// the UI does from an explicit button (never at launch).
@MainActor
public final class LocationAccess: NSObject, CLLocationManagerDelegate {
    public enum State: Sendable, Equatable {
        /// Never asked.
        case notDetermined
        case authorized
        /// Denied by the user, restricted by policy, or Location Services are off for the whole Mac
        /// (macOS reports all three the same way).
        case denied
    }

    public private(set) var state: State = .notDetermined
    public var onChange: (() -> Void)?

    private lazy var manager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        return manager
    }()

    public override init() {
        super.init()
        refresh()
    }

    /// Shows the system permission dialog (once; afterwards the answer is final).
    public func request() {
        guard state == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    public func refresh() {
        let new = Self.state(for: manager.authorizationStatus)
        guard new != state else { return }
        state = new
        onChange?()
    }

    nonisolated static func state(for status: CLAuthorizationStatus) -> State {
        switch status {
        case .authorizedAlways, .authorized: .authorized
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { refresh() }
    }
}
