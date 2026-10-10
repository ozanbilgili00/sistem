import Dispatch
import Foundation

/// Keeps the Mac awake on request or by trigger, and lets go when it gets unsafe.
///
/// There is no always-on timer. One timer exists only while something needs it: a trigger is
/// switched on, an assertion is held, or the protection is waiting to clear. It fires every
/// ``pollInterval`` seconds (and at a session's end or a grace period's end) and reads what
/// is needed straight from the system, not from the sampler: the sampler stops completely
/// while the display sleeps or the screen is locked, which is exactly when a kept-awake Mac
/// needs watching.
///
/// Dying with the process is the system's doing: an IOPM assertion belongs to its creator.
@MainActor
public final class KeepAwakeController {
    public static let pollInterval: TimeInterval = 30

    public private(set) var config = KeepAwakeConfig()
    public private(set) var state = KeepAwakeState()
    /// Called after every change of `state`.
    public var onChange: (() -> Void)?
    /// Called when the protection trips or clears.
    public var onEvent: ((KeepAwakeEvent) -> Void)?

    private let backend: PowerAssertionBackend
    private var sources: AwakeSources
    private let assertionName: String
    private var protection: KeepAwakeGuard

    private var systemID: UInt32?
    private var displayID: UInt32?
    private var manualActive = false
    private var manualEndsAt: Date?
    /// Last time each trigger's condition was true.
    private var lastSeen: [AwakeTrigger: Date] = [:]
    private var network = ThresholdMachine(ThresholdSpec(direction: .above, trigger: 1, clear: 0))
    private var processesSeen: Set<String> = []
    private var lastPoll = Date.distantPast
    private var timer: DispatchSourceTimer?

    public init(backend: PowerAssertionBackend = IOPMBackend(), sources: AwakeSources = .live(),
                assertionName: String = "Sistem - Uyanik Tut", limits: GuardLimits = GuardLimits()) {
        self.backend = backend
        self.sources = sources
        self.assertionName = assertionName
        protection = KeepAwakeGuard(limits)
    }

    isolated deinit {
        timer?.cancel()
        releaseAssertions()
    }

    // MARK: Control

    public func apply(_ new: KeepAwakeConfig) {
        guard new != config else { return }
        let old = config
        config = new
        if !new.enabled {
            manualActive = false
            manualEndsAt = nil
            lastSeen = [:]
            protection = KeepAwakeGuard()
        }
        if new.networkThreshold != old.networkThreshold || new.triggers.contains(.network) != old.triggers.contains(.network) {
            network = ThresholdMachine(ThresholdSpec(direction: .above, trigger: new.networkThreshold, clear: new.networkThreshold / 2))
            sources.resetNetwork()
        }
        for trigger in AwakeTrigger.allCases where !new.triggers.contains(trigger) { lastSeen[trigger] = nil }
        evaluate(poll: new.enabled)
    }

    /// Starts a manual session. false when disabled or when the protection says no.
    @discardableResult
    public func startManual(duration: TimeInterval?) -> Bool {
        guard config.enabled, state.blocked == nil else { return false }
        manualActive = true
        manualEndsAt = duration.map { sources.now().addingTimeInterval($0) }
        evaluate(poll: false)
        return state.manualActive
    }

    public func stopManual() {
        guard manualActive else { return }
        manualActive = false
        manualEndsAt = nil
        evaluate(poll: false)
    }

    /// Looks again right now: an app launched, the Mac woke up.
    public func refresh() {
        guard config.enabled else { return }
        evaluate(poll: true)
    }

    /// Seconds left of a timed manual session.
    public func remaining(at date: Date? = nil) -> TimeInterval? {
        guard let end = manualEndsAt, manualActive else { return nil }
        return max(0, end.timeIntervalSince(date ?? sources.now()))
    }

    // MARK: Evaluation

    func evaluate(poll: Bool) {
        let now = sources.now()
        guard config.enabled else {
            timer?.cancel()
            timer = nil
            releaseAssertions()
            publish(KeepAwakeState())
            return
        }
        if let end = manualEndsAt, manualActive, now >= end {
            manualActive = false
            manualEndsAt = nil
        }
        var present: Set<AwakeTrigger> = []
        if poll {
            lastPoll = now
            present = pollTriggers(now: now)
            for trigger in present { lastSeen[trigger] = now }
        } else {
            present = state.presentTriggers.intersection(config.triggers)
        }
        let holding = Set(config.triggers.filter { trigger in
            guard let seen = lastSeen[trigger] else { return false }
            return now.timeIntervalSince(seen) <= trigger.grace
        })
        let wouldHold = manualActive || !holding.isEmpty

        var event: KeepAwakeEvent?
        if wouldHold || state.blocked != nil {
            switch protection.feed(sources.guardInput(), at: now) {
            case .tripped(let reason)?:
                event = .protectionTripped(reason)
                manualActive = false
                manualEndsAt = nil
            case .cleared?:
                event = .protectionCleared
            case nil:
                break
            }
        }
        let blocked = protection.tripped
        let hold = blocked == nil && (manualActive || !holding.isEmpty)
        reconcile(hold: hold)

        var new = KeepAwakeState()
        new.isHolding = systemID != nil
        new.holdsDisplay = displayID != nil
        new.manualActive = manualActive && blocked == nil
        new.manualEndsAt = new.manualActive ? manualEndsAt : nil
        new.holdingTriggers = hold ? holding : []
        new.presentTriggers = present
        new.blocked = blocked
        publish(new)
        schedule(now: now)
        if let event { onEvent?(event) }
    }

    /// One read of every enabled trigger's condition.
    private func pollTriggers(now: Date) -> Set<AwakeTrigger> {
        var present: Set<AwakeTrigger> = []
        let wanted = config.triggers.filter(\.isProcessBased)
        if !wanted.isEmpty {
            let names = Set(wanted.flatMap(\.processNames))
            processesSeen = sources.runningProcesses(names)
            for trigger in wanted where !trigger.processNames.isDisjoint(with: processesSeen) { present.insert(trigger) }
        }
        if config.triggers.contains(.network) {
            // The machine keeps the last verdict across a missing rate, so a reader without a baseline changes nothing.
            _ = network.feed(sources.networkRate(), at: now)
            if network.isActive { present.insert(.network) }
        }
        if config.triggers.contains(.charging), sources.isOnPower() == true { present.insert(.charging) }
        return present
    }

    private func reconcile(hold: Bool) {
        if hold {
            if systemID == nil { systemID = backend.create(.system, name: assertionName) }
            if config.keepDisplayOn {
                if displayID == nil { displayID = backend.create(.display, name: assertionName) }
            } else if let id = displayID {
                backend.release(id)
                displayID = nil
            }
        } else {
            releaseAssertions()
        }
    }

    private func releaseAssertions() {
        if let id = systemID { backend.release(id) }
        if let id = displayID { backend.release(id) }
        systemID = nil
        displayID = nil
    }

    private func publish(_ new: KeepAwakeState) {
        guard new != state else { return }
        state = new
        onChange?()
    }

    // MARK: Timer

    private var needsPoll: Bool {
        config.enabled && (!config.triggers.isEmpty || state.isHolding || state.blocked != nil)
    }

    private func schedule(now: Date) {
        timer?.cancel()
        timer = nil
        var next: [Date] = []
        if needsPoll { next.append(lastPoll.addingTimeInterval(Self.pollInterval)) }
        if manualActive, let end = manualEndsAt { next.append(end) }
        for (trigger, seen) in lastSeen where !state.presentTriggers.contains(trigger) {
            let end = seen.addingTimeInterval(trigger.grace + 0.5)
            if end > now { next.append(end) }
        }
        guard let when = next.min() else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + max(0.5, when.timeIntervalSince(now)), leeway: .seconds(2))
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let due = self.sources.now().timeIntervalSince(self.lastPoll) >= Self.pollInterval - 1
                self.evaluate(poll: due)
            }
        }
        source.activate()
        timer = source
    }
}
