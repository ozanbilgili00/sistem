#if DEBUG
import AppKit
import SistemUI
import SwiftUI

/// `Sistem --snapshot <dir>` renders key screens offscreen to PNGs, in both themes,
/// then exits. Lets the UI be checked without opening a window or taking focus.
enum SnapshotRenderer {
    static func run(into directory: URL) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "SistemSnapshot")!)
        let pages: [(String, Page)] = [
            ("dashboard", .module(.dashboard)), ("cpu", .module(.cpu)),
            ("settings", .settings), ("diagnostics", .diagnostics),
        ]
        for (theme, name) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let appearance = NSAppearance(named: name)!
            for (label, page) in pages {
                render(MainView(settings: settings, pinnedPage: page), size: CGSize(width: 1000, height: 660),
                       appearance: appearance, to: directory.appending(path: "\(label)-\(theme).png"))
            }
            render(PopoverView(openWindow: {}), size: CGSize(width: 300, height: 220),
                   appearance: appearance, to: directory.appending(path: "popover-\(theme).png"))
        }
    }

    private static func render<V: View>(_ view: V, size: CGSize, appearance: NSAppearance, to url: URL) {
        let host = NSHostingView(rootView: view)
        host.appearance = appearance
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: .now + 0.4)  // let SwiftUI commit a frame
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
