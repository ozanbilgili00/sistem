import AppKit

/// Tracks the moments nobody can see the numbers: system sleep, display sleep,
/// screen lock, and a switched-away login session. While any applies the sampler
/// stops completely — no timer, no wakeups (PLAN.md §3-A).
@MainActor
public final class PauseMonitor {
    public enum Reason: String, CaseIterable, Sendable {
        case systemSleep, displaySleep, screenLocked, sessionInactive
    }

    public private(set) var reasons: Set<Reason> = []
    public var onChange: (() -> Void)?

    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    public init() {
        let workspace = NSWorkspace.shared.notificationCenter
        watch(workspace, NSWorkspace.willSleepNotification, .systemSleep, active: true)
        watch(workspace, NSWorkspace.didWakeNotification, .systemSleep, active: false)
        watch(workspace, NSWorkspace.screensDidSleepNotification, .displaySleep, active: true)
        watch(workspace, NSWorkspace.screensDidWakeNotification, .displaySleep, active: false)
        watch(workspace, NSWorkspace.sessionDidResignActiveNotification, .sessionInactive, active: true)
        watch(workspace, NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive, active: false)
        let distributed = DistributedNotificationCenter.default()
        watch(distributed, Notification.Name("com.apple.screenIsLocked"), .screenLocked, active: true)
        watch(distributed, Notification.Name("com.apple.screenIsUnlocked"), .screenLocked, active: false)
    }

    isolated deinit {
        for (center, token) in tokens { center.removeObserver(token) }
    }

    private func watch(_ center: NotificationCenter, _ name: Notification.Name, _ reason: Reason, active: Bool) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.set(reason, active) }
        }
        tokens.append((center, token))
    }

    private func set(_ reason: Reason, _ active: Bool) {
        let changed = active ? reasons.insert(reason).inserted : reasons.remove(reason) != nil
        if changed { onChange?() }
    }
}
