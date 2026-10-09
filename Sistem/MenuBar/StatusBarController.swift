import AppKit
import Observation
import SwiftUI
import SystemKit

/// Owns the menu bar: one status item per live module the user chose, each with
/// its own popover; a plain icon when none is chosen, so the app stays reachable.
///
/// Popover content is built on open and dropped on close, so a closed popover
/// holds no SwiftUI hierarchy and no metric demand (PLAN.md §3-D).
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let settings: SettingsStore
    private let engine: SamplingEngine
    private let openWindow: (Page?) -> Void

    private var items: [ModuleItem] = []
    private var fallback: NSStatusItem?
    private let popover = NSPopover()
    private var popoverFeed: LiveFeed?
    private var popoverModule: ModuleID?

    init(settings: SettingsStore, engine: SamplingEngine, openWindow: @escaping (Page?) -> Void) {
        self.settings = settings
        self.engine = engine
        self.openWindow = openWindow
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        trackSettings()
    }

    // MARK: Items

    /// Re-reads the menu bar settings whenever they change.
    private func trackSettings() {
        let (wanted, sensors, clock) = withObservationTracking {
            (settings.menuBarModules.filter(\.hasMenuBarItem).map { ($0, settings.widget(for: $0)) }, settings.sensorsDisplay, settings.clockDisplay)
        } onChange: { [weak self] in
            // Fires on willSet; read the new values on the next turn.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.trackSettings() } }
        }
        apply(wanted, sensors: sensors, clock: clock)
    }

    private func apply(_ wanted: [(ModuleID, WidgetConfig)], sensors: SensorsDisplay, clock: ClockDisplay) {
        if wanted.map(\.0) != items.map(\.module) {
            if popover.isShown { popover.performClose(nil) }
            items.forEach { $0.remove() }
            // A new status item lands left of the existing ones; build right to left.
            items = wanted.reversed().map { module, config in
                ModuleItem(module: module, config: config, sensors: sensors, clock: clock, engine: engine, target: self, action: #selector(clicked(_:)))
            }.reversed()
        } else {
            for (item, (_, config)) in zip(items, wanted) { item.config = config }
            for item in items where item.module == .sensors { item.sensors = sensors }
            for item in items where item.module == .clock { item.clock = clock }
        }
        updateFallback()
    }

    private func updateFallback() {
        if items.isEmpty, fallback == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.autosaveName = "SistemStatusItem"
            let image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "Sistem")
            image?.isTemplate = true
            item.button?.image = image
            item.button?.target = self
            item.button?.action = #selector(clicked(_:))
            fallback = item
        } else if !items.isEmpty, let item = fallback {
            NSStatusBar.system.removeStatusItem(item)
            fallback = nil
        }
    }

    // MARK: Popover

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let module = items.first { $0.item.button === sender }?.module
        if popover.isShown {
            let same = module == popoverModule
            popover.performClose(sender)
            if same { return }
        }
        show(module, from: sender)
    }

    private func show(_ module: ModuleID?, from button: NSStatusBarButton) {
        let feed = LiveFeed(engine: engine)
        let close: () -> Void = { [weak self] in self?.popover.performClose(nil) }
        let open: (Page?) -> Void = { [weak self] page in
            self?.popover.performClose(nil)
            self?.openWindow(page)
        }
        let content: AnyView = switch module {
        case .cpu: AnyView(CPUPopover(settings: settings, openWindow: { open(.module(.cpu)) }, close: close))
        case .gpu: AnyView(GPUPopover(settings: settings, openWindow: { open(.module(.gpu)) }))
        case .ram: AnyView(RAMPopover(settings: settings, openWindow: { open(.module(.ram)) }))
        case .disk: AnyView(DiskPopover(settings: settings, openWindow: { open(.module(.disk)) }))
        case .network: AnyView(NetworkPopover(settings: settings, openWindow: { open(.module(.network)) }))
        case .sensors: AnyView(SensorsPopover(settings: settings, openWindow: { open(.module(.sensors)) }))
        case .battery: AnyView(BatteryPopover(settings: settings, openWindow: { open(.module(.battery)) }))
        case .clock: AnyView(ClockPopover(settings: settings, openWindow: { open(.module(.clock)) }))
        case .bluetooth: AnyView(BluetoothPopover(openWindow: { open(.module(.bluetooth)) }))
        default: AnyView(PopoverView(openWindow: { open(nil) }))
        }
        let host = NSHostingController(rootView: content.environment(feed))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popoverFeed = feed
        popoverModule = module
        feed.isActive = true
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        popoverFeed?.isActive = false
        popoverFeed = nil
        popoverModule = nil
        popover.contentViewController = nil
    }
}

/// One module's status item: holds demand for its metric while it exists and
/// redraws its widget after each tick.
private final class ModuleItem {
    let module: ModuleID
    let item: NSStatusItem
    private let view = WidgetView()
    private let engine: SamplingEngine
    private var token: ObservationToken?
    private var shown: DisplayHysteresis
    private var shownRates = RateHysteresis()
    /// The GPU line of the stacked sensors item, with its own hysteresis.
    private var shownGPU = DisplayHysteresis.for(.sensors)
    /// The metric this item holds demand for: the sensors item reads more keys when stacked.
    private var demanded: Metric?

    var config: WidgetConfig {
        didSet { if config != oldValue { refresh() } }
    }

    var clock: ClockDisplay {
        didSet {
            guard clock != oldValue else { return }
            view.widestText = WidgetModel.widestText(for: module, sensors: sensors, clock: clock)
            ticker?.start(pattern: clock.pattern)
            refresh()
        }
    }

    /// Only the clock has one: it redraws at its own boundary, not on the sampler's tick.
    private var ticker: ClockTicker?

    var sensors: SensorsDisplay {
        didSet {
            guard sensors != oldValue else { return }
            syncDemand()
            view.widestText = WidgetModel.widestText(for: module, sensors: sensors)
            if sensors.stacked != oldValue.stacked { shown = DisplayHysteresis.for(module); shownGPU = DisplayHysteresis.for(.sensors) }
            refresh()
        }
    }

    private func syncDemand() {
        let wanted: Metric? = module == .sensors && sensors.stacked ? .temperatureStack : module.metric
        guard wanted != demanded else { return }
        if let wanted { engine.demand.retain(wanted) }  // take the new one first: no gap in demand
        if let demanded { engine.demand.release(demanded) }
        demanded = wanted
    }

    init(module: ModuleID, config: WidgetConfig, sensors: SensorsDisplay, clock: ClockDisplay, engine: SamplingEngine, target: AnyObject, action: Selector) {
        self.module = module
        self.config = config
        self.sensors = sensors
        self.clock = clock
        self.engine = engine
        shown = DisplayHysteresis.for(module)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "Sistem.\(module.rawValue)"
        if let button = item.button {
            button.target = target
            button.action = action
            button.setAccessibilityLabel(String(localized: module.menuBarTitle))
            view.frame = button.bounds
            view.autoresizingMask = [.width, .height]
            button.addSubview(view)
        }
        if module == .bluetooth {
            // A fixed icon: nothing to redraw, no metric demanded while the popover is closed.
            item.length = NSStatusItem.squareLength
            let image = NSImage(systemSymbolName: ModuleID.bluetooth.symbol, accessibilityDescription: "Bluetooth")
            image?.isTemplate = true
            item.button?.image = image
            view.removeFromSuperview()
            return
        }
        view.widestText = WidgetModel.widestText(for: module, sensors: sensors, clock: clock)
        view.reservesGlyph = module == .battery
        if module == .clock { view.widestLabel = clock.widestLabel }
        view.onWidthChange = { [weak self] width in self?.item.length = width }
        syncDemand()
        if module == .clock {
            let ticker = ClockTicker { [weak self] in self?.refresh() }
            self.ticker = ticker
            ticker.start(pattern: clock.pattern)
        } else {
            token = engine.store.observe { [weak self] in self?.refresh() }
        }
        refresh()
    }

    private func refresh() {
        var model = WidgetModel.make(module, store: engine.store, sensors: sensors, clock: clock)
        if module == .clock {
            // Text only changes at the ticker's boundary; nothing to filter.
        } else if module == .battery {
            // The system reports whole percents on its own events; the hysteresis only passes 1-point steps.
            model.value = shown.filter(model.value)
            if let value = model.value { model.text = Format.percent(value) }
        } else if module == .sensors {
            // A whole degree at a time (see DisplayHysteresis.for), shown in the user's unit.
            model.value = shown.filter(model.value)
            let cpu = Format.temperature(model.value.map(SensorScale.celsius), unit: sensors.unit)
            if sensors.stacked {
                model.gpuValue = shownGPU.filter(model.gpuValue)
                model.label = "CPU \(cpu)"
                model.text = "GPU \(Format.temperature(model.gpuValue.map(SensorScale.celsius), unit: sensors.unit))"
            } else {
                model.text = cpu
            }
        } else if let top = model.topRate, let bottom = model.bottomRate {
            // Speeds: two lines, shown through the rate hysteresis. The disk's ring
            // (capacity) moves slowly enough to go straight through.
            let (a, b) = shownRates.filter(top, bottom)
            model.label = WidgetModel.pairLine(module, top: true, rate: a)
            model.text = WidgetModel.pairLine(module, top: false, rate: b)
        } else {
            model.value = shown.filter(model.value)
            model.text = Format.percent(model.value)
        }
        if view.update(model, config: config) {
            item.button?.setAccessibilityValue(model.text)
            MenuBarStats.redraws += 1
        }
    }

    func remove() {
        token = nil
        ticker?.stop()
        ticker = nil
        if let demanded { engine.demand.release(demanded) }
        demanded = nil
        NSStatusBar.system.removeStatusItem(item)
    }
}
