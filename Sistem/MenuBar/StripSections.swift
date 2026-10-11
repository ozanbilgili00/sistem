import AppKit
import SistemUI
import SystemKit

/// What a section of the strip is. The order of the cases is the order in the strip after the widgets.
enum StripKind: Hashable {
    case module(ModuleID)
    case keepAwake
    case display
    case servers
}

/// One part of the single menu bar item. A section draws into its own view and reports when its width or its
/// accessible value changes; the strip owns the layout, the click handling and the popovers.
@MainActor
protocol StripSection: AnyObject {
    var kind: StripKind { get }
    var view: NSView { get }
    /// Fixed for a configuration, never per value, so the strip does not shift.
    var width: CGFloat { get }
    var accessibilityTitle: String { get }
    var accessibilityValue: String? { get }
    var onLayoutChange: (() -> Void)? { get set }
    var onValueChange: (() -> Void)? { get set }
    func remove()
}

/// A fixed symbol (cup, display, server, Bluetooth). Redraws only when the symbol changes.
final class SymbolView: NSView {
    var symbol: String { didSet { if symbol != oldValue { needsDisplay = true } } }

    init(symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) else { return }
        let tinted = NSImage(size: image.size, flipped: false) { frame in
            image.draw(in: frame)
            NSColor.labelColor.setFill()
            frame.fill(using: .sourceIn)
            return true
        }
        tinted.draw(at: NSPoint(x: bounds.midX - tinted.size.width / 2, y: bounds.midY - tinted.size.height / 2),
                    from: .zero, operation: .sourceOver, fraction: 1)
    }
}

@MainActor
final class IconSection: StripSection {
    let kind: StripKind
    let view: NSView
    private let symbolView: SymbolView
    private var title: String
    private(set) var accessibilityValue: String?
    var onLayoutChange: (() -> Void)?
    var onValueChange: (() -> Void)?

    var width: CGFloat { NSStatusBar.system.thickness }
    var accessibilityTitle: String { title }

    init(kind: StripKind, symbol: String, title: String, value: String? = nil) {
        self.kind = kind
        self.title = title
        accessibilityValue = value
        symbolView = SymbolView(symbol: symbol)
        view = symbolView
    }

    /// Redraws only if the symbol or the value differ from what is shown.
    func update(symbol: String, value: String?) {
        let changed = symbolView.symbol != symbol || accessibilityValue != value
        symbolView.symbol = symbol
        accessibilityValue = value
        if changed { onValueChange?() }
    }

    func remove() {}

    static func cupSymbol(holding: Bool, blocked: Bool) -> String {
        blocked ? "exclamationmark.triangle" : (holding ? "cup.and.saucer.fill" : "cup.and.saucer")
    }
}

/// Where a widget reads its numbers and how it asks for them. The app uses the engine; snapshots use a fixed store.
struct WidgetSource {
    var store: MetricStore
    var observe: (@escaping () -> Void) -> ObservationToken?
    var retain: (Metric) -> Void
    var release: (Metric) -> Void

    @MainActor
    static func live(_ engine: SamplingEngine) -> WidgetSource {
        WidgetSource(store: engine.store, observe: { engine.store.observe($0) },
                     retain: { engine.demand.retain($0) }, release: { engine.demand.release($0) })
    }

    static func fixed(_ store: MetricStore) -> WidgetSource {
        WidgetSource(store: store, observe: { _ in nil }, retain: { _ in }, release: { _ in })
    }
}

/// One module's widget: holds demand for its metric while it exists and redraws after each tick. This is the former
/// per-module status item, minus the item: the view is a section of the strip.
@MainActor
final class WidgetSection: StripSection {
    let module: ModuleID
    var kind: StripKind { .module(module) }
    let view: NSView
    private let widget = WidgetView()
    private let source: WidgetSource
    private var token: ObservationToken?
    private var shown: DisplayHysteresis
    private var shownRates = RateHysteresis()
    /// The GPU line of the stacked sensors item, with its own hysteresis.
    private var shownGPU = DisplayHysteresis.for(.sensors)
    /// The metric this section holds demand for: the sensors widget reads more keys when stacked.
    private var demanded: Metric?
    private var lastText = ""
    var onLayoutChange: (() -> Void)?
    var onValueChange: (() -> Void)?

    var width: CGFloat { widget.intrinsicWidth }
    var accessibilityTitle: String { String(localized: module.menuBarTitle) }
    var accessibilityValue: String? { lastText.isEmpty ? nil : lastText }

    var config: WidgetConfig {
        didSet { if config != oldValue { refresh() } }
    }

    var clock: ClockDisplay {
        didSet {
            guard clock != oldValue else { return }
            widget.widestText = WidgetModel.widestText(for: module, sensors: sensors, clock: clock)
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
            widget.widestText = WidgetModel.widestText(for: module, sensors: sensors)
            if sensors.stacked != oldValue.stacked { shown = DisplayHysteresis.for(module); shownGPU = DisplayHysteresis.for(.sensors) }
            refresh()
        }
    }

    private func syncDemand() {
        let wanted: Metric? = module == .sensors && sensors.stacked ? .temperatureStack : module.metric
        guard wanted != demanded else { return }
        if let wanted { source.retain(wanted) }  // take the new one first: no gap in demand
        if let demanded { source.release(demanded) }
        demanded = wanted
    }

    init(module: ModuleID, config: WidgetConfig, sensors: SensorsDisplay, clock: ClockDisplay, source: WidgetSource) {
        self.module = module
        self.config = config
        self.sensors = sensors
        self.clock = clock
        self.source = source
        view = widget
        shown = DisplayHysteresis.for(module)
        widget.widestText = WidgetModel.widestText(for: module, sensors: sensors, clock: clock)
        widget.reservesGlyph = module == .battery
        if module == .clock { widget.widestLabel = clock.widestLabel }
        widget.onWidthChange = { [weak self] _ in self?.onLayoutChange?() }
        syncDemand()
        if module == .clock {
            let ticker = ClockTicker { [weak self] in self?.refresh() }
            self.ticker = ticker
            ticker.start(pattern: clock.pattern)
        } else {
            token = source.observe { [weak self] in self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        var model = WidgetModel.make(module, store: source.store, sensors: sensors, clock: clock)
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
        if widget.update(model, config: config) {
            lastText = model.text
            onValueChange?()
            MenuBarStats.redraws += 1
        }
    }

    func remove() {
        token = nil
        ticker?.stop()
        ticker = nil
        if let demanded { source.release(demanded) }
        demanded = nil
    }
}
