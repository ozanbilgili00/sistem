import Foundation

/// The conditions a user can be notified about.
public enum AlertKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case cpuLoad, memoryPressure, cpuTemperature, diskFree, batteryLow, networkDown

    public var id: String { rawValue }

    /// The metric the rule reads while it is on.
    public var metric: Metric {
        switch self {
        case .cpuLoad: .cpu
        case .memoryPressure: .memory
        case .cpuTemperature: .temperature
        case .diskFree: .diskSpace
        case .batteryLow: .battery
        case .networkDown: .connectivity
        }
    }

    /// Seconds between readings; nil for a source that reports events by itself.
    public var period: Double? {
        switch self {
        case .cpuLoad, .memoryPressure, .cpuTemperature: 10
        case .diskFree, .batteryLow: 60
        case .networkDown: nil
        }
    }

    /// Whether a quiet source may need a timer to finish a pending duration.
    public var isEventDriven: Bool { period == nil }

    /// The page a notification opens.
    public var module: ModuleID {
        switch self {
        case .cpuLoad: .cpu
        case .memoryPressure: .ram
        case .cpuTemperature: .sensors
        case .diskFree: .disk
        case .batteryLow: .battery
        case .networkDown: .network
        }
    }

    public var direction: ThresholdSpec.Direction {
        switch self {
        case .cpuLoad, .memoryPressure, .cpuTemperature, .networkDown: .above
        case .diskFree, .batteryLow: .below
        }
    }

    /// What the threshold is measured in, for the UI.
    public enum Unit: Sendable { case percent, celsius, gigabytes, pressure, none }

    public var unit: Unit {
        switch self {
        case .cpuLoad, .batteryLow: .percent
        case .cpuTemperature: .celsius
        case .diskFree: .gigabytes
        case .memoryPressure: .pressure
        case .networkDown: .none
        }
    }

    /// Allowed trigger values (memory pressure: 2 = warning, 4 = critical, the kernel's own levels).
    public var thresholdChoices: [Double] {
        switch self {
        case .cpuLoad: [70, 80, 90, 95]
        case .memoryPressure: [2, 4]
        case .cpuTemperature: [80, 85, 90, 95, 100]
        case .diskFree: [5, 10, 20, 50, 100]
        case .batteryLow: [10, 15, 20, 30]
        case .networkDown: [1]
        }
    }

    public var defaultThreshold: Double {
        switch self {
        case .cpuLoad: 90
        case .memoryPressure: 2
        case .cpuTemperature: 95
        case .diskFree: 10
        case .batteryLow: 20
        case .networkDown: 1
        }
    }

    /// Seconds the breach must last. Empty = fixed at `defaultDuration`.
    public var durationChoices: [Double] {
        switch self {
        case .cpuLoad: [10, 30, 60, 120, 300]
        case .cpuTemperature: [10, 30, 60, 120]
        case .networkDown: [5, 15, 30, 60]
        case .memoryPressure, .diskFree, .batteryLow: []
        }
    }

    public var defaultDuration: Double {
        switch self {
        case .cpuLoad, .cpuTemperature: 30
        case .memoryPressure: 10
        case .diskFree, .batteryLow: 0
        case .networkDown: 15
        }
    }

    /// Seconds before the same rule may notify again.
    public var cooldown: Double {
        switch self {
        case .cpuLoad, .cpuTemperature: 600
        case .memoryPressure: 900
        case .diskFree: 6 * 3600
        case .batteryLow: 1800
        case .networkDown: 300
        }
    }

    /// The level the value must come back past: the hysteresis band's far edge.
    public func clearLevel(for trigger: Double) -> Double {
        switch self {
        case .cpuLoad: max(0, trigger - 10)
        case .memoryPressure: trigger / 2  // warning (2) clears at normal (1); critical (4) at warning (2)
        case .cpuTemperature: trigger - 10
        case .diskFree: (trigger * 1.2).rounded(.up)
        case .batteryLow: trigger + 5
        case .networkDown: 0
        }
    }

    /// The current reading, in the rule's unit. nil = nothing to judge.
    @MainActor
    public func value(from store: MetricStore) -> Double? {
        switch self {
        case .cpuLoad:
            return store.cpu.map { Double($0.total) * 100 }
        case .memoryPressure:
            return store.memory.map { Double($0.pressure.rawValue) }
        case .cpuTemperature:
            guard let sample = store.temperature else { return nil }
            return (sample.cpuHottest ?? sample.hottest).map(Double.init)
        case .diskFree:
            return store.bootVolume.map { Double($0.available) / 1_000_000_000 }
        case .batteryLow:
            // On power the condition is over by definition, whatever the charge.
            guard let sample = store.battery?.sample else { return nil }
            return sample.state == .discharging ? Double(sample.percent) : 100
        case .networkDown:
            return store.path.map { $0.isConnected ? 0 : 1 }
        }
    }
}

/// One user-configurable rule. Off by default.
public struct AlertRule: Codable, Equatable, Sendable, Identifiable {
    public var kind: AlertKind
    public var enabled: Bool
    public var threshold: Double
    /// Seconds.
    public var duration: Double

    public var id: AlertKind { kind }

    public init(kind: AlertKind, enabled: Bool = false, threshold: Double? = nil, duration: Double? = nil) {
        self.kind = kind
        self.enabled = enabled
        self.threshold = threshold ?? kind.defaultThreshold
        self.duration = duration ?? kind.defaultDuration
    }

    /// Values outside the choices (hand-edited file, older version) snap to the nearest allowed one.
    public func sanitized() -> AlertRule {
        var rule = self
        rule.threshold = Self.nearest(to: threshold.isFinite ? threshold : kind.defaultThreshold, in: kind.thresholdChoices)
        rule.duration = kind.durationChoices.isEmpty
            ? kind.defaultDuration
            : Self.nearest(to: duration.isFinite ? duration : kind.defaultDuration, in: kind.durationChoices)
        return rule
    }

    private static func nearest(to value: Double, in choices: [Double]) -> Double {
        choices.min { abs($0 - value) < abs($1 - value) } ?? value
    }

    public var spec: ThresholdSpec {
        ThresholdSpec(direction: kind.direction, trigger: threshold, clear: kind.clearLevel(for: threshold),
                      minDuration: duration, clearDuration: min(duration, 30), cooldown: kind.cooldown,
                      staleAfter: kind.isEventDriven ? .infinity : 900)
    }

    /// One disabled rule per kind, in declaration order.
    public static var defaults: [AlertRule] { AlertKind.allCases.map { AlertRule(kind: $0) } }

    /// Decodes a stored list, ignoring unknown kinds and repairing values; every kind
    /// appears exactly once, missing ones as disabled defaults.
    public static func decode(_ data: Data?) -> [AlertRule] {
        merged(with: data.flatMap { try? JSONDecoder().decode([Lossy].self, from: $0) }?.compactMap(\.rule) ?? [])
    }

    public static func merged(with stored: [AlertRule]) -> [AlertRule] {
        AlertKind.allCases.map { kind in
            stored.last { $0.kind == kind }?.sanitized() ?? AlertRule(kind: kind)
        }
    }

    public static func encode(_ rules: [AlertRule]) -> Data? { try? JSONEncoder().encode(rules) }

    /// Decodes an element or yields nil, so one unknown kind does not discard the list.
    private struct Lossy: Decodable {
        var rule: AlertRule?
        init(from decoder: Decoder) throws { rule = try? AlertRule(from: decoder) }
    }
}

/// A rule fired or recovered.
public struct AlertEvent: Sendable, Equatable {
    public var kind: AlertKind
    public var transition: ThresholdTransition
    public var value: Double
    public var threshold: Double
    public var date: Date

    public init(kind: AlertKind, transition: ThresholdTransition, value: Double, threshold: Double, date: Date) {
        self.kind = kind
        self.transition = transition
        self.value = value
        self.threshold = threshold
        self.date = date
    }
}
