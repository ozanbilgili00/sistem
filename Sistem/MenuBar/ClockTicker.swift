import AppKit
import SystemKit

/// Fires exactly when the clock's text can change: at the next minute boundary, or the next second
/// for a pattern that shows seconds. One one-shot timer at a time, rescheduled after every fire,
/// so a minute clock wakes the app once a minute (not on the sampler's tick, and not once a second).
/// A wall-clock timer, so a clock change, a time zone change or waking from sleep rescan the boundary.
@MainActor
final class ClockTicker {
    private var timer: DispatchSourceTimer?
    private var pattern = ""
    private let fire: () -> Void
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// How many times the timer has fired, for the diagnostics and the tests.
    private(set) var fires = 0

    init(fire: @escaping () -> Void) {
        self.fire = fire
        let rescan: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.reschedule(refire: true) } }
        let center = NotificationCenter.default
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, NSLocale.currentLocaleDidChangeNotification] {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main, using: rescan)))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: rescan)))
    }

    isolated deinit {
        timer?.cancel()
        for (center, token) in observers { center.removeObserver(token) }
    }

    func start(pattern: String) {
        self.pattern = pattern
        reschedule(refire: false)
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func reschedule(refire: Bool) {
        timer?.cancel()
        if refire { fire() }
        let delay = max(0.05, ClockFormat.nextUpdate(after: .now, pattern: pattern).timeIntervalSinceNow)
        let source = DispatchSource.makeTimerSource(queue: .main)
        // A little leeway lets the kernel fold the wakeup into someone else's; a minute clock can
        // be half a second late, a seconds clock only a tenth.
        let leeway = ClockFormat.containsSeconds(pattern) ? 100 : 500
        source.schedule(wallDeadline: .now() + delay, leeway: .milliseconds(leeway))
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fires += 1
                self.reschedule(refire: true)
            }
        }
        source.activate()
        timer = source
    }
}
