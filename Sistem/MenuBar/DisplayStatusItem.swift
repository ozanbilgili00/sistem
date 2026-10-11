import AppKit
import SwiftUI
import SystemKit

/// The monitor icon in the menu bar: its own status item, off unless the user turns it on.
/// The icon never changes, so it is drawn once and never redrawn; a click opens the popover.
final class DisplayStatusItem: NSObject, NSPopoverDelegate {
    private let item: NSStatusItem
    private let model: DisplayModel
    private let openWindow: (Page?) -> Void
    private let popover = NSPopover()

    init(model: DisplayModel, openWindow: @escaping (Page?) -> Void) {
        self.model = model
        self.openWindow = openWindow
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.autosaveName = "Sistem.display"
        popover.behavior = .transient
        popover.delegate = self
        if let button = item.button {
            button.image = Self.image()
            button.target = self
            button.action = #selector(clicked(_:))
            button.setAccessibilityLabel(String(localized: "Ekran"))
        }
    }

    func remove() {
        if popover.isShown { popover.performClose(nil) }
        NSStatusBar.system.removeStatusItem(item)
    }

    static func image() -> NSImage? {
        let image = NSImage(systemSymbolName: "display", accessibilityDescription: String(localized: "Ekran"))
        image?.isTemplate = true
        return image
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        let close: () -> Void = { [weak self] in self?.popover.performClose(nil) }
        let host = NSHostingController(rootView: DisplayPopover(openWindow: { [weak self] in
            close()
            self?.openWindow(.module(.display))
        }).environment(model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }
}
