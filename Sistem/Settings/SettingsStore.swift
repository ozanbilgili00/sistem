import AppKit
import Observation
import SystemKit

/// User preferences, persisted in UserDefaults. Each property writes through on
/// change; side effects (appearance, Dock icon) apply immediately.
@Observable
final class SettingsStore {
    enum Appearance: String, CaseIterable, Identifiable {
        case system, dark, light
        var id: Self { self }
    }

    enum TemperatureUnit: String, CaseIterable, Identifiable {
        case celsius, fahrenheit
        var id: Self { self }
        var symbol: String { self == .celsius ? "°C" : "°F" }
        func convert(_ celsius: Float) -> Float { self == .celsius ? celsius : celsius * 9 / 5 + 32 }
    }

    /// Typed keys: a typo here is a compile error, not a silently lost setting.
    private enum Key {
        static let appearance = "appearance"
        static let showInDock = "showInDock"
        static let updateInterval = "updateInterval"
        static let slowDownOnBattery = "slowDownOnBattery"
        static let temperatureUnit = "temperatureUnit"
        static let menuBarModules = "menuBarModules"
        static let widgets = "menuBarWidgets"
        static let cpuShowCores = "cpu.showCores"
        static let cpuShowLoadAverage = "cpu.showLoadAverage"
        static let cpuShowProcesses = "cpu.showProcesses"
        static let ramShowProcesses = "ram.showProcesses"
        static let gpuShowPower = "gpu.showPower"
        static let sensorsStack = "sensors.stack"
        static let networkPublicIP = "network.publicIP"
        static let networkLatency = "network.latency"
        static let clockPattern = "clock.pattern"
        static let clockZones = "clock.zones"
        static let powerProfile = "powerProfile"
        static let alertRules = "alertRules"
        static let keepAwakeEnabled = "keepAwake.enabled"
        static let keepAwakeDisplay = "keepAwake.keepDisplay"
        static let keepAwakeTriggers = "keepAwake.triggers"
        static let keepAwakeNetwork = "keepAwake.networkThreshold"
        static let keepAwakeDuration = "keepAwake.defaultDuration"
        static let displayEnabled = "display.enabled"
        static let displayMenuBar = "display.menuBar"
    }

    /// Choices offered for the update interval, in seconds.
    static let intervalChoices: [Double] = [1, 2, 3, 5]

    @ObservationIgnored private let defaults: UserDefaults

    var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance); applyAppearance() }
    }
    var showInDock: Bool {
        didSet { defaults.set(showInDock, forKey: Key.showInDock); applyDockPolicy() }
    }
    var updateInterval: Double {
        didSet { defaults.set(updateInterval, forKey: Key.updateInterval) }
    }
    var slowDownOnBattery: Bool {
        didSet { defaults.set(slowDownOnBattery, forKey: Key.slowDownOnBattery) }
    }
    var temperatureUnit: TemperatureUnit {
        didSet { defaults.set(temperatureUnit.rawValue, forKey: Key.temperatureUnit) }
    }

    /// Automatic follows "slow down on battery"; the other two override it (PowerProfile).
    var powerProfile: PowerProfile {
        didSet { defaults.set(powerProfile.rawValue, forKey: Key.powerProfile) }
    }

    /// Notification rules, one per kind, all off until the user turns them on.
    var alertRules: [AlertRule] {
        didSet { defaults.set(AlertRule.encode(alertRules), forKey: Key.alertRules) }
    }

    /// Keep Awake: the module, its cup icon and the smart triggers are all off until the user turns them on.
    var keepAwakeEnabled: Bool {
        didSet { defaults.set(keepAwakeEnabled, forKey: Key.keepAwakeEnabled) }
    }
    /// Also hold the display on. Off = the display may turn off while the Mac stays awake.
    var keepAwakeDisplay: Bool {
        didSet { defaults.set(keepAwakeDisplay, forKey: Key.keepAwakeDisplay) }
    }
    var keepAwakeTriggers: Set<AwakeTrigger> {
        didSet { defaults.set(keepAwakeTriggers.map(\.rawValue).sorted(), forKey: Key.keepAwakeTriggers) }
    }
    /// Bytes per second that count as a big transfer.
    var keepAwakeNetworkThreshold: Double {
        didSet { defaults.set(keepAwakeNetworkThreshold, forKey: Key.keepAwakeNetwork) }
    }
    /// Seconds a click on the cup holds the Mac awake; 0 = until stopped.
    var keepAwakeDuration: Double {
        didSet { defaults.set(keepAwakeDuration, forKey: Key.keepAwakeDuration) }
    }

    var keepAwakeConfig: KeepAwakeConfig {
        KeepAwakeConfig(enabled: keepAwakeEnabled, keepDisplayOn: keepAwakeDisplay, triggers: keepAwakeTriggers,
                        networkThreshold: keepAwakeNetworkThreshold)
    }

    /// Display module: watching and controlling the displays. Reading is event driven and free, so it starts on.
    var displayEnabled: Bool {
        didSet { defaults.set(displayEnabled, forKey: Key.displayEnabled) }
    }
    /// The monitor icon in the menu bar; off until the user turns it on.
    var displayMenuBar: Bool {
        didSet { defaults.set(displayMenuBar, forKey: Key.displayMenuBar) }
    }

    static let keepAwakeDurationChoices: [Double] = [1_800, 3_600, 10_800, 28_800, 0]

    /// Launch at login is the system's state, not ours: it is read from `SMAppService`, never stored or exported.
    @ObservationIgnored let loginItem = LoginItem()
    var menuBarModules: [ModuleID] {
        didSet { defaults.set(menuBarModules.map(\.rawValue), forKey: Key.menuBarModules) }
    }

    /// Which widgets each module draws in the menu bar. Modules not in the map use
    /// ``WidgetConfig/default``.
    var widgets: [ModuleID: WidgetConfig] {
        didSet {
            let encoded = Dictionary(uniqueKeysWithValues: widgets.map { ($0.key.rawValue, $0.value) })
            defaults.set(try? JSONEncoder().encode(encoded), forKey: Key.widgets)
        }
    }
    var cpuShowCores: Bool {
        didSet { defaults.set(cpuShowCores, forKey: Key.cpuShowCores) }
    }
    var cpuShowLoadAverage: Bool {
        didSet { defaults.set(cpuShowLoadAverage, forKey: Key.cpuShowLoadAverage) }
    }

    /// Top-process lists in popovers. Each costs a `ps` call every other tick
    /// while the popover is open.
    var cpuShowProcesses: Bool {
        didSet { defaults.set(cpuShowProcesses, forKey: Key.cpuShowProcesses) }
    }
    var ramShowProcesses: Bool {
        didSet { defaults.set(ramShowProcesses, forKey: Key.ramShowProcesses) }
    }

    /// GPU and Neural Engine watts in the GPU popover. Reading them means sampling
    /// IOReport (~4 ms of CPU a tick) while the popover is open, so it can be turned off.
    var gpuShowPower: Bool {
        didSet { defaults.set(gpuShowPower, forKey: Key.gpuShowPower) }
    }

    /// Both off until the user asks: with the defaults the app makes no outbound
    /// request at all (PLAN.md §3-E). The public address is looked up only when the
    /// connection changes; latency is measured every 60 s while the network is on
    /// screen and the Mac is on power.
    var networkPublicIP: Bool {
        didSet { defaults.set(networkPublicIP, forKey: Key.networkPublicIP) }
    }
    var networkLatency: Bool {
        didSet { defaults.set(networkLatency, forKey: Key.networkLatency) }
    }

    /// The sensors menu bar item as two lines, CPU over GPU, instead of one CPU number.
    /// The GPU line reads 42 more SMC keys (~0.2 ms of CPU) every other tick.
    var sensorsStack: Bool {
        didSet { defaults.set(sensorsStack, forKey: Key.sensorsStack) }
    }

    /// `DateFormatter` pattern of the clock menu bar item; empty follows the system's time style.
    /// The item redraws once a minute, or once a second only when the pattern has seconds.
    var clockPattern: String {
        didSet {
            let clean = ClockFormat.sanitized(clockPattern)
            if clean != clockPattern { clockPattern = clean; return }
            defaults.set(clockPattern, forKey: Key.clockPattern)
        }
    }

    /// Time zone identifiers shown next to local time, in the order added.
    var clockZones: [String] {
        didSet { defaults.set(clockZones, forKey: Key.clockZones) }
    }

    static let clockZoneLimit = 8

    var clockDisplay: ClockDisplay { ClockDisplay(pattern: clockPattern.isEmpty ? ClockFormat.defaultPattern() : clockPattern) }

    func addClockZone(_ identifier: String) {
        guard TimeZone(identifier: identifier) != nil, !clockZones.contains(identifier), clockZones.count < Self.clockZoneLimit else { return }
        clockZones.append(identifier)
    }

    var sensorsDisplay: SensorsDisplay { SensorsDisplay(unit: temperatureUnit, stacked: sensorsStack) }

    func widget(for module: ModuleID) -> WidgetConfig {
        widgets[module] ?? (module == .battery || module == .clock ? .plain : .default)
    }

    func setWidget(_ config: WidgetConfig, for module: ModuleID) { widgets[module] = config }

    func isInMenuBar(_ module: ModuleID) -> Bool { menuBarModules.contains(module) }

    /// Adds or removes a module, keeping the default left-to-right order.
    func setInMenuBar(_ module: ModuleID, _ shown: Bool) {
        var set = Set(menuBarModules)
        if shown { set.insert(module) } else { set.remove(module) }
        menuBarModules = ModuleID.allCases.filter(set.contains)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = defaults.string(forKey: Key.appearance).flatMap(Appearance.init) ?? .system
        showInDock = defaults.object(forKey: Key.showInDock) as? Bool ?? false
        updateInterval = defaults.object(forKey: Key.updateInterval) as? Double ?? 2
        slowDownOnBattery = defaults.object(forKey: Key.slowDownOnBattery) as? Bool ?? true
        temperatureUnit = defaults.string(forKey: Key.temperatureUnit).flatMap(TemperatureUnit.init) ?? .celsius
        powerProfile = defaults.string(forKey: Key.powerProfile).flatMap(PowerProfile.init) ?? .automatic
        alertRules = AlertRule.decode(defaults.data(forKey: Key.alertRules))
        keepAwakeEnabled = defaults.object(forKey: Key.keepAwakeEnabled) as? Bool ?? false
        keepAwakeDisplay = defaults.object(forKey: Key.keepAwakeDisplay) as? Bool ?? false
        keepAwakeTriggers = Set((defaults.stringArray(forKey: Key.keepAwakeTriggers) ?? []).compactMap(AwakeTrigger.init))
        keepAwakeNetworkThreshold = Self.snapNetwork(defaults.object(forKey: Key.keepAwakeNetwork) as? Double)
        keepAwakeDuration = Self.snapDuration(defaults.object(forKey: Key.keepAwakeDuration) as? Double)
        displayEnabled = defaults.object(forKey: Key.displayEnabled) as? Bool ?? true
        displayMenuBar = defaults.object(forKey: Key.displayMenuBar) as? Bool ?? false
        menuBarModules = (defaults.stringArray(forKey: Key.menuBarModules)?.compactMap(ModuleID.init))
            ?? ModuleID.defaultMenuBar
        let stored = defaults.data(forKey: Key.widgets)
            .flatMap { try? JSONDecoder().decode([String: WidgetConfig].self, from: $0) } ?? [:]
        widgets = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            ModuleID(rawValue: key).map { ($0, value) }
        })
        cpuShowCores = defaults.object(forKey: Key.cpuShowCores) as? Bool ?? true
        cpuShowLoadAverage = defaults.object(forKey: Key.cpuShowLoadAverage) as? Bool ?? true
        cpuShowProcesses = defaults.object(forKey: Key.cpuShowProcesses) as? Bool ?? true
        ramShowProcesses = defaults.object(forKey: Key.ramShowProcesses) as? Bool ?? true
        gpuShowPower = defaults.object(forKey: Key.gpuShowPower) as? Bool ?? true
        sensorsStack = defaults.object(forKey: Key.sensorsStack) as? Bool ?? false
        networkPublicIP = defaults.object(forKey: Key.networkPublicIP) as? Bool ?? false
        networkLatency = defaults.object(forKey: Key.networkLatency) as? Bool ?? false
        clockPattern = ClockFormat.sanitized(defaults.string(forKey: Key.clockPattern) ?? "")
        clockZones = Array((defaults.stringArray(forKey: Key.clockZones) ?? []).filter { TimeZone(identifier: $0) != nil }.prefix(Self.clockZoneLimit))
    }

    private static func snapNetwork(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return AwakeTrigger.defaultNetworkThreshold }
        return AwakeTrigger.networkThresholdChoices.min { abs($0 - value) < abs($1 - value) } ?? AwakeTrigger.defaultNetworkThreshold
    }

    private static func snapDuration(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 3_600 }
        return keepAwakeDurationChoices.contains(value) ? value : 3_600
    }

    func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        }
    }

    func applyDockPolicy() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    // MARK: Export, import, reset

    /// Every exportable setting as JSON-compatible values.
    func exportValues() -> [String: Any] {
        var values: [String: Any] = [
            Key.appearance: appearance.rawValue,
            Key.showInDock: showInDock,
            Key.updateInterval: updateInterval,
            Key.slowDownOnBattery: slowDownOnBattery,
            Key.powerProfile: powerProfile.rawValue,
            Key.temperatureUnit: temperatureUnit.rawValue,
            Key.menuBarModules: menuBarModules.map(\.rawValue),
            Key.cpuShowCores: cpuShowCores,
            Key.cpuShowLoadAverage: cpuShowLoadAverage,
            Key.cpuShowProcesses: cpuShowProcesses,
            Key.ramShowProcesses: ramShowProcesses,
            Key.gpuShowPower: gpuShowPower,
            Key.sensorsStack: sensorsStack,
            Key.networkPublicIP: networkPublicIP,
            Key.networkLatency: networkLatency,
            Key.clockPattern: clockPattern,
            Key.clockZones: clockZones,
            Key.keepAwakeEnabled: keepAwakeEnabled,
            Key.keepAwakeDisplay: keepAwakeDisplay,
            Key.keepAwakeTriggers: keepAwakeTriggers.map(\.rawValue).sorted(),
            Key.keepAwakeNetwork: keepAwakeNetworkThreshold,
            Key.keepAwakeDuration: keepAwakeDuration,
            Key.displayEnabled: displayEnabled,
            Key.displayMenuBar: displayMenuBar,
        ]
        let encoded = Dictionary(uniqueKeysWithValues: widgets.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(encoded), let object = try? JSONSerialization.jsonObject(with: data) {
            values[Key.widgets] = object
        }
        if let data = AlertRule.encode(alertRules), let object = try? JSONSerialization.jsonObject(with: data) {
            values[Key.alertRules] = object
        }
        return values
    }

    func exportData() throws -> Data { try SettingsArchive.encode(exportValues()) }

    /// What an import did, for the confirmation line.
    struct ImportResult: Equatable {
        var applied = 0
        var ignored = 0
    }

    /// Applies the settings in `data`, key by key. A value of the wrong type or outside its
    /// allowed set is skipped and counted; unknown keys are ignored. Throws only if the file
    /// is not a Sistem settings file (SettingsArchive.Failure).
    @discardableResult
    func importData(_ data: Data) throws -> ImportResult {
        let values = try SettingsArchive.decode(data)
        var result = ImportResult()
        func take<T>(_ key: String, _ convert: (Any) -> T?, _ assign: (T) -> Void) {
            guard let raw = values[key] else { return }
            if let value = convert(raw) { assign(value); result.applied += 1 } else { result.ignored += 1 }
        }
        func bool(_ raw: Any) -> Bool? { (raw as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil } }
        func strings(_ raw: Any) -> [String]? { raw as? [String] }

        take(Key.appearance, { ($0 as? String).flatMap(Appearance.init) }) { appearance = $0; applyAppearance() }
        take(Key.showInDock, bool) { showInDock = $0 }
        take(Key.updateInterval, { ($0 as? Double).flatMap { Self.intervalChoices.contains($0) ? $0 : nil } }) { updateInterval = $0 }
        take(Key.slowDownOnBattery, bool) { slowDownOnBattery = $0 }
        take(Key.powerProfile, { ($0 as? String).flatMap(PowerProfile.init) }) { powerProfile = $0 }
        take(Key.temperatureUnit, { ($0 as? String).flatMap(TemperatureUnit.init) }) { temperatureUnit = $0 }
        take(Key.menuBarModules, { strings($0).map { $0.compactMap(ModuleID.init) } }) { chosen in
            menuBarModules = ModuleID.allCases.filter(Set(chosen).contains)
        }
        take(Key.cpuShowCores, bool) { cpuShowCores = $0 }
        take(Key.cpuShowLoadAverage, bool) { cpuShowLoadAverage = $0 }
        take(Key.cpuShowProcesses, bool) { cpuShowProcesses = $0 }
        take(Key.ramShowProcesses, bool) { ramShowProcesses = $0 }
        take(Key.gpuShowPower, bool) { gpuShowPower = $0 }
        take(Key.sensorsStack, bool) { sensorsStack = $0 }
        take(Key.networkPublicIP, bool) { networkPublicIP = $0 }
        take(Key.networkLatency, bool) { networkLatency = $0 }
        take(Key.clockPattern, { ($0 as? String).map(ClockFormat.sanitized) }) { clockPattern = $0 }
        take(Key.clockZones, { strings($0).map { Array($0.filter { TimeZone(identifier: $0) != nil }.prefix(Self.clockZoneLimit)) } }) { clockZones = $0 }
        take(Key.keepAwakeEnabled, bool) { keepAwakeEnabled = $0 }
        take(Key.keepAwakeDisplay, bool) { keepAwakeDisplay = $0 }
        take(Key.keepAwakeTriggers, { strings($0).map { Set($0.compactMap(AwakeTrigger.init)) } }) { keepAwakeTriggers = $0 }
        take(Key.keepAwakeNetwork, { ($0 as? Double).flatMap { AwakeTrigger.networkThresholdChoices.contains($0) ? $0 : nil } }) { keepAwakeNetworkThreshold = $0 }
        take(Key.keepAwakeDuration, { ($0 as? Double).flatMap { Self.keepAwakeDurationChoices.contains($0) ? $0 : nil } }) { keepAwakeDuration = $0 }
        take(Key.displayEnabled, bool) { displayEnabled = $0 }
        take(Key.displayMenuBar, bool) { displayMenuBar = $0 }
        take(Key.widgets, { raw -> [ModuleID: WidgetConfig]? in
            guard JSONSerialization.isValidJSONObject(raw), let data = try? JSONSerialization.data(withJSONObject: raw),
                  let decoded = try? JSONDecoder().decode([String: WidgetConfig].self, from: data) else { return nil }
            return Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in ModuleID(rawValue: key).map { ($0, value) } })
        }) { widgets = $0 }
        take(Key.alertRules, { raw -> [AlertRule]? in
            guard JSONSerialization.isValidJSONObject(raw), let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
            return AlertRule.decode(data)
        }) { alertRules = $0 }
        return result
    }

    /// Back to the factory defaults. Notification rules go off too; the launch-at-login
    /// registration belongs to the system and is left alone.
    func resetToDefaults() {
        appearance = .system
        showInDock = false
        updateInterval = 2
        slowDownOnBattery = true
        powerProfile = .automatic
        temperatureUnit = .celsius
        menuBarModules = ModuleID.defaultMenuBar
        widgets = [:]
        cpuShowCores = true
        cpuShowLoadAverage = true
        cpuShowProcesses = true
        ramShowProcesses = true
        gpuShowPower = true
        sensorsStack = false
        networkPublicIP = false
        networkLatency = false
        clockPattern = ""
        clockZones = []
        alertRules = AlertRule.defaults
        keepAwakeEnabled = false
        keepAwakeDisplay = false
        keepAwakeTriggers = []
        keepAwakeNetworkThreshold = AwakeTrigger.defaultNetworkThreshold
        keepAwakeDuration = 3_600
        displayEnabled = true
        displayMenuBar = false
        applyAppearance()
    }
}
