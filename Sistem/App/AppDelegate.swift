import AppKit
import Observation
import SystemKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private let engine = SamplingEngine()
    private let notifier = AlertNotifier()
    private lazy var alerts = AlertCenter(store: engine.store, demand: engine.demand) { [weak self] event in
        guard let self else { return }
        notifier.post(event, unit: settings.temperatureUnit)
    }
    private let keepAwake = KeepAwakeModel()
    private lazy var mainWindow = MainWindowController(settings: settings, engine: engine, notifier: notifier, keepAwake: keepAwake)
    private var keepAwakeItem: KeepAwakeStatusItem?
    private var hadEnabledRules = false
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings.applyAppearance()
        settings.applyDockPolicy()
        // Only the click handler: the permission is requested when the user enables a rule, never here.
        notifier.activate()
        notifier.open = { [weak self] module in self?.mainWindow.show(page: .module(module)) }
        hadEnabledRules = settings.alertRules.contains(where: \.enabled)
        if hadEnabledRules { notifier.refresh() }
        keepAwake.onProtection = { [weak self] event in
            if case .protectionTripped(let reason) = event { self?.notifier.postKeepAwake(reason) }
        }
        syncEngineSettings()
        // Launch silently into the menu bar; never pull a window to the front on
        // start, so the app doesn't steal focus from whatever the user is doing.
        statusBar = StatusBarController(settings: settings, engine: engine) { [weak self] page in
            self?.mainWindow.show(page: page)
        }
        syncKeepAwake()
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--measure-window") {
            let page = args.indices.contains(i + 1) ? Page(rawValue: args[i + 1]) : .module(.cpu)
            mainWindow.openOffscreenForMeasurement(page: page)
        }
    }

    /// Keeps the sampler's interval, the optional network lookups and the notification rules in step with the settings.
    private func syncEngineSettings() {
        engine.baseInterval = withObservationTracking {
            engine.slowDownOnBattery = settings.slowDownOnBattery
            engine.profile = settings.powerProfile
            let rules = settings.alertRules
            alerts.apply(rules)
            let anyEnabled = rules.contains(where: \.enabled)
            if anyEnabled, !hadEnabledRules { notifier.requestIfNeeded() }
            hadEnabledRules = anyEnabled
            engine.network.publicIPEnabled = settings.networkPublicIP
            engine.network.latencyEnabled = settings.networkLatency
            return settings.updateInterval
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.syncEngineSettings() } }
        }
    }

    /// Keeps the Keep Awake controller and its menu bar item in step with the settings.
    private func syncKeepAwake() {
        let config = withObservationTracking {
            settings.keepAwakeConfig
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.syncKeepAwake() } }
        }
        keepAwake.apply(config)
        syncKeepAwakeItem(enabled: config.enabled)
    }

    /// The cup exists only while the module is on.
    private func syncKeepAwakeItem(enabled: Bool) {
        if enabled, keepAwakeItem == nil {
            keepAwakeItem = KeepAwakeStatusItem(model: keepAwake, settings: settings, engine: engine) { [weak self] page in
                self?.mainWindow.show(page: page)
            }
        } else if !enabled, let item = keepAwakeItem {
            item.remove()
            keepAwakeItem = nil
        }
    }

    /// Clicking the Dock icon (when "Dock'ta göster" is on) reopens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow.show(page: nil)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
