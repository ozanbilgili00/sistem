import AppKit
import SwiftUI

/// The menu bar item and its popover.
///
/// The popover's SwiftUI content is built each time it opens and dropped when it
/// closes, so a closed popover holds no view hierarchy in memory (PLAN.md §3-D).
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let openWindow: () -> Void

    init(openWindow: @escaping () -> Void) {
        self.openWindow = openWindow
        super.init()
        item.autosaveName = "SistemStatusItem"
        if let button = item.button {
            let image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "Sistem")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        popover.behavior = .transient
        popover.delegate = self
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        let content = PopoverView { [weak self] in
            self?.popover.performClose(nil)
            self?.openWindow()
        }
        let host = NSHostingController(rootView: content)
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }
}
