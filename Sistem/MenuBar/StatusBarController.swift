import AppKit
import Observation
import SwiftUI
import SystemKit

/// Owns the menu bar: ONE status item that holds every Sistem part side by side as sections (the widgets of the chosen
/// modules, then the cup, the display and the server icons, only those that are on). macOS stores the position of every
/// status item separately and offers no way to keep several together, so the parts live in one item that can be
/// moved with ⌘-drag as a whole. A plain icon item stays when there is no section, so the app remains reachable.
///
/// A click is mapped to a section by its x position (``StripLayout/index(at:)``) and opens that section's popover,
/// anchored under it. Popover content is built on open and dropped on close, so a closed popover holds no SwiftUI
/// hierarchy and no metric demand (PLAN.md §3-D).
final class StatusBarController: NSObject, NSPopoverDelegate {
    private static let autosaveName = "Sistem.menuBar"

    private let settings: SettingsStore
    private let engine: SamplingEngine
    private let keepAwake: KeepAwakeModel
    private let display: DisplayModel
    private let servers: ServersModel
    private let openWindow: (Page?) -> Void

    private var item: NSStatusItem?
    private let strip = StripView()
    private var fallback: NSStatusItem?
    private let popover = NSPopover()
    private var popoverFeed: LiveFeed?
    private var popoverKind: StripKind?
    private var cup: IconSection?

    init(settings: SettingsStore, engine: SamplingEngine, keepAwake: KeepAwakeModel, display: DisplayModel, servers: ServersModel,
         openWindow: @escaping (Page?) -> Void) {
        self.settings = settings
        self.engine = engine
        self.keepAwake = keepAwake
        self.display = display
        self.servers = servers
        self.openWindow = openWindow
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        strip.onTotalWidthChange = { [weak self] width in self?.item?.length = width }
        strip.onPress = { [weak self] index in self?.activate(index: index, fromClick: false) }
        trackSettings()
    }

    // MARK: Sections

    /// The sections that are on, in the user's order (``MenuBarOrder``; by default the widgets, then cup, display, servers).
    static func wantedKinds(modules: [ModuleID], order: [ModuleID], keepAwake: Bool, display: Bool, servers: Bool) -> [StripKind] {
        SettingsStore.sections(modules: modules, order: order, keepAwake: keepAwake, display: display, servers: servers).map { section in
            switch section {
            case .keepAwake: StripKind.keepAwake
            case .display: .display
            case .servers: .servers
            default: .module(section)
            }
        }
    }

    /// Re-reads the menu bar settings whenever they change.
    private func trackSettings() {
        struct Snapshot {
            var kinds: [StripKind]
            var widgets: [ModuleID: WidgetConfig]
            var sensors: SensorsDisplay
            var clock: ClockDisplay
        }
        let snapshot = withObservationTracking {
            let kinds = Self.wantedKinds(modules: settings.menuBarModules, order: settings.menuBarOrder, keepAwake: settings.keepAwakeEnabled,
                                         display: settings.displayEnabled && settings.displayMenuBar,
                                         servers: settings.serversEnabled && settings.serversMenuBar)
            var widgets: [ModuleID: WidgetConfig] = [:]
            for case .module(let module) in kinds { widgets[module] = settings.widget(for: module) }
            return Snapshot(kinds: kinds, widgets: widgets, sensors: settings.sensorsDisplay, clock: settings.clockDisplay)
        } onChange: { [weak self] in
            // Fires on willSet; read the new values on the next turn.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.trackSettings() } }
        }
        apply(snapshot.kinds, widgets: snapshot.widgets, sensors: snapshot.sensors, clock: snapshot.clock)
    }

    private func apply(_ kinds: [StripKind], widgets: [ModuleID: WidgetConfig], sensors: SensorsDisplay, clock: ClockDisplay) {
        if kinds != strip.sections.map(\.kind) {
            if popover.isShown { popover.performClose(nil) }
            strip.sections.forEach { $0.remove() }
            keepAwake.onVisibleChange = nil
            cup = nil
            let source = WidgetSource.live(engine)
            let sections: [any StripSection] = kinds.map { kind in
                switch kind {
                case .module(.bluetooth):
                    IconSection(kind: kind, symbol: ModuleID.bluetooth.symbol, title: "Bluetooth")
                case .module(let module):
                    WidgetSection(module: module, config: widgets[module] ?? .default, sensors: sensors, clock: clock, source: source)
                case .keepAwake:
                    makeCup()
                case .display:
                    IconSection(kind: kind, symbol: "display", title: String(localized: "Ekran"))
                case .servers:
                    IconSection(kind: kind, symbol: "server.rack", title: String(localized: "Sunucular"))
                }
            }
            strip.setSections(sections)
        } else {
            for case let section as WidgetSection in strip.sections {
                if let config = widgets[section.module] { section.config = config }
                if section.module == .sensors { section.sensors = sensors }
                if section.module == .clock { section.clock = clock }
            }
        }
        syncItems(empty: kinds.isEmpty)
    }

    /// The cup redraws only when what it shows changes (holding or not, blocked or not), never on a timer or tick.
    private func makeCup() -> IconSection {
        let section = IconSection(kind: .keepAwake, symbol: "cup.and.saucer", title: String(localized: "Uyanık Tut"))
        cup = section
        keepAwake.onVisibleChange = { [weak self] in self?.updateCup() }
        updateCup()
        return section
    }

    private func updateCup() {
        guard let cup else { return }
        let state = keepAwake.state
        cup.update(symbol: IconSection.cupSymbol(holding: state.isHolding, blocked: state.blocked != nil),
                   value: String(localized: state.isHolding ? "Açık" : "Kapalı"))
    }

    private func syncItems(empty: Bool) {
        if !empty {
            if item == nil {
                let created = NSStatusBar.system.statusItem(withLength: strip.layoutModel.totalWidth)
                created.autosaveName = Self.autosaveName
                if let button = created.button {
                    button.target = self
                    button.action = #selector(clicked(_:))
                    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                    strip.frame = button.bounds
                    strip.autoresizingMask = [.width, .height]
                    button.addSubview(strip)
                    button.setAccessibilityLabel("Sistem")
                    button.setAccessibilityRole(.group)
                    button.setAccessibilityChildren(strip.accessibilityElements)
                }
                item = created
            } else {
                item?.button?.setAccessibilityChildren(strip.accessibilityElements)
            }
            item?.length = strip.layoutModel.totalWidth
            if let item = fallback {
                NSStatusBar.system.removeStatusItem(item)
                fallback = nil
            }
        } else {
            if let item {
                strip.removeFromSuperview()
                NSStatusBar.system.removeStatusItem(item)
                self.item = nil
            }
            if fallback == nil {
                let created = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                created.autosaveName = "SistemStatusItem"
                let image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "Sistem")
                image?.isTemplate = true
                created.button?.image = image
                created.button?.target = self
                created.button?.action = #selector(clicked(_:))
                fallback = created
            }
        }
    }

    // MARK: Clicks

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard sender === item?.button, !strip.sections.isEmpty else {
            togglePopover(nil, rect: sender.bounds, in: sender)
            return
        }
        guard let index = strip.layoutModel.index(at: clickX(in: sender)) else { return }
        activate(index: index, fromClick: true)
    }

    /// Where the click landed, in the button's coordinates. The pointer's screen position comes first: on macOS 26+ the
    /// event a status item's action receives can carry the button's centre instead of the real click point, which sent
    /// every click to the middle section. The event's own position is the fallback when the pointer is outside the button.
    private func clickX(in button: NSStatusBarButton) -> CGFloat {
        if let window = button.window {
            let point = button.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            if button.bounds.insetBy(dx: -1, dy: -4).contains(point) { return point.x }
        }
        return NSApp.currentEvent.map { button.convert($0.locationInWindow, from: nil).x } ?? 0
    }

    private func activate(index: Int, fromClick: Bool) {
        guard strip.sections.indices.contains(index), let button = item?.button else { return }
        let kind = strip.sections[index].kind
        let rect = strip.rect(of: index)
        // The cup opens its popover (durations, Stop, who keeps the Mac awake) like every other section; the right click keeps the quick menu.
        if kind == .keepAwake, fromClick, NSApp.currentEvent?.type == .rightMouseUp {
            showCupMenu(rect: rect, in: button)
            return
        }
        togglePopover(kind, rect: rect, in: button)
    }

    private func togglePopover(_ kind: StripKind?, rect: NSRect, in button: NSStatusBarButton) {
        if popover.isShown {
            let same = kind == popoverKind
            popover.performClose(button)
            if same { return }
        }
        show(kind, rect: rect, in: button)
    }

    private func show(_ kind: StripKind?, rect: NSRect, in button: NSStatusBarButton) {
        let feed = LiveFeed(engine: engine)
        let close: () -> Void = { [weak self] in self?.popover.performClose(nil) }
        let open: (Page?) -> Void = { [weak self] page in
            self?.popover.performClose(nil)
            self?.openWindow(page)
        }
        let content: AnyView = switch kind {
        case .module(.cpu): AnyView(CPUPopover(settings: settings, openWindow: { open(.module(.cpu)) }, close: close))
        case .module(.gpu): AnyView(GPUPopover(settings: settings, openWindow: { open(.module(.gpu)) }))
        case .module(.ram): AnyView(RAMPopover(settings: settings, openWindow: { open(.module(.ram)) }))
        case .module(.disk): AnyView(DiskPopover(settings: settings, openWindow: { open(.module(.disk)) }))
        case .module(.network): AnyView(NetworkPopover(settings: settings, openWindow: { open(.module(.network)) }))
        case .module(.sensors): AnyView(SensorsPopover(settings: settings, openWindow: { open(.module(.sensors)) }))
        case .module(.battery): AnyView(BatteryPopover(settings: settings, openWindow: { open(.module(.battery)) }))
        case .module(.clock): AnyView(ClockPopover(settings: settings, openWindow: { open(.module(.clock)) }))
        case .module(.bluetooth): AnyView(BluetoothPopover(openWindow: { open(.module(.bluetooth)) }))
        case .keepAwake:
            AnyView(KeepAwakePopover(settings: settings, openWindow: { open(.module(.keepAwake)) }).environment(keepAwake))
        case .display: AnyView(DisplayPopover(openWindow: { open(.module(.display)) }).environment(display))
        case .servers: AnyView(ServersPopover(openWindow: { open(.module(.servers)) }).environment(servers))
        default: AnyView(PopoverView(openWindow: { open(nil) }))
        }
        let host = NSHostingController(rootView: content.environment(feed))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popoverFeed = feed
        popoverKind = kind
        feed.isActive = true
        popover.show(relativeTo: rect, of: button, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        popoverFeed?.isActive = false
        popoverFeed = nil
        popoverKind = nil
        popover.contentViewController = nil
    }

    // MARK: Cup menu

    /// Right click on the cup: durations, stop, status. The menu is the item's own for the moment of the click.
    private func showCupMenu(rect: NSRect, in button: NSStatusBarButton) {
        let menu = NSMenu()
        for seconds in SettingsStore.keepAwakeDurationChoices {
            let entry = NSMenuItem(title: KeepAwakeText.durationMenuTitle(seconds), action: #selector(startFromMenu(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = seconds
            menu.addItem(entry)
        }
        if keepAwake.state.manualActive {
            menu.addItem(.separator())
            let stop = NSMenuItem(title: String(localized: "Durdur"), action: #selector(stopFromMenu), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)
        }
        menu.addItem(.separator())
        let details = NSMenuItem(title: String(localized: "Durumu göster"), action: #selector(showCupPopover), keyEquivalent: "")
        details.target = self
        menu.addItem(details)
        let page = NSMenuItem(title: String(localized: "Uyanık Tut sayfasını aç"), action: #selector(openCupPage), keyEquivalent: "")
        page.target = self
        menu.addItem(page)
        item?.menu = menu
        button.performClick(nil)
        item?.menu = nil
    }

    @objc private func startFromMenu(_ sender: NSMenuItem) {
        let seconds = sender.representedObject as? Double ?? 0
        keepAwake.start(duration: seconds > 0 ? seconds : nil)
    }

    @objc private func stopFromMenu() { keepAwake.stop() }
    @objc private func openCupPage() { openWindow(.module(.keepAwake)) }

    @objc private func showCupPopover() {
        guard let button = item?.button, let index = strip.sections.firstIndex(where: { $0.kind == .keepAwake }) else { return }
        if popover.isShown { popover.performClose(nil) }
        show(.keepAwake, rect: strip.rect(of: index), in: button)
    }
}
