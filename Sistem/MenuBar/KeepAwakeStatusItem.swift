import AppKit
import SwiftUI
import SystemKit

/// The cup in the menu bar: its own status item, not a metric widget. It redraws only when
/// the state it shows changes (holding or not, blocked or not), never on a timer or tick.
/// Click toggles, right click offers the durations; the popover is in that menu.
final class KeepAwakeStatusItem: NSObject, NSPopoverDelegate {
    private let item: NSStatusItem
    private let model: KeepAwakeModel
    private let settings: SettingsStore
    private let engine: SamplingEngine
    private let openWindow: (Page?) -> Void
    private let popover = NSPopover()
    private var feed: LiveFeed?

    init(model: KeepAwakeModel, settings: SettingsStore, engine: SamplingEngine, openWindow: @escaping (Page?) -> Void) {
        self.model = model
        self.settings = settings
        self.engine = engine
        self.openWindow = openWindow
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.autosaveName = "Sistem.keepAwake"
        popover.behavior = .transient
        popover.delegate = self
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        model.onVisibleChange = { [weak self] in self?.redraw() }
        redraw()
    }

    func remove() {
        model.onVisibleChange = nil
        if popover.isShown { popover.performClose(nil) }
        NSStatusBar.system.removeStatusItem(item)
    }

    /// The image for a state; also used by snapshots.
    static func image(holding: Bool, blocked: Bool) -> NSImage? {
        let name = blocked ? "exclamationmark.triangle" : (holding ? "cup.and.saucer.fill" : "cup.and.saucer")
        let image = NSImage(systemSymbolName: name, accessibilityDescription: String(localized: "Uyanık Tut"))
        image?.isTemplate = true
        return image
    }

    private func redraw() {
        let state = model.state
        item.button?.image = Self.image(holding: state.isHolding, blocked: state.blocked != nil)
        item.button?.setAccessibilityValue(String(localized: state.isHolding ? "Açık" : "Kapalı"))
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else if popover.isShown {
            popover.performClose(sender)
        } else {
            model.toggle(defaultDuration: settings.keepAwakeDuration)
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        for seconds in SettingsStore.keepAwakeDurationChoices {
            let entry = NSMenuItem(title: KeepAwakeText.durationMenuTitle(seconds), action: #selector(startFromMenu(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = seconds
            menu.addItem(entry)
        }
        if model.state.manualActive {
            menu.addItem(.separator())
            let stop = NSMenuItem(title: String(localized: "Durdur"), action: #selector(stopFromMenu), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)
        }
        menu.addItem(.separator())
        let details = NSMenuItem(title: String(localized: "Durumu göster"), action: #selector(showPopover), keyEquivalent: "")
        details.target = self
        menu.addItem(details)
        let page = NSMenuItem(title: String(localized: "Uyanık Tut sayfasını aç"), action: #selector(openPage), keyEquivalent: "")
        page.target = self
        menu.addItem(page)
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func startFromMenu(_ sender: NSMenuItem) {
        let seconds = sender.representedObject as? Double ?? 0
        model.start(duration: seconds > 0 ? seconds : nil)
    }

    @objc private func stopFromMenu() { model.stop() }
    @objc private func openPage() { openWindow(.module(.keepAwake)) }

    @objc private func showPopover() {
        guard let button = item.button else { return }
        let feed = LiveFeed(engine: engine)
        let close: () -> Void = { [weak self] in self?.popover.performClose(nil) }
        let host = NSHostingController(rootView: KeepAwakePopover(settings: settings, openWindow: { [weak self] in
            close()
            self?.openWindow(.module(.keepAwake))
        }).environment(feed).environment(model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        self.feed = feed
        feed.isActive = true
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        feed?.isActive = false
        feed = nil
        popover.contentViewController = nil
    }
}
