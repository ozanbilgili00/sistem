import Foundation

/// A reading of everything the protection looks at.
public struct GuardInput: Sendable, Equatable {
    /// nil on a Mac without a battery.
    public var batteryPercent: Int?
    public var onBattery: Bool
    public var thermal: ProcessInfo.ThermalState
    /// Hottest SMC sensor, °C.
    public var hottest: Float?

    public init(batteryPercent: Int? = nil, onBattery: Bool = false, thermal: ProcessInfo.ThermalState = .nominal, hottest: Float? = nil) {
        self.batteryPercent = batteryPercent
        self.onBattery = onBattery
        self.thermal = thermal
        self.hottest = hottest
    }
}

/// The limits. PLAN.md Faz 9: battery <= 15 % on battery, thermal state >= serious, or the
/// hottest sensor >= 90 C for 60 s; hold again once it is back under 75 C.
public struct GuardLimits: Sendable, Equatable {
    public var batteryTrigger = 15.0
    public var batteryClear = 20.0
    public var temperatureTrigger = 90.0
    public var temperatureClear = 75.0
    public var temperatureDuration: TimeInterval = 60
    /// A gap between readings longer than this restarts the clocks (sleep, a paused loop).
    public var staleAfter: TimeInterval = 150

    public init() {}
}

/// The always-on protection: three hysteresis machines, any of which being active blocks holding.
public struct KeepAwakeGuard: Sendable, Equatable {
    public enum Change: Sendable, Equatable {
        case tripped(ProtectionReason)
        case cleared
    }

    private var battery: ThresholdMachine
    private var thermal: ThresholdMachine
    private var temperature: ThresholdMachine

    public init(_ limits: GuardLimits = GuardLimits()) {
        battery = ThresholdMachine(ThresholdSpec(direction: .below, trigger: limits.batteryTrigger, clear: limits.batteryClear,
                                                 staleAfter: limits.staleAfter))
        // serious (2) or critical (3) trips; back to fair (1) or nominal (0) recovers.
        thermal = ThresholdMachine(ThresholdSpec(direction: .above, trigger: 2, clear: 1, staleAfter: limits.staleAfter))
        temperature = ThresholdMachine(ThresholdSpec(direction: .above, trigger: limits.temperatureTrigger, clear: limits.temperatureClear,
                                                     minDuration: limits.temperatureDuration, staleAfter: limits.staleAfter))
    }

    /// The reason the Mac must not be held, or nil.
    public var tripped: ProtectionReason? {
        if battery.isActive { return .battery }
        if thermal.isActive { return .thermalState }
        if temperature.isActive { return .temperature }
        return nil
    }

    @discardableResult
    public mutating func feed(_ input: GuardInput, at now: Date) -> Change? {
        let before = tripped
        // On power the battery condition is over by definition, whatever the charge.
        let level = input.batteryPercent.map { input.onBattery ? Double($0) : 100 }
        _ = battery.feed(level, at: now)
        _ = thermal.feed(Double(Self.rank(input.thermal)), at: now)
        _ = temperature.feed(input.hottest.map(Double.init), at: now)
        let after = tripped
        switch (before, after) {
        case (nil, let reason?): return .tripped(reason)
        case (_?, nil): return .cleared
        default: return nil
        }
    }

    static func rank(_ state: ProcessInfo.ThermalState) -> Int {
        switch state {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        @unknown default: 3
        }
    }
}
