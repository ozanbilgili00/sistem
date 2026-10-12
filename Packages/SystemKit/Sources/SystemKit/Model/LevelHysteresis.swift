/// Quantizing for the menu bar's bar and line graphs. A graph is redrawn once per display's menu bar (~6 ms and ~4 wakeups
/// on a three-display Mac), and its history shifts by one sample every tick, so without limits it would redraw every tick.
public enum LevelScale {
    /// `values` (0...1) as whole steps 0...`steps`.
    public static func levels(_ values: [Float], steps: Int) -> [UInt8] {
        values.map { UInt8(max(0, min(1, $0)) * Float(steps) + 0.5) }
    }

    /// At most `count` points: the oldest samples are averaged in equal groups, so the line keeps its shape with fewer points.
    public static func resample(_ values: [Float], to count: Int) -> [Float] {
        guard count > 0, values.count > count else { return values }
        return (0..<count).map { index in
            let from = index * values.count / count, to = max(from + 1, (index + 1) * values.count / count)
            return values[from..<to].reduce(0, +) / Float(to - from)
        }
    }
}

/// Keeps a graph from redrawing on every wobble. Works on already quantized levels:
/// - a level or more that moved by `bigJump` shows at once;
/// - a move of `step` shows after `minTicks` ticks since the last update;
/// - smaller moves (1 level) show only after `patience` ticks of them, then also respect `minTicks`;
/// - nothing visible changes, nothing is returned new.
/// The bound: at most one redraw per `minTicks` ticks for ordinary movement, however busy the Mac is.
public struct LevelHysteresis: Sendable {
    public var step = 2
    public var bigJump = 4
    public var minTicks = 3
    public var patience = 8

    private var shown: [UInt8]?
    private var pending = 0
    private var sinceUpdate = 0

    public init(step: Int = 2, bigJump: Int = 4, minTicks: Int = 3, patience: Int = 8) {
        self.step = step
        self.bigJump = bigJump
        self.minTicks = minTicks
        self.patience = patience
    }

    public mutating func filter(_ levels: [UInt8]) -> [UInt8] {
        sinceUpdate += 1
        guard let current = shown, current.count == levels.count else {
            accept(levels)
            return levels
        }
        var difference = 0
        for (old, new) in zip(current, levels) { difference = max(difference, abs(Int(old) - Int(new))) }
        if difference >= bigJump {
            accept(levels)
        } else if difference >= step {
            if sinceUpdate >= minTicks { accept(levels) }
        } else if difference >= 1 {
            pending += 1
            if pending >= patience, sinceUpdate >= minTicks { accept(levels) }
        } else {
            pending = 0
        }
        return shown ?? levels
    }

    private mutating func accept(_ levels: [UInt8]) {
        shown = levels
        pending = 0
        sinceUpdate = 0
    }
}
