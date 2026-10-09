import Dispatch
import Foundation

/// Turns the user's rules into demand and notifications.
///
/// Every enabled rule holds its metric in the ``DemandRegistry`` as a *periodic* consumer, so
/// it is read every ~10 s at most (``AlertKind/period``), and a rule that is off holds nothing:
/// with all rules off this object observes nothing and costs nothing. Evaluation happens when
/// the store ingests a snapshot; the only timer is a one-shot for event-driven rules (network)
/// whose pending duration would otherwise wait for a reading that never comes.
@MainActor
public final class AlertCenter {
    public private(set) var rules: [AlertRule] = AlertRule.defaults

    private let store: MetricStore
    private let demand: DemandRegistry
    private let now: () -> Date
    private let post: (AlertEvent) -> Void

    private var machines: [AlertKind: ThresholdMachine] = [:]
    private var retained: [AlertKind: (metric: Metric, period: Double?)] = [:]
    private var token: ObservationToken?
    private var timer: DispatchSourceTimer?

    /// `post` is called on the main actor for each trigger and recovery.
    public init(store: MetricStore, demand: DemandRegistry, now: @escaping () -> Date = Date.init,
                post: @escaping (AlertEvent) -> Void) {
        self.store = store
        self.demand = demand
        self.now = now
        self.post = post
    }

    isolated deinit { timer?.cancel() }

    public var hasEnabledRules: Bool { rules.contains(where: \.enabled) }

    /// Replaces the rule set. Rules that did not change keep their running state, so editing
    /// one threshold cannot re-notify another.
    public func apply(_ new: [AlertRule]) {
        let merged = AlertRule.merged(with: new)
        let old = rules
        rules = merged
        for rule in merged {
            let before = old.first { $0.kind == rule.kind }
            if rule.enabled {
                if before != rule || machines[rule.kind] == nil {
                    machines[rule.kind] = ThresholdMachine(rule.spec)
                }
                hold(rule.kind)
            } else {
                machines[rule.kind] = nil
                drop(rule.kind)
            }
        }
        if hasEnabledRules, token == nil {
            token = store.observe { [weak self] in self?.evaluate() }
        } else if !hasEnabledRules {
            token = nil
            timer?.cancel()
            timer = nil
        }
    }

    /// Whether the rule has fired and not yet recovered. For the UI.
    public func isActive(_ kind: AlertKind) -> Bool { machines[kind]?.isActive ?? false }

    private func hold(_ kind: AlertKind) {
        guard retained[kind] == nil else { return }
        retained[kind] = (kind.metric, kind.period)
        if let period = kind.period { demand.retain(kind.metric, period: period) } else { demand.retain(kind.metric) }
    }

    private func drop(_ kind: AlertKind) {
        guard let held = retained.removeValue(forKey: kind) else { return }
        if let period = held.period { demand.release(held.metric, period: period) } else { demand.release(held.metric) }
    }

    /// Feeds every enabled rule the store's current value. Repeating a value is harmless:
    /// only time and value matter to the machines.
    func evaluate() {
        let date = now()
        for rule in rules where rule.enabled {
            guard var machine = machines[rule.kind] else { continue }
            let value = rule.kind.value(from: store)
            let transition = machine.feed(value, at: date)
            machines[rule.kind] = machine
            if let transition, let value {
                post(AlertEvent(kind: rule.kind, transition: transition, value: value, threshold: rule.threshold, date: date))
            }
        }
        scheduleDeadline()
    }

    private func scheduleDeadline() {
        timer?.cancel()
        timer = nil
        let date = now()
        let next = rules.filter { $0.enabled && $0.kind.isEventDriven }
            .compactMap { machines[$0.kind]?.deadline }
            .min()
        guard let next else { return }
        let delay = max(0.5, next.timeIntervalSince(date))
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + delay, leeway: .milliseconds(500))
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        source.activate()
        timer = source
    }
}
