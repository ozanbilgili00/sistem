import AppKit
import Observation
import SystemKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private let engine = SamplingEngine()
    private lazy var mainWindow = MainWindowController(settings: settings, engine: engine)
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings.applyAppearance()
        settings.applyDockPolicy()
        syncEngineSettings()
        // Launch silently into the menu bar; never pull a window to the front on
        // start, so the app doesn't steal focus from whatever the user is doing.
        statusBar = StatusBarController(settings: settings, engine: engine) { [weak self] page in
            self?.mainWindow.show(page: page)
        }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--measure-window") {
            let page = args.indices.contains(i + 1) ? Page(rawValue: args[i + 1]) : .module(.cpu)
            mainWindow.openOffscreenForMeasurement(page: page)
        }
    }

    /// Keeps the sampler's interval in step with the settings.
    private func syncEngineSettings() {
        engine.baseInterval = withObservationTracking {
            engine.slowDownOnBattery = settings.slowDownOnBattery
            return settings.updateInterval
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.syncEngineSettings() } }
        }
    }

    /// Clicking the Dock icon (when "Dock'ta göster" is on) reopens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow.show(page: nil)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
