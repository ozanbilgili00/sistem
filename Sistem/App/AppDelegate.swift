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
    private let display = DisplayModel()
    private let servers = ServersModel()
    private lazy var mainWindow = MainWindowController(settings: settings, engine: engine, notifier: notifier, keepAwake: keepAwake, display: display, servers: servers)
    private var hadEnabledRules = false
    private var hadReachability = false
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
        statusBar = StatusBarController(settings: settings, engine: engine, keepAwake: keepAwake, display: display, servers: servers) { [weak self] page in
            self?.mainWindow.show(page: page)
        }
        syncKeepAwake()
        syncDisplay()
        servers.onServerDown = { [weak self] server in self?.notifier.postServerDown(name: server.name) }
        syncServers()
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
    }

    /// Keeps the display model and its optional menu bar icon in step with the settings.
    private func syncDisplay() {
        let enabled = withObservationTracking {
            settings.displayEnabled
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.syncDisplay() } }
        }
        display.apply(enabled: enabled)
    }

    /// Keeps the servers model and its optional menu bar icon in step with the settings.
    private func syncServers() {
        let config = withObservationTracking {
            settings.serversConfig
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.syncServers() } }
        }
        if config.reachabilityCheck, !hadReachability { notifier.requestIfNeeded() }
        hadReachability = config.reachabilityCheck
        servers.apply(config)
    }

    /// Quitting ends tunnels and shared ssh connections first, but never waits more than three seconds for it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard settings.serversEnabled, !settings.servers.isEmpty else { return .terminateNow }
        let done = ServersModel.TerminationGate()
        Task { @MainActor in
            await self.servers.shutdown()
            if done.fire() { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            ProcessRegistry.shared.terminateAll(grace: 0.2)
            if done.fire() { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    /// A clean quit gives the screens back: a mode trial is reverted, dimming and night tone are released.
    /// If the process dies instead, the system does the same (see DisplayController).
    func applicationWillTerminate(_ notification: Notification) {
        display.shutdown()
    }

    /// Clicking the Dock icon (when "Dock'ta göster" is on) reopens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow.show(page: nil)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
