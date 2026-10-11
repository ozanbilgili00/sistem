import CoreGraphics

/// Where each section of the menu bar strip sits, and which section a click belongs to. Pure: widths in, numbers out,
/// so the click mapping is tested without a menu bar.
public struct StripLayout: Equatable, Sendable {
    /// Space between two neighbouring sections, close to the spacing macOS puts between separate items.
    public static let gap: CGFloat = 4

    public var widths: [CGFloat]

    public init(widths: [CGFloat]) { self.widths = widths }

    public var totalWidth: CGFloat {
        widths.reduce(0, +) + Self.gap * CGFloat(max(0, widths.count - 1))
    }

    /// The horizontal extent of every section, left to right.
    public var spans: [ClosedRange<CGFloat>] {
        var x: CGFloat = 0
        return widths.map { width in
            defer { x += width + Self.gap }
            return x...(x + width)
        }
    }

    /// The section a click at `x` (in the strip's own coordinates, 0 at the left edge) belongs to. Every point of the strip
    /// belongs to someone: a gap goes to the section on its right from its middle on (the boundary pixel itself belongs to the
    /// right-hand section), and a point left of the first or right of the last section goes to that one.
    public func index(at x: CGFloat) -> Int? {
        guard !widths.isEmpty else { return nil }
        let spans = spans
        for index in 1..<max(1, spans.count) {
            let boundary = (spans[index - 1].upperBound + spans[index].lowerBound) / 2
            if x < boundary { return index - 1 }
        }
        return spans.count - 1
    }
}
