import Foundation

/// When a reading counts as a breach, when it counts as recovered, and how long each
/// has to last. Generic on purpose: notification rules, the Keep-Awake guard (Faz 9)
/// and server alerts (Faz 11) all use it.
public struct ThresholdSpec: Sendable, Equatable {
    public enum Direction: Sendable, Equatable {
        /// Breached while the value is at or above `trigger`.
        case above
        /// Breached while the value is at or below `trigger`.
        case below
    }

    public var direction: Direction
    /// Crossing this starts the breach clock.
    public var trigger: Double
    /// The value must come back past this (not merely to `trigger`) to recover. The gap
    /// between the two is the hysteresis band.
    public var clear: Double
    /// Seconds the value must stay in breach before the machine fires. 0 fires at once.
    public var minDuration: TimeInterval
    /// Seconds the value must stay recovered before the machine re-arms.
    public var clearDuration: TimeInterval
    /// Minimum seconds between two firings, however the value moves.
    public var cooldown: TimeInterval
    /// A gap between two readings longer than this (sleep, a paused sampler) restarts
    /// the clocks: a breach is not counted across time nobody was looking.
    public var staleAfter: TimeInterval

    public init(direction: Direction, trigger: Double, clear: Double, minDuration: TimeInterval = 0,
                clearDuration: TimeInterval = 0, cooldown: TimeInterval = 0, staleAfter: TimeInterval = 120) {
        self.direction = direction
        self.trigger = trigger
        self.clear = clear
        self.minDuration = minDuration
        self.clearDuration = clearDuration
        self.cooldown = cooldown
        self.staleAfter = staleAfter
    }

    func breaches(_ value: Double) -> Bool {
        direction == .above ? value >= trigger : value <= trigger
    }

    func recovered(_ value: Double) -> Bool {
        direction == .above ? value <= clear : value >= clear
    }
}

/// What a reading changed.
public enum ThresholdTransition: Sendable, Equatable {
    case triggered
    case recovered
}

/// One rule's state. Pure: it never reads the clock; the caller passes the time of each
/// reading, so tests drive it with synthetic series.
///
///     idle ──(breach for minDuration, cooldown over)──▶ active ──(recovered for clearDuration)──▶ idle
///
/// A value wobbling around the limit therefore fires once: a pending breach survives dips into
/// the hysteresis band, while active the value only has to stay out of the recovered zone, and a
/// dip that does recover cannot fire again inside the cooldown.
public struct ThresholdMachine: Sendable, Equatable {
    public private(set) var spec: ThresholdSpec
    public private(set) var isActive = false
    private var breachSince: Date?
    private var recoverySince: Date?
    private var lastFired: Date?
    private var lastReading: Date?

    public init(_ spec: ThresholdSpec) { self.spec = spec }

    /// Feed one reading. `nil` means "no value right now" (sensor gone, no battery): the
    /// running clocks restart, the active state stays.
    public mutating func feed(_ value: Double?, at now: Date) -> ThresholdTransition? {
        if let last = lastReading, now.timeIntervalSince(last) > spec.staleAfter {
            breachSince = nil
            recoverySince = nil
        }
        lastReading = now
        guard let value else {
            breachSince = nil
            recoverySince = nil
            return nil
        }
        if isActive {
            guard spec.recovered(value) else {
                recoverySince = nil
                return nil
            }
            let since = recoverySince ?? now
            recoverySince = since
            guard now.timeIntervalSince(since) >= spec.clearDuration else { return nil }
            isActive = false
            recoverySince = nil
            return .recovered
        }
        guard spec.breaches(value) else {
            // Inside the hysteresis band a started breach is not abandoned: a value that wobbles
            // around the limit must not keep restarting its own clock. Only a real recovery does.
            if spec.recovered(value) { breachSince = nil }
            return nil
        }
        let since = breachSince ?? now
        breachSince = since
        guard now.timeIntervalSince(since) >= spec.minDuration else { return nil }
        if let fired = lastFired, now.timeIntervalSince(fired) < spec.cooldown { return nil }
        isActive = true
        lastFired = now
        breachSince = nil
        return .triggered
    }

    /// The earliest time something could change without a new reading, for sources that
    /// report rarely (a path event, then silence). nil when nothing is pending.
    public var deadline: Date? {
        if isActive { return recoverySince.map { $0.addingTimeInterval(spec.clearDuration) } }
        guard let since = breachSince else { return nil }
        let ready = since.addingTimeInterval(spec.minDuration)
        guard let fired = lastFired else { return ready }
        return max(ready, fired.addingTimeInterval(spec.cooldown))
    }

    /// Forget everything (rule switched off).
    public mutating func reset() {
        self = ThresholdMachine(spec)
    }
}
