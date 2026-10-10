import AppKit
import SistemUI
import SwiftUI
import SystemKit

/// Creates the main window on demand and tears it down completely on close, so a
/// closed window costs neither memory nor SwiftUI updates (PLAN.md §3-D). While
/// the window is fully hidden — behind other windows, minimised, on another
/// Space — its feed is inactive: no redraws, no metric demand (§3-C).
final class MainWindowController: NSObject, NSWindowDelegate {
    private let settings: SettingsStore
    private let engine: SamplingEngine
    private let notifier: AlertNotifier
    private let keepAwake: KeepAwakeModel
    private var window: NSWindow?
    private var feed: LiveFeed?

    init(settings: SettingsStore, engine: SamplingEngine, notifier: AlertNotifier, keepAwake: KeepAwakeModel) {
        self.settings = settings
        self.engine = engine
        self.notifier = notifier
        self.keepAwake = keepAwake
        super.init()
    }

    /// Shows the window, optionally switching to `page` first.
    func show(page: Page?) {
        if let page { UserDefaults.standard.set(page.rawValue, forKey: MainView.pageKey) }
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
        let feed = LiveFeed(engine: engine)
        self.feed = feed
        let host = NSHostingController(rootView: MainView(settings: settings).environment(feed).environment(notifier).environment(keepAwake))
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

    /// `Sistem --measure-window`: builds the window on `page` far off every screen
    /// and keeps it live, so perf-check can measure an open window without the
    /// window ever appearing or taking focus.
    private var measuring = false

    func openOffscreenForMeasurement(page: Page) {
        measuring = true
        UserDefaults.standard.set(page.rawValue, forKey: MainView.pageKey)
        let window = makeWindow()
        window.setFrameAutosaveName("")  // don't remember the off-screen frame
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderBack(nil)
        self.window = window
        feed?.isActive = true
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard !measuring else { return }
        feed?.isActive = window?.occlusionState.contains(.visible) ?? false
    }

    func windowWillClose(_ notification: Notification) {
        feed?.isActive = false
        feed = nil
        window?.contentViewController = nil
        window?.delegate = nil
        window = nil
    }
}
