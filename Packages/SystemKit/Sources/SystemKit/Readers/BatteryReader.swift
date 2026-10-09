import Foundation
import IOKit
import IOKit.ps

/// What the Mac's internal battery is doing, from the power-source API (the same
/// numbers `pmset -g batt` and the system menu print).
public struct BatterySample: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case discharging
        case charging
        /// Full and on power.
        case charged
        /// On power but not taking charge: a charge limit, optimised charging, or heat.
        case pluggedNotCharging
    }

    /// 0...100.
    public var percent: Int
    public var state: State
    /// Minutes until empty (discharging) or full (charging). nil when the system has no
    /// estimate; see ``isEstimating``.
    public var minutesRemaining: Int?
    /// The system is still working out the estimate (it reports -1 for a while after
    /// a power change).
    public var isEstimating: Bool
    public var isOnPower: Bool { state != .discharging }
    public var health: BatteryHealth?
    /// The charger, while one is connected.
    public var adapter: AdapterInfo?

    public init(percent: Int, state: State, minutesRemaining: Int? = nil, isEstimating: Bool = false,
                health: BatteryHealth? = nil, adapter: AdapterInfo? = nil) {
        self.percent = percent
        self.state = state
        self.minutesRemaining = minutesRemaining
        self.isEstimating = isEstimating
        self.health = health
        self.adapter = adapter
    }

    /// "H:MM", the way `pmset -g batt` writes it.
    public var remainingText: String? {
        guard let minutes = minutesRemaining else { return nil }
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}

/// Battery condition and electrical state, from the `AppleSmartBattery` service.
public struct BatteryHealth: Sendable, Equatable {
    /// Capacity the battery can hold now against what it held new, whole percent, at most 100
    /// (System Information's "Maximum Capacity").
    public var maximumCapacityPercent: Int?
    /// mAh.
    public var designCapacity: Int?
    public var nominalCapacity: Int?
    public var cycleCount: Int?
    public var designCycleCount: Int?
    /// Average of the pack's temperature sensors.
    public var temperatureCelsius: Double?
    public var volts: Double?
    /// Positive while charging, negative while discharging.
    public var amps: Double?
    /// Volts × amps: into (+) or out of (−) the battery.
    public var batteryWatts: Double? {
        guard let volts, let amps else { return nil }
        return volts * amps
    }
    /// What the whole machine is drawing right now.
    public var systemWatts: Double?

    public init(maximumCapacityPercent: Int? = nil, designCapacity: Int? = nil, nominalCapacity: Int? = nil,
                cycleCount: Int? = nil, designCycleCount: Int? = nil, temperatureCelsius: Double? = nil,
                volts: Double? = nil, amps: Double? = nil, systemWatts: Double? = nil) {
        self.maximumCapacityPercent = maximumCapacityPercent
        self.designCapacity = designCapacity
        self.nominalCapacity = nominalCapacity
        self.cycleCount = cycleCount
        self.designCycleCount = designCycleCount
        self.temperatureCelsius = temperatureCelsius
        self.volts = volts
        self.amps = amps
        self.systemWatts = systemWatts
    }
}

/// The connected charger. Serial numbers and other identifiers are deliberately left out.
public struct AdapterInfo: Sendable, Equatable {
    public var watts: Int?
    public var name: String?
    public var isWireless: Bool

    public init(watts: Int?, name: String?, isWireless: Bool = false) {
        self.watts = watts
        self.name = name
        self.isWireless = isWireless
    }
}

/// Battery is either not there (a desktop Mac) or described.
public enum BatteryStatus: Sendable, Equatable {
    case notPresent
    case present(BatterySample)

    public var sample: BatterySample? {
        if case .present(let sample) = self { sample } else { nil }
    }
}

/// Reads the internal battery.
///
/// Percentage, state and time remaining come from the power-source API, which is told
/// of changes by `IOPSNotificationCreateRunLoopSource`: nothing polls for them. A change
/// only sets a flag (and calls ``onChange``); the next ``sample()`` rereads. The electrical
/// details (voltage, current, temperature, cycles) come from the `AppleSmartBattery`
/// registry entry, ten properties at ~0.1 ms, whenever a sample is taken.
///
/// Not thread-safe: confine to one executor. ``onChange`` is called on the main thread.
public final class BatteryReader {
    private let service: io_service_t
    private var watcher: PowerSourceWatcher?
    private var smc: SMC?
    private var smcTried = false
    private var cachedPower: (state: BatterySample, present: Bool)?
    private var cachedAdapter: AdapterInfo?
    private var dirty = true
    /// Power-source reads, for the tests and the diagnostics page: stays flat while nothing changes.
    public private(set) var powerSourceReads = 0

    /// `onChange` runs on the main thread after the system reports a power-source change.
    public init(onChange: (@Sendable () -> Void)? = nil) {
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if let onChange { watcher = PowerSourceWatcher(onChange) }
    }

    deinit {
        watcher?.stop()
        if service != IO_OBJECT_NULL { IOObjectRelease(service) }
    }

    /// The next ``sample()`` rereads the power source.
    public func markChanged() { dirty = true }

    public func sample() -> BatteryStatus {
        if dirty || cachedPower == nil { refreshPower() }
        guard let cached = cachedPower, cached.present else { return .notPresent }
        var sample = cached.state
        sample.health = readHealth()
        sample.adapter = sample.isOnPower ? cachedAdapter : nil
        return .present(sample)
    }

    // MARK: Power source

    private func refreshPower() {
        dirty = false
        powerSourceReads += 1
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() else {
            cachedPower = (BatterySample(percent: 0, state: .discharging), false)
            return
        }
        var found: BatterySample?
        for index in 0..<CFArrayGetCount(list) {
            let source = CFArrayGetValueAtIndex(list, index)
            guard let description = IOPSGetPowerSourceDescription(info, unsafeBitCast(source, to: CFTypeRef.self))?
                .takeUnretainedValue() else { continue }
            if let parsed = Self.parse(description) {
                found = parsed
                break
            }
        }
        cachedPower = (found ?? BatterySample(percent: 0, state: .discharging), found != nil)
        if let found, found.isOnPower {
            cachedAdapter = IOPSCopyExternalPowerAdapterDetails().flatMap { Self.parseAdapter($0.takeRetainedValue()) }
        } else {
            cachedAdapter = nil
        }
    }

    /// One power-source description. nil when it isn't an internal battery that is present.
    static func parse(_ description: CFDictionary) -> BatterySample? {
        guard CFReading.string(description, kIOPSTypeKey) == kIOPSInternalBatteryType,
              CFReading.bool(description, kIOPSIsPresentKey) ?? true,
              let current = CFReading.int64(description, kIOPSCurrentCapacityKey),
              let maximum = CFReading.int64(description, kIOPSMaxCapacityKey), maximum > 0 else { return nil }
        let percent = Int((Double(current) / Double(maximum) * 100).rounded())
        let onPower = CFReading.string(description, kIOPSPowerSourceStateKey) == kIOPSACPowerValue
        let charging = CFReading.bool(description, kIOPSIsChargingKey) ?? false
        let charged = CFReading.bool(description, kIOPSIsChargedKey) ?? false
        let state: BatterySample.State = !onPower ? .discharging : charging ? .charging : charged ? .charged : .pluggedNotCharging

        // Minutes; -1 while the system is still estimating, 0 where no estimate applies.
        let key = switch state {
        case .discharging: kIOPSTimeToEmptyKey
        case .charging: kIOPSTimeToFullChargeKey
        default: nil as String?
        }
        var minutes: Int?
        var estimating = false
        if let key, let value = CFReading.int64(description, key) {
            if value > 0 && value < 100_000 { minutes = Int(value) } else if value < 0 { estimating = true }
        }
        return BatterySample(percent: max(0, min(100, percent)), state: state, minutesRemaining: minutes, isEstimating: estimating)
    }

    static func parseAdapter(_ details: CFDictionary) -> AdapterInfo? {
        let watts = CFReading.int64(details, "Watts").flatMap { (1...1000).contains($0) ? Int($0) : nil }
        let name = CFReading.string(details, "Name")
        guard watts != nil || name != nil else { return nil }
        return AdapterInfo(watts: watts, name: name, isWireless: CFReading.bool(details, "IsWireless") ?? false)
    }

    // MARK: Registry

    private func readHealth() -> BatteryHealth? {
        guard service != IO_OBJECT_NULL else { return nil }
        var health = BatteryHealth()
        health.cycleCount = integer("CycleCount").flatMap { (0...50_000).contains($0) ? Int($0) : nil }
        health.designCycleCount = integer("DesignCycleCount9C").flatMap { (1...50_000).contains($0) ? Int($0) : nil }
        if let data = dictionary("BatteryData") {
            let design = CFReading.int64(data, "DesignCapacity")
            // Apple's "maximum capacity" is the nominal figure over the design one; the full-charge
            // figure also dips with temperature and load.
            let nominal = CFReading.int64(data, "NominalChargeCapacity").flatMap { $0 > 0 ? $0 : nil }
                ?? integer("AppleRawMaxCapacity").flatMap { $0 > 0 ? $0 : nil }
            if let design, design > 0, design < 100_000 {
                health.designCapacity = Int(design)
                if let nominal, nominal < 200_000 {
                    health.nominalCapacity = Int(nominal)
                    health.maximumCapacityPercent = min(100, Int((Double(nominal) / Double(design) * 100).rounded()))
                }
            }
        }
        // Millivolts and milliamps. `Amperage` is signed (it is stored as a 64-bit two's complement).
        if let millivolts = integer("Voltage"), (1...30_000).contains(millivolts) { health.volts = Double(millivolts) / 1000 }
        if let milliamps = integer("InstantAmperage") ?? integer("Amperage"), abs(milliamps) < 30_000 {
            health.amps = Double(milliamps) / 1000
        }
        if let telemetry = dictionary("PowerTelemetryData"),
           let load = CFReading.int64(telemetry, "SystemLoad"), load >= 0, load < 500_000 {
            health.systemWatts = Double(load) / 1000
        }
        health.temperatureCelsius = temperature()
        return health
    }

    /// The registry's own `Temperature` (hundredths of a degree) where macOS publishes it,
    /// otherwise the pack's three SMC sensors (`TB0T`...), averaged.
    private func temperature() -> Double? {
        if let hundredths = integer("Temperature") {
            let celsius = Double(hundredths) / 100
            if SensorValidity.isValidTemperature(celsius) { return celsius }
        }
        if !smcTried {
            smcTried = true
            smc = SMC()
        }
        guard let smc else { return nil }
        let values = ["TB0T", "TB1T", "TB2T"].compactMap { name in
            smc.key(name).flatMap { smc.readNumber($0) }
        }.filter(SensorValidity.isValidTemperature)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private func property(_ key: String) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private func integer(_ key: String) -> Int64? {
        guard let value = property(key), CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        var result: Int64 = 0
        return CFNumberGetValue(unsafeDowncast(value, to: CFNumber.self), .sInt64Type, &result) ? result : nil
    }

    private func dictionary(_ key: String) -> CFDictionary? {
        guard let value = property(key), CFGetTypeID(value) == CFDictionaryGetTypeID() else { return nil }
        return unsafeDowncast(value, to: CFDictionary.self)
    }
}

/// Wraps `IOPSNotificationCreateRunLoopSource` on the main run loop. The callback fires
/// only when the system's power sources change (percent, charger, time estimate).
private final class PowerSourceWatcher {
    private let handler: @Sendable () -> Void
    private var source: CFRunLoopSource?

    init(_ handler: @escaping @Sendable () -> Void) {
        self.handler = handler
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let created = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<PowerSourceWatcher>.fromOpaque(context).takeUnretainedValue().handler()
        }, context)?.takeRetainedValue() else { return }
        source = created
        CFRunLoopAddSource(CFRunLoopGetMain(), created, .commonModes)
    }

    /// Detaches the callback before the object it points at goes away.
    func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        source = nil
    }
}
