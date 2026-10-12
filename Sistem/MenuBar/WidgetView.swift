import AppKit
import SistemUI
import SystemKit

/// What a widget shows, independent of how. Built from the store each tick.
struct WidgetModel: Equatable {
    var label: String
    /// 0...1, nil before the first sample.
    var value: Float?
    var text: String
    /// Oldest first, 0...1, for the mini chart.
    var history: [Float]
    /// Speeds in bytes per second for the two-line modules (disk, network): the top and
    /// bottom line. nil for percentage modules.
    var topRate: Double?
    var bottomRate: Double?
    /// SF Symbols drawn left of the two speed lines, top first.
    var rateSymbols: [String] = []
    /// One level 0...``barSteps`` per bar (CPU cores; memory's app / wired / compressed). Raw here; the strip's
    /// section passes them through its ``LevelHysteresis`` before drawing.
    var barLevels: [UInt8] = []
    /// The last minute reduced to at most ``sparkPoints`` points of 0...``sparkSteps``.
    var sparkLevels: [UInt8] = []

    /// The GPU's temperature as a ring fraction, for the stacked CPU/GPU sensors item.
    var gpuValue: Float?
    /// CPU over GPU: two lines, like the speeds.
    var stacked = false
    /// SF Symbol drawn left of the value (the battery's charging bolt); nil for none.
    var glyph: String?
    /// Two-line readouts (speeds, CPU/GPU temperatures) always stack, whatever the label setting says.
    var isPair: Bool { topRate != nil || stacked }

    static let chartSamples = 30  // one minute at the default 2 s
    static let barSteps = 8
    static let sparkSteps = 8
    /// Few points are enough for a line 28 pt wide, and every point is a chance to redraw.
    static let sparkPoints = 15

    /// Logical CPUs, one bar each. Fixed for the Mac, so the CPU widget's width never depends on a sample.
    static let coreCount: Int = max(1, HardwareInfo.current().clusters.map(\.logicalCPUs.upperBound).max() ?? 1)

    /// How many bars a module's bar widget has; the width is reserved for all of them.
    static func barCount(for module: ModuleID) -> Int {
        switch module {
        case .cpu: coreCount
        case .ram: 3
        default: 0
        }
    }
    /// The texts that can be the widest a module's readout takes (a speed's unit changes its width, a percent is widest
    /// at 100); the width is reserved for the widest of them, so the menu bar never shifts.
    @MainActor static func widestTexts(for module: ModuleID, sensors: SensorsDisplay = SensorsDisplay(), clock: ClockDisplay? = nil) -> [String] {
        switch module {
        case .clock:
            return [clock?.widestText ?? "00:00"]
        case .sensors:
            let value = Format.temperature(199, unit: sensors.unit)  // "199°C" / "390°F"
            return [sensors.stacked ? "GPU \(value)" : value]
        case .network, .disk:
            // 888 in every unit, and 8.8 GB/s: "MB/s" is wider than "KB/s", and the number is widest at 888.
            return [888, 888_000, 888_000_000, 888_000_000_000, 8_800_000_000].map { Format.rate($0) }
        default:
            return [Format.percent(1)]
        }
    }

    /// The clock reads the date it is given (the item's timer decides when), not the store.
    @MainActor static func makeClock(_ display: ClockDisplay, date: Date = .now) -> WidgetModel {
        WidgetModel(label: display.dateLabel(date), value: nil, text: display.text(date), history: [])
    }

    /// Percentage and a bolt (charging) or plug (on power, not charging). Desktop Macs show "—".
    @MainActor static func makeBattery(_ status: BatteryStatus?) -> WidgetModel {
        let label = String(localized: ModuleID.battery.menuBarTitle)
        guard case .present(let sample)? = status else {
            return WidgetModel(label: label, value: nil, text: "—", history: [])
        }
        let fraction = Float(sample.percent) / 100
        var model = WidgetModel(label: label, value: fraction, text: Format.percent(fraction), history: [])
        switch sample.state {
        case .charging: model.glyph = "bolt.fill"
        case .charged, .pluggedNotCharging: model.glyph = "powerplug.fill"
        case .discharging: break
        }
        return model
    }

    @MainActor static func make(_ module: ModuleID, store: MetricStore, sensors: SensorsDisplay = SensorsDisplay(), clock: ClockDisplay? = nil) -> WidgetModel {
        switch module {
        case .battery:
            return makeBattery(store.battery)
        case .clock:
            return makeClock(clock ?? ClockDisplay(pattern: ClockFormat.defaultPattern()))
        case .sensors:
            let count = min(store.cpuTemperature.count, chartSamples)
            let start = store.cpuTemperature.count - count
            let history = (0..<count).map { SensorScale.fraction(store.cpuTemperature[start + $0]) }
            let cpu = store.temperature?.headline, gpu = store.temperature?.gpuHottest
            var model = WidgetModel(label: "CPU", value: cpu.map(SensorScale.fraction),
                                    text: Format.temperature(cpu, unit: sensors.unit), history: history)
            if sensors.stacked {
                model.stacked = true
                model.gpuValue = gpu.map(SensorScale.fraction)
                model.label = "CPU \(model.text)"
                model.text = "GPU \(Format.temperature(gpu, unit: sensors.unit))"
            }
            return withGraphs(model)
        case .cpu:
            let count = min(store.cpuUser.count, chartSamples)
            let start = store.cpuUser.count - count
            let history = (0..<count).map { store.cpuUser[start + $0] + store.cpuSystem[start + $0] }
            let value = smoothed(history, fallback: store.cpu?.total)
            var model = WidgetModel(label: "CPU", value: value, text: Format.percent(value), history: history)
            model.barLevels = LevelScale.levels(store.cpu?.cores ?? [], steps: barSteps)
            return withGraphs(model)
        case .gpu:
            let count = min(store.gpuDevice.count, chartSamples)
            let start = store.gpuDevice.count - count
            let history = (0..<count).map { store.gpuDevice[start + $0] }
            // Device Utilization %, the same number Activity Monitor's GPU history draws.
            // Idle GPU load is bursty (compositing for every display), so a longer window.
            let value = smoothed(history, window: 3, fallback: store.gpu?.device)
            return withGraphs(WidgetModel(label: "GPU", value: value, text: Format.percent(value), history: history))
        case .ram:
            let count = min(store.memoryApp.count, chartSamples)
            let start = store.memoryApp.count - count
            let history = (0..<count).map {
                store.memoryApp[start + $0] + store.memoryWired[start + $0] + store.memoryCompressed[start + $0]
            }
            let value = store.memory?.usedFraction
            var model = WidgetModel(label: "RAM", value: value, text: Format.percent(value), history: history)
            if let memory = store.memory {
                model.barLevels = LevelScale.levels([memory.fraction(memory.app), memory.fraction(memory.wired), memory.fraction(memory.compressed)], steps: barSteps)
            }
            return withGraphs(model)
        case .network:
            let down = store.network?.down ?? 0, up = store.network?.up ?? 0
            let history = pairHistory(store.networkDown, store.networkUp)
            var model = WidgetModel(label: Format.rate(up), value: nil, text: Format.rate(down), history: history,
                                    topRate: up, bottomRate: down)
            model.rateSymbols = ["arrow.up", "arrow.down"]
            return withGraphs(model)
        case .disk:
            let read = store.disk?.readRate ?? 0, write = store.disk?.writeRate ?? 0
            let boot = store.diskVolumes.first { $0.isBoot } ?? store.diskVolumes.first
            // Read pulls data off the disk, write pushes it on: the to-line arrows, so they are not taken for the network's.
            var model = WidgetModel(label: Format.rate(read), value: boot?.usedFraction, text: Format.rate(write),
                                    history: pairHistory(store.diskRead, store.diskWrite), topRate: read, bottomRate: write)
            model.rateSymbols = ["arrow.down.to.line", "arrow.up.to.line"]
            return withGraphs(model)
        default:
            return WidgetModel(label: String(localized: module.menuBarTitle), value: nil, text: "—", history: [])
        }
    }

    /// What VoiceOver reads as the value: the number in words, speeds named, a graph reduced to its number.
    @MainActor static func summary(_ module: ModuleID, _ model: WidgetModel) -> String {
        switch module {
        case .network, .disk:
            guard let top = model.topRate, let bottom = model.bottomRate else { return model.text }
            let names = module == .network
                ? (String(localized: "İndirme"), String(localized: "Yükleme"))
                : (String(localized: "Okuma"), String(localized: "Yazma"))
            // Network shows upload over download, disk read over write: say them in the order of the lines' meaning.
            return module == .network
                ? "\(names.0) \(Format.rate(bottom)), \(names.1) \(Format.rate(top))"
                : "\(names.0) \(Format.rate(top)), \(names.1) \(Format.rate(bottom))"
        case .battery:
            switch model.glyph {
            case "bolt.fill": return "\(model.text), \(String(localized: "şarj oluyor"))"
            case "powerplug.fill": return "\(model.text), \(String(localized: "prize takılı"))"
            default: return model.text
            }
        case .sensors where model.stacked:
            return "\(model.label), \(model.text)"
        default:
            return model.text
        }
    }

    /// Fills in the line graph's levels from the model's history.
    private static func withGraphs(_ model: WidgetModel) -> WidgetModel {
        var model = model
        model.sparkLevels = LevelScale.levels(LevelScale.resample(model.history, to: sparkPoints), steps: sparkSteps)
        return model
    }

    /// Both directions summed and scaled to the busiest second of the last minute
    /// (at least 100 KB/s, so a trickle doesn't fill the chart).
    private static func pairHistory(_ first: RingBuffer, _ second: RingBuffer) -> [Float] {
        let count = min(first.count, second.count, chartSamples)
        let start = first.count - count
        let totals = (0..<count).map { first[start + $0] + second[second.count - count + $0] }
        let peak = max(totals.max() ?? 0, 100_000)
        return totals.map { $0 / peak }
    }

    /// Mean of the last `window` samples: two is a 4 s window at the default interval,
    /// closer to Activity Monitor's 5 s, and it damps the tick-to-tick wobble that
    /// would otherwise redraw the item (see DisplayHysteresis).
    private static func smoothed(_ history: [Float], window: Int = 2, fallback: Float?) -> Float? {
        guard !history.isEmpty else { return fallback }
        let tail = history.suffix(window)
        return tail.reduce(0, +) / Float(tail.count)
    }
}

/// A tinted SF Symbol, drawn with the label colour of the appearance it is drawn in. The images are built once per name
/// and size; their drawing handler runs at draw time, so a change of appearance needs no new image.
@MainActor
enum TintedSymbol {
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String, size: CGFloat, weight: NSFont.Weight = .semibold) -> NSImage? {
        let key = "\(name)@\(size)"
        if let hit = cache[key] { return hit }
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight)) else { return nil }
        let tinted = NSImage(size: symbol.size, flipped: false) { frame in
            symbol.draw(in: frame)
            NSColor.labelColor.setFill()
            frame.fill(using: .sourceIn)
            return true
        }
        cache[key] = tinted
        return tinted
    }

    static func draw(_ name: String, size: CGFloat, centeredAt point: NSPoint) {
        guard let image = image(name, size: size) else { return }
        image.draw(at: NSPoint(x: point.x - image.size.width / 2, y: point.y - image.size.height / 2), from: .zero, operation: .sourceOver, fraction: 1)
    }
}

/// Draws one module's widgets inside a status item button.
///
/// Redraws only when what it would draw changes: the text, the ring in 2 % steps, the bars and the line in a few levels,
/// or the chart's pixel heights (PLAN.md §3-C). A steady 5 % costs nothing after the first frame. Every part has a fixed
/// width for its configuration, never for its value: text is reserved for the widest string it can take, bars for all
/// their bars. Clicks pass through to the button underneath.
final class WidgetView: NSView {
    private struct RenderKey: Equatable {
        var config: WidgetConfig
        var label: String
        var text: String
        var glyph: String?
        var ringSteps: Int
        var chartPixels: [UInt8]
        var barLevels: [UInt8]
        var sparkLevels: [UInt8]
        /// The battery body: fill in 5 % steps (nil = no battery) and the symbol beside it.
        var batterySteps: Int?
        /// The two speed lines.
        var arrowLines: [String]
    }

    private enum Layout {
        static let padding: CGFloat = 3
        static let spacing: CGFloat = 5
        static let chartWidth: CGFloat = 30
        static let sparkWidth: CGFloat = 28
        static let ringInset: CGFloat = 4
        static let barWidth: CGFloat = 2
        static let barGap: CGFloat = 1
        static let batteryBody = CGSize(width: 19, height: 10)
        static let batteryNub: CGFloat = 1.5
        static let labelFont = NSFont.systemFont(ofSize: 7.5, weight: .semibold)
        static let stackedValueFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        /// Two speeds stacked: smaller than a value-over-label pair, so both lines fit the bar.
        static let pairFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
        static let glyphSize: CGFloat = 8
        static let glyphGap: CGFloat = 2
        /// Room for an arrow left of a speed.
        static let arrowSlot: CGFloat = 9
    }

    private var glyphReserve: CGFloat {
        reservesGlyph && !config.kinds.contains(.battery) ? Layout.glyphSize + Layout.glyphGap : 0
    }

    var onWidthChange: ((CGFloat) -> Void)?

    private var config = WidgetConfig.default
    private var model = WidgetModel(label: "", value: nil, text: "—", history: [])
    private var key: RenderKey?
    /// Set by the owner; text width is reserved for the widest of these strings.
    var widestTexts: [String] = [Format.percent(1)] {
        didSet {
            guard widestTexts != oldValue else { return }
            strings = nil
            if frame.width > 0 { onWidthChange?(intrinsicWidth) }
        }
    }

    /// Set by the owner: the label's width is reserved for this string (a date that varies in width).
    var widestLabel: String? {
        didSet {
            guard widestLabel != oldValue else { return }
            strings = nil
            if frame.width > 0 { onWidthChange?(intrinsicWidth) }
        }
    }
    /// Room for a glyph left of the value is always kept, so the item doesn't resize when it appears.
    var reservesGlyph = false {
        didSet {
            guard reservesGlyph != oldValue else { return }
            if frame.width > 0 { onWidthChange?(intrinsicWidth) }
        }
    }
    /// How many bars the bar widget has (cores); its width is reserved for all of them.
    var barCount = 0 {
        didSet {
            guard barCount != oldValue else { return }
            if frame.width > 0 { onWidthChange?(intrinsicWidth) }
        }
    }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Returns true if anything will be redrawn.
    @discardableResult
    func update(_ model: WidgetModel, config: WidgetConfig) -> Bool {
        let chartHeight = max(1, bounds.height - 2 * Layout.ringInset)
        let kinds = config.kinds
        let pixels = kinds.contains(.chart)
            ? model.history.map { UInt8(max(0, min(1, $0)) * Float(chartHeight)) } : []
        // Ring in 2 % steps: finer arcs are invisible at 14 pt but cost a redraw.
        let ring = kinds.contains(.ring) ? Int(((model.value ?? 0) * 50).rounded()) : 0
        let hasText = kinds.contains(.text)
        let text = hasText ? model.text : ""
        let stackedNow = hasText && (config.showLabel || model.isPair)
        let battery = kinds.contains(.battery) ? Int(((model.value ?? 0) * 20).rounded()) : nil
        let new = RenderKey(config: config, label: stackedNow ? model.label : "", text: text,
                            glyph: hasText || battery != nil ? model.glyph : nil, ringSteps: ring, chartPixels: pixels,
                            barLevels: kinds.contains(.bars) ? model.barLevels : [],
                            sparkLevels: kinds.contains(.sparkline) ? model.sparkLevels : [],
                            batterySteps: battery,
                            arrowLines: kinds.contains(.arrows) ? [model.label, model.text] : [])
        let configChanged = config != self.config || model.isPair != self.model.isPair
        self.model = model
        self.config = config
        guard new != key else { return false }
        key = new
        strings = nil
        if configChanged || frame.width == 0 { onWidthChange?(intrinsicWidth) }
        needsDisplay = true
        return true
    }

    /// Fixed per config, never per value, so the menu bar never jitters.
    var intrinsicWidth: CGFloat {
        let kinds = config.orderedKinds
        var width = Layout.padding * 2 + Layout.spacing * CGFloat(max(0, kinds.count - 1))
        for kind in kinds { width += partWidth(kind) }
        return ceil(width)
    }

    private func partWidth(_ kind: WidgetKind) -> CGFloat {
        switch kind {
        case .text: textWidth
        case .arrows: arrowsWidth
        case .chart: Layout.chartWidth
        case .sparkline: Layout.sparkWidth
        case .ring: ringDiameter
        case .bars: barsWidth
        case .battery: batteryWidth
        }
    }

    private var ringDiameter: CGFloat { max(10, NSStatusBar.system.thickness - 2 * Layout.ringInset) }

    private var barsWidth: CGFloat {
        let count = CGFloat(max(1, barCount))
        return count * Layout.barWidth + (count - 1) * Layout.barGap
    }

    private var batteryWidth: CGFloat { Layout.glyphSize + Layout.glyphGap + Layout.batteryBody.width + Layout.batteryNub + 1 }

    private var stacked: Bool { config.showLabel || model.isPair }

    private var valueFont: NSFont {
        model.isPair ? Layout.pairFont : stacked ? Layout.stackedValueFont : Layout.valueFont
    }

    private func widest(_ font: NSFont) -> CGFloat {
        widestTexts.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
    }

    private var textWidth: CGFloat {
        let valueWidth = widest(valueFont) + glyphReserve
        guard stacked else { return ceil(valueWidth) }
        // The second line of a CPU/GPU pair is as wide as the first; a name only needs its own width.
        guard !model.isPair else { return ceil(valueWidth) }
        let labelWidth = ((widestLabel ?? model.label) as NSString).size(withAttributes: [.font: Layout.labelFont]).width
        return ceil(max(valueWidth, labelWidth))
    }

    /// Whether every string `model` would draw fits the width reserved for it (checked by the Debug self-check).
    func fits(_ model: WidgetModel, config: WidgetConfig) -> Bool {
        self.model = model
        self.config = config
        func width(_ text: String, _ font: NSFont) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
        var fits = true
        if config.kinds.contains(.text) {
            let reserved = textWidth - glyphReserve
            fits = fits && width(model.text, valueFont) <= reserved && (!stacked || model.isPair || width(model.label, Layout.labelFont) <= reserved)
            if model.isPair { fits = fits && width(model.label, Layout.pairFont) <= reserved }
        }
        if config.kinds.contains(.arrows) {
            fits = fits && max(width(model.label, Layout.pairFont), width(model.text, Layout.pairFont)) <= arrowsWidth - Layout.arrowSlot
        }
        return fits
    }

    private var arrowsWidth: CGFloat { ceil(Layout.arrowSlot + widest(Layout.pairFont)) }

    override func draw(_ dirtyRect: NSRect) {
        var x = Layout.padding
        for kind in config.orderedKinds {
            let width = partWidth(kind)
            let plot = NSRect(x: x, y: Layout.ringInset, width: width, height: bounds.height - 2 * Layout.ringInset)
            switch kind {
            case .text: drawText(in: NSRect(x: x, y: 0, width: width, height: bounds.height))
            case .arrows: drawArrows(in: NSRect(x: x, y: 0, width: width, height: bounds.height))
            case .chart: drawChart(in: plot)
            case .sparkline: drawSparkline(in: plot)
            case .ring:
                let d = ringDiameter
                drawRing(in: NSRect(x: x, y: (bounds.height - d) / 2, width: d, height: d))
            case .bars: drawBars(in: plot)
            case .battery: drawBattery(in: NSRect(x: x, y: 0, width: width, height: bounds.height))
            }
            x += width + Layout.spacing
        }
    }

    /// Built once per change, not per draw: AppKit draws the view once per display.
    private var strings: (label: NSAttributedString, value: NSAttributedString)?

    private func makeStrings() -> (label: NSAttributedString, value: NSAttributedString) {
        let paragraph = NSMutableParagraphStyle()
        // A lone value sits flush right, so its unit stays put as the digits change length; a name over a value is centred.
        paragraph.alignment = stacked ? .center : .right
        let label = NSAttributedString(string: model.label, attributes: [
            .font: model.isPair ? Layout.pairFont : Layout.labelFont,
            .foregroundColor: model.isPair ? NSColor.labelColor : NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
        ])
        let value = NSAttributedString(string: model.text, attributes: [
            .font: valueFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ])
        return (label, value)
    }

    private func drawText(in full: NSRect) {
        let strings = self.strings ?? makeStrings()
        self.strings = strings
        var rect = full
        if glyphReserve > 0 {
            if let name = model.glyph {
                TintedSymbol.draw(name, size: Layout.glyphSize, centeredAt: NSPoint(x: full.minX + Layout.glyphSize / 2, y: full.midY))
            }
            rect.origin.x += glyphReserve
            rect.size.width -= glyphReserve
        }
        if model.isPair {
            let mid = rect.midY
            strings.label.draw(in: NSRect(x: rect.minX, y: mid, width: rect.width, height: 11.5))
            strings.value.draw(in: NSRect(x: rect.minX, y: mid - 11.5, width: rect.width, height: 11.5))
        } else if stacked {
            let mid = rect.midY
            strings.label.draw(in: NSRect(x: rect.minX, y: mid + 0.5, width: rect.width, height: 10))
            strings.value.draw(in: NSRect(x: rect.minX, y: mid - 11.5, width: rect.width, height: 13))
        } else {
            let height = strings.value.size().height
            strings.value.draw(in: NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height))
        }
    }

    /// Two speeds, an arrow at the left of each and the number flush right, so the arrows and the units line up
    /// whatever the numbers are.
    private func drawArrows(in rect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [.font: Layout.pairFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        let lines = [model.label, model.text]
        for (index, line) in lines.enumerated() {
            let y = index == 0 ? rect.midY : rect.midY - 11.5
            let row = NSRect(x: rect.minX + Layout.arrowSlot, y: y, width: rect.width - Layout.arrowSlot, height: 11.5)
            (line as NSString).draw(in: row, withAttributes: attributes)
            if model.rateSymbols.indices.contains(index) {
                TintedSymbol.draw(model.rateSymbols[index], size: Layout.glyphSize, centeredAt: NSPoint(x: rect.minX + Layout.glyphSize / 2, y: y + 5.75))
            }
        }
    }

    private func drawBattery(in rect: NSRect) {
        let bodyX = rect.minX + Layout.glyphSize + Layout.glyphGap
        if let name = model.glyph {
            TintedSymbol.draw(name, size: Layout.glyphSize, centeredAt: NSPoint(x: rect.minX + Layout.glyphSize / 2, y: rect.midY))
        }
        let body = NSRect(x: bodyX, y: rect.midY - Layout.batteryBody.height / 2, width: Layout.batteryBody.width, height: Layout.batteryBody.height)
        let outline = NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), xRadius: 2.5, yRadius: 2.5)
        outline.lineWidth = 1
        NSColor.labelColor.withAlphaComponent(0.55).setStroke()
        outline.stroke()
        NSColor.labelColor.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: NSRect(x: body.maxX + 0.5, y: rect.midY - 2, width: Layout.batteryNub, height: 4), xRadius: 0.75, yRadius: 0.75).fill()
        let fraction = CGFloat(max(0, min(1, model.value ?? 0)))
        let inner = body.insetBy(dx: 2, dy: 2)
        guard fraction > 0 else { return }
        let fill = NSRect(x: inner.minX, y: inner.minY, width: max(1.5, inner.width * fraction), height: inner.height)
        // Low charge reads red whether or not the glyph beside it says "charging".
        (fraction <= 0.2 && model.glyph != "bolt.fill" ? NSColor.systemRed : NSColor.labelColor).setFill()
        NSBezierPath(roundedRect: fill, xRadius: 1, yRadius: 1).fill()
    }

    /// One thin bar per core (or per memory part): a faint track and the level from the bottom, in eight steps.
    private func drawBars(in rect: NSRect) {
        let count = max(1, barCount)
        for index in 0..<count {
            let x = rect.minX + CGFloat(index) * (Layout.barWidth + Layout.barGap)
            let track = NSRect(x: x, y: rect.minY, width: Layout.barWidth, height: rect.height)
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            track.fill()
            guard model.barLevels.indices.contains(index), model.barLevels[index] > 0 else { continue }
            let level = CGFloat(model.barLevels[index]) / CGFloat(WidgetModel.barSteps)
            NSPalette.accent.setFill()
            NSRect(x: x, y: rect.minY, width: Layout.barWidth, height: max(1, rect.height * level)).fill()
        }
    }

    /// A line through at most ``WidgetModel/sparkPoints`` points, newest at the right edge.
    private func drawSparkline(in rect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.2).setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 0.5).fill()
        let levels = model.sparkLevels
        guard levels.count > 1 else { return }
        let step = rect.width / CGFloat(WidgetModel.sparkPoints - 1)
        let firstX = rect.maxX - CGFloat(levels.count - 1) * step
        let path = NSBezierPath()
        for (index, level) in levels.enumerated() {
            let point = NSPoint(x: firstX + CGFloat(index) * step,
                                y: rect.minY + 1 + (rect.height - 2) * CGFloat(level) / CGFloat(WidgetModel.sparkSteps))
            index == 0 ? path.move(to: point) : path.line(to: point)
        }
        path.lineWidth = 1.25
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        NSPalette.accent.setStroke()
        path.stroke()
    }

    private func drawChart(in rect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        let values = model.history
        guard values.count > 1 else { return }
        let step = rect.width / CGFloat(WidgetModel.chartSamples - 1)
        let firstX = rect.maxX - CGFloat(values.count - 1) * step
        let path = NSBezierPath()
        path.move(to: NSPoint(x: firstX, y: rect.minY))
        for (i, value) in values.enumerated() {
            path.line(to: NSPoint(x: firstX + CGFloat(i) * step, y: rect.minY + CGFloat(max(0, min(1, value))) * rect.height))
        }
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        path.close()
        NSPalette.accent.setFill()
        path.fill()
    }

    private func drawRing(in rect: NSRect) {
        let width: CGFloat = 2.5
        let inset = rect.insetBy(dx: width / 2, dy: width / 2)
        let track = NSBezierPath(ovalIn: inset)
        track.lineWidth = width
        NSColor.labelColor.withAlphaComponent(0.18).setStroke()
        track.stroke()
        let fraction = CGFloat(max(0, min(1, model.value ?? 0)))
        guard fraction > 0 else { return }
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: inset.midX, y: inset.midY), radius: inset.width / 2,
                      startAngle: 90, endAngle: 90 - fraction * 360, clockwise: true)
        arc.lineWidth = width
        NSPalette.accent.setStroke()
        arc.stroke()
    }
}
