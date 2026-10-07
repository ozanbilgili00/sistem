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

    static let chartSamples = 30  // one minute at the default 2 s

    @MainActor static func make(_ module: ModuleID, store: MetricStore) -> WidgetModel {
        switch module {
        case .cpu:
            let count = min(store.cpuUser.count, chartSamples)
            let start = store.cpuUser.count - count
            let history = (0..<count).map { store.cpuUser[start + $0] + store.cpuSystem[start + $0] }
            let value = smoothed(history, fallback: store.cpu?.total)
            return WidgetModel(label: "CPU", value: value, text: Format.percent(value), history: history)
        case .gpu:
            let count = min(store.gpuDevice.count, chartSamples)
            let start = store.gpuDevice.count - count
            let history = (0..<count).map { store.gpuDevice[start + $0] }
            // Device Utilization %, the same number Activity Monitor's GPU history draws.
            // Idle GPU load is bursty (compositing for every display), so a longer window.
            let value = smoothed(history, window: 3, fallback: store.gpu?.device)
            return WidgetModel(label: "GPU", value: value, text: Format.percent(value), history: history)
        case .ram:
            let count = min(store.memoryApp.count, chartSamples)
            let start = store.memoryApp.count - count
            let history = (0..<count).map {
                store.memoryApp[start + $0] + store.memoryWired[start + $0] + store.memoryCompressed[start + $0]
            }
            let value = store.memory?.usedFraction
            return WidgetModel(label: "RAM", value: value, text: Format.percent(value), history: history)
        default:
            return WidgetModel(label: String(localized: module.menuBarTitle), value: nil, text: "—", history: [])
        }
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

/// Draws one module's widgets inside a status item button.
///
/// Redraws only when what it would draw changes: the text, the ring in 2 %
/// steps, or the chart's pixel heights (PLAN.md §3-C). A steady 5 % costs
/// nothing after the first frame. Clicks pass through to the button underneath.
final class WidgetView: NSView {
    private struct RenderKey: Equatable {
        var config: WidgetConfig
        var label: String
        var text: String
        var ringSteps: Int
        var chartPixels: [UInt8]
    }

    private enum Layout {
        static let padding: CGFloat = 3
        static let spacing: CGFloat = 5
        static let chartWidth: CGFloat = 30
        static let ringInset: CGFloat = 4
        static let labelFont = NSFont.systemFont(ofSize: 7.5, weight: .semibold)
        static let stackedValueFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    }

    var onWidthChange: ((CGFloat) -> Void)?

    private var config = WidgetConfig.default
    private var model = WidgetModel(label: "", value: nil, text: "—", history: [])
    private var key: RenderKey?

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
        let pixels = config.kinds.contains(.chart)
            ? model.history.map { UInt8(max(0, min(1, $0)) * Float(chartHeight)) } : []
        // Ring in 2 % steps: finer arcs are invisible at 14 pt but cost a redraw.
        let ring = config.kinds.contains(.ring) ? Int(((model.value ?? 0) * 50).rounded()) : 0
        let text = config.kinds.contains(.text) ? model.text : ""
        let new = RenderKey(config: config, label: config.showLabel ? model.label : "", text: text,
                            ringSteps: ring, chartPixels: pixels)
        let configChanged = config != self.config
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
        for kind in kinds {
            switch kind {
            case .text: width += textWidth
            case .chart: width += Layout.chartWidth
            case .ring: width += ringDiameter
            }
        }
        return ceil(width)
    }

    private var ringDiameter: CGFloat { max(10, NSStatusBar.system.thickness - 2 * Layout.ringInset) }

    private var stacked: Bool { config.showLabel }

    private var textWidth: CGFloat {
        let widest = Format.percent(1)  // "%100" / "100%"
        let valueWidth = (widest as NSString).size(withAttributes: [.font: stacked ? Layout.stackedValueFont : Layout.valueFont]).width
        guard stacked else { return ceil(valueWidth) }
        let labelWidth = (model.label as NSString).size(withAttributes: [.font: Layout.labelFont]).width
        return ceil(max(valueWidth, labelWidth))
    }

    override func draw(_ dirtyRect: NSRect) {
        var x = Layout.padding
        for kind in config.orderedKinds {
            switch kind {
            case .text:
                drawText(in: NSRect(x: x, y: 0, width: textWidth, height: bounds.height))
                x += textWidth
            case .chart:
                drawChart(in: NSRect(x: x, y: Layout.ringInset, width: Layout.chartWidth, height: bounds.height - 2 * Layout.ringInset))
                x += Layout.chartWidth
            case .ring:
                let d = ringDiameter
                drawRing(in: NSRect(x: x, y: (bounds.height - d) / 2, width: d, height: d))
                x += d
            }
            x += Layout.spacing
        }
    }

    /// Built once per change, not per draw: AppKit draws the view once per display.
    private var strings: (label: NSAttributedString, value: NSAttributedString)?

    private func makeStrings() -> (label: NSAttributedString, value: NSAttributedString) {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let label = NSAttributedString(string: model.label, attributes: [
            .font: Layout.labelFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: center,
        ])
        let value = NSAttributedString(string: model.text, attributes: [
            .font: stacked ? Layout.stackedValueFont : Layout.valueFont,
            .foregroundColor: NSColor.labelColor, .paragraphStyle: center,
        ])
        return (label, value)
    }

    private func drawText(in rect: NSRect) {
        let strings = self.strings ?? makeStrings()
        self.strings = strings
        if stacked {
            let mid = rect.midY
            strings.label.draw(in: NSRect(x: rect.minX, y: mid + 0.5, width: rect.width, height: 10))
            strings.value.draw(in: NSRect(x: rect.minX, y: mid - 11.5, width: rect.width, height: 13))
        } else {
            let height = strings.value.size().height
            strings.value.draw(in: NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height))
        }
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
