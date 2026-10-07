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

    func widget(for module: ModuleID) -> WidgetConfig { widgets[module] ?? .default }

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
}
