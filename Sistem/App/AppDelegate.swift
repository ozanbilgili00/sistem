import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private lazy var mainWindow = MainWindowController(settings: settings)
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings.applyAppearance()
        settings.applyDockPolicy()
        // Launch silently into the menu bar; never pull a window to the front on
        // start, so the app doesn't steal focus from whatever the user is doing.
        statusBar = StatusBarController { [weak self] in self?.mainWindow.show() }
    }

    /// Clicking the Dock icon (when "Dock'ta göster" is on) reopens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
