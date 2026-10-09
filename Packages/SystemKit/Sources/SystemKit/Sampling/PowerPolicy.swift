import Foundation
import IOKit.ps
import notify

/// Watches the power situation and says how much to stretch the interval
/// (PLAN.md §3-A). Event-driven: no polling, nothing runs between changes.
@MainActor
public final class PowerPolicy {
    public struct State: Equatable, Sendable {
        public var onBattery = false
        public var lowPowerMode = false
        public var thermal: ProcessInfo.ThermalState = .nominal
    }

    public private(set) var state = State()
    var onChange: (() -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var powerSourceToken: Int32 = NOTIFY_TOKEN_INVALID

    public init() {
        refresh()
        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        notify_register_dispatch(kIOPSNotifyPowerSource, &powerSourceToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if powerSourceToken != NOTIFY_TOKEN_INVALID { notify_cancel(powerSourceToken) }
    }

    /// ×2 on battery or in Low Power Mode (when the user allows slowing down),
    /// another ×2 when the Mac is running hot.
    public func multiplier(slowDownOnBattery: Bool) -> Double {
        Self.multiplier(for: state, slowDownOnBattery: slowDownOnBattery)
    }

    /// The same rule as a pure function, so profiles and tests can feed it any state.
    public nonisolated static func multiplier(for state: State, slowDownOnBattery: Bool) -> Double {
        var factor = 1.0
        if slowDownOnBattery && (state.onBattery || state.lowPowerMode) { factor *= 2 }
        if state.thermal == .serious || state.thermal == .critical { factor *= 2 }
        return factor
    }

    private func refresh() {
        var new = State()
        new.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        new.thermal = ProcessInfo.processInfo.thermalState
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() {
            new.onBattery = (type as String) == kIOPMBatteryPowerKey
        }
        guard new != state else { return }
        state = new
        onChange?()
    }
}
