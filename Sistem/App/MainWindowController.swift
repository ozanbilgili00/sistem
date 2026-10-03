import AppKit
import SistemUI
import SwiftUI

/// Creates the main window on demand and tears it down completely on close, so a
/// closed window costs neither memory nor SwiftUI updates (PLAN.md §3-D).
final class MainWindowController: NSObject, NSWindowDelegate {
    private let settings: SettingsStore
    private var window: NSWindow?

    init(settings: SettingsStore) {
        self.settings = settings
        super.init()
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        let host = NSHostingController(rootView: MainView(settings: settings))
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(NSSize(width: 1000, height: 660))
        window.contentMinSize = NSSize(width: 820, height: 540)
        window.title = "Sistem"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSPalette.background
        window.isReleasedWhenClosed = false
        window.delegate = self
        if !window.setFrameUsingName("SistemMainWindow") { window.center() }
        window.setFrameAutosaveName("SistemMainWindow")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window?.delegate = nil
        window = nil
    }
}
