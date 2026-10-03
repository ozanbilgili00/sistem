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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = defaults.string(forKey: Key.appearance).flatMap(Appearance.init) ?? .system
        showInDock = defaults.object(forKey: Key.showInDock) as? Bool ?? false
        updateInterval = defaults.object(forKey: Key.updateInterval) as? Double ?? 2
        slowDownOnBattery = defaults.object(forKey: Key.slowDownOnBattery) as? Bool ?? true
        temperatureUnit = defaults.string(forKey: Key.temperatureUnit).flatMap(TemperatureUnit.init) ?? .celsius
        menuBarModules = (defaults.stringArray(forKey: Key.menuBarModules)?.compactMap(ModuleID.init))
            ?? ModuleID.defaultMenuBar
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
