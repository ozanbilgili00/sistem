import SwiftUI

/// Colors for the three parts of a CPU reading. User work is the accent; system
/// work the same blue, lighter; idle is just the track.
public enum UsageColors {
    public static let user = Palette.accent
    public static let system = Palette.accent.opacity(0.42)
    public static let track = Palette.surface2
    /// Legend swatch for idle: the track itself is too faint to read as a key.
    public static let idleSwatch = Palette.inkTertiary.opacity(0.45)
}

/// A ring of stacked segments, each a fraction of the full circle, starting at
/// twelve o'clock. Drawn in one Canvas pass; no animation (PLAN.md §3-C).
public struct UsageRing<Center: View>: View {
    public struct Segment {
        public let fraction: Double
        public let color: Color
        public init(_ fraction: Double, _ color: Color) {
            self.fraction = fraction
            self.color = color
        }
    }

    private let segments: [Segment]
    private let lineWidth: CGFloat
    private let center: Center

    public init(_ segments: [Segment], lineWidth: CGFloat = 10, @ViewBuilder center: () -> Center) {
        self.segments = segments
        self.lineWidth = lineWidth
        self.center = center()
    }

    public var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let rect = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
                .insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            let style = StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
            context.stroke(Path(ellipseIn: rect), with: .color(UsageColors.track), style: style)
            var start = -90.0
            for segment in segments where segment.fraction > 0 {
                let sweep = min(segment.fraction, 1) * 360
                var arc = Path()
                arc.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2,
                           startAngle: .degrees(start), endAngle: .degrees(start + sweep), clockwise: false)
                context.stroke(arc, with: .color(segment.color), style: style)
                start += sweep
            }
        }
        // The arcs repeat the legend's numbers; VoiceOver reads the center text.
        .accessibilityHidden(true)
        .overlay { center }
    }
}

/// Stacked area history. `layers[0]` sits at the bottom; each value is 0...1.
/// Newest sample at the right edge; the chart fills in from the right as history
/// accumulates, with `capacity` slots across the full width.
public struct HistoryChart: View {
    public struct Layer {
        public let values: [Float]
        public let color: Color
        public init(_ values: [Float], _ color: Color) {
            self.values = values
            self.color = color
        }
    }

    private let layers: [Layer]
    private let capacity: Int
    private let gridLines: Bool

    public init(_ layers: [Layer], capacity: Int, gridLines: Bool = true) {
        self.layers = layers
        self.capacity = max(capacity, 2)
        self.gridLines = gridLines
    }

    public var body: some View {
        Canvas { context, size in
            if gridLines {
                for fraction in [0.25, 0.5, 0.75] {
                    let y = (size.height * (1 - fraction)).rounded() + 0.5
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(Palette.line))
                }
            }
            let count = layers.map(\.values.count).min() ?? 0
            guard count > 1 else { return }
            let step = size.width / CGFloat(capacity - 1)
            let firstX = size.width - CGFloat(count - 1) * step
            var base = [CGFloat](repeating: 0, count: count)
            for layer in layers {
                var top = base
                for i in 0..<count {
                    top[i] = min(1, base[i] + CGFloat(layer.values[layer.values.count - count + i]))
                }
                var area = Path()
                area.move(to: CGPoint(x: firstX, y: size.height * (1 - base[0])))
                for i in 0..<count {
                    area.addLine(to: CGPoint(x: firstX + CGFloat(i) * step, y: size.height * (1 - top[i])))
                }
                for i in stride(from: count - 1, through: 0, by: -1) {
                    area.addLine(to: CGPoint(x: firstX + CGFloat(i) * step, y: size.height * (1 - base[i])))
                }
                area.closeSubpath()
                context.fill(area, with: .color(layer.color))
                base = top
            }
        }
        .accessibilityHidden(true)  // decorative: current values are shown as text
    }
}

/// One vertical bar per value (0...1), evenly spaced, on a track.
public struct BarStrip: View {
    private let values: [Float]
    private let color: Color

    public init(_ values: [Float], color: Color = Palette.accent) {
        self.values = values
        self.color = color
    }

    public var body: some View {
        Canvas { context, size in
            guard !values.isEmpty else { return }
            let gap: CGFloat = 3
            let width = (size.width - gap * CGFloat(values.count - 1)) / CGFloat(values.count)
            for (i, value) in values.enumerated() {
                let x = CGFloat(i) * (width + gap)
                let track = CGRect(x: x, y: 0, width: width, height: size.height)
                context.fill(Path(roundedRect: track, cornerRadius: 2), with: .color(UsageColors.track))
                let height = max(0, min(1, CGFloat(value))) * size.height
                guard height > 0.5 else { continue }
                let fill = CGRect(x: x, y: size.height - height, width: width, height: height)
                context.fill(Path(roundedRect: fill, cornerRadius: 2), with: .color(color))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Small legend line: swatch, name, right-aligned value.
public struct LegendRow: View {
    private let color: Color
    private let title: LocalizedStringKey
    private let value: String

    public init(_ title: LocalizedStringKey, color: Color, value: String) {
        self.title = title
        self.color = color
        self.value = value
    }

    public var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(title).font(.sistemBody).foregroundStyle(Palette.inkSecondary)
            Spacer(minLength: 8)
            Text(verbatim: value).font(.sistemValue).foregroundStyle(Palette.ink)
        }
    }
}

/// A horizontal gauge: `fraction` (0...1) of the width filled on a track. Flat, no
/// animation; the number it repeats is shown beside it as text.
public struct MeterBar: View {
    private let fraction: Double
    private let color: Color

    public init(_ fraction: Double, color: Color = Palette.accent) {
        self.fraction = fraction
        self.color = color
    }

    public var body: some View {
        Canvas { context, size in
            let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
            context.fill(track, with: .color(UsageColors.track))
            let width = max(0, min(1, fraction)) * size.width
            guard width > 0.5 else { return }
            let fill = Path(roundedRect: CGRect(x: 0, y: 0, width: max(width, size.height), height: size.height),
                            cornerRadius: size.height / 2)
            context.fill(fill, with: .color(color))
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}
