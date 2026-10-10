import AppKit
import Observation
import SystemKit

/// The app's view of Keep Awake: wraps the controller, mirrors its state for SwiftUI, and
/// reports protection events as notifications. With the module off it holds nothing.
@Observable
final class KeepAwakeModel {
    private(set) var state = KeepAwakeState()
    /// The settings the controller currently runs on, for views that explain them.
    private(set) var config = KeepAwakeConfig()

    @ObservationIgnored private let controller: KeepAwakeController?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Called once per change of `state.isHolding` or `state.blocked`: the menu bar icon redraws only then.
    @ObservationIgnored var onVisibleChange: (() -> Void)?
    @ObservationIgnored var onProtection: (KeepAwakeEvent) -> Void = { _ in }
    @ObservationIgnored private var lastVisible: Visible?

    private struct Visible: Equatable {
        var holding: Bool
        var blocked: ProtectionReason?
    }

    /// `controller` nil = a frozen preview (snapshots): nothing is created, nothing held.
    init(controller: KeepAwakeController? = KeepAwakeController()) {
        self.controller = controller
        controller?.onChange = { [weak self] in self?.sync() }
        controller?.onEvent = { [weak self] event in self?.onProtection(event) }
    }

    #if DEBUG
    init(previewing state: KeepAwakeState, config: KeepAwakeConfig = KeepAwakeConfig(enabled: true)) {
        controller = nil
        self.state = state
        self.config = config
    }
    #endif

    isolated deinit { observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) } }

    func apply(_ new: KeepAwakeConfig) {
        config = new
        controller?.apply(new)
        syncWorkspaceHints(wanted: new.enabled && !new.triggers.isEmpty)
        sync()
    }

    /// Starts a session; false when the protection refuses (low battery, hot Mac).
    @discardableResult
    func start(duration: TimeInterval?) -> Bool { controller?.startManual(duration: duration) ?? false }
    func stop() { controller?.stopManual() }

    /// Click on the cup: stop when holding, otherwise start with the default length.
    func toggle(defaultDuration: Double) {
        if state.manualActive {
            stop()
        } else {
            start(duration: defaultDuration > 0 ? defaultDuration : nil)
        }
    }

    func remaining(at date: Date = Date()) -> TimeInterval? { controller?.remaining(at: date) ?? state.manualEndsAt.map { max(0, $0.timeIntervalSince(date)) } }

    private func sync() {
        guard let controller else { return }
        if controller.state != state { state = controller.state }
        let visible = Visible(holding: state.isHolding, blocked: state.blocked)
        if visible != lastVisible {
            lastVisible = visible
            onVisibleChange?()
        }
    }

    /// A launched app or a wake is a hint to look now instead of at the next 30 s step. Registered
    /// only while a trigger is on; each is one cheap notification, no polling.
    private func syncWorkspaceHints(wanted: Bool) {
        if wanted, observers.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didWakeNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.controller?.refresh() }
                })
            }
        } else if !wanted, !observers.isEmpty {
            observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
            observers = []
        }
    }
}
