/// How a byte rate is written: decimal units (the way Finder and Activity Monitor
/// count), two significant digits, so a menu bar number is short and doesn't flicker.
public enum RateScale {
    public static let units = ["B", "KB", "MB", "GB"]

    /// The value in the largest unit that keeps it under 1000 after rounding, and that
    /// unit's index into ``units``.
    public static func scale(_ bytesPerSecond: Double) -> (value: Double, unit: Int) {
        var value = max(0, bytesPerSecond)
        var unit = 0
        while unit < units.count - 1, display(value, unit: unit) >= 1000 {
            value /= 1000
            unit += 1
        }
        return (value, unit)
    }

    /// What is actually shown: bytes whole, 1–9.9 with one decimal, above that whole.
    static func display(_ value: Double, unit: Int) -> Double {
        if unit == 0 || value >= 10 { return value.rounded() }
        return (value * 10).rounded() / 10
    }

    /// Identifies the text a rate would show; equal keys mean an identical menu bar string.
    public static func displayKey(_ bytesPerSecond: Double) -> Int {
        let (value, unit) = scale(bytesPerSecond)
        return unit * 1_000_000 + Int((display(value, unit: unit) * 10).rounded())
    }

    /// The number part of the display, as a Double to be formatted by the caller's locale.
    public static func displayed(_ bytesPerSecond: Double) -> (value: Double, fractionDigits: Int, unit: String) {
        let (value, unit) = scale(bytesPerSecond)
        let shown = display(value, unit: unit)
        return (shown, unit > 0 && shown < 10 ? 1 : 0, units[unit])
    }
}

/// Keeps a pair of menu bar speeds (upload/download, read/write) from redrawing the
/// status item on every tick. Every redraw costs ~6 ms and 4 wakeups on a three-display
/// Mac (measured in Faz 3/4), and traffic is bursty, so:
/// - a change must alter the shown text **and** be at least `relative` of the value;
/// - at most one update per `minTicks` ticks (4 s at the default interval);
/// - unless a speed changed by an order of magnitude (idle ↔ busy), which shows at once.
public struct RateHysteresis: Sendable {
    public var minTicks = 2
    public var relative = 0.10
    /// Below this a rate counts as "nothing" when judging order-of-magnitude jumps.
    public var floor = 1_000.0

    private var shown: (Double, Double)?
    private var sinceUpdate = 0

    public init(minTicks: Int = 2, relative: Double = 0.10) {
        self.minTicks = minTicks
        self.relative = relative
    }

    public mutating func filter(_ first: Double, _ second: Double) -> (Double, Double) {
        sinceUpdate += 1
        guard let current = shown else {
            accept(first, second)
            return (first, second)
        }
        let pairs = [(current.0, first), (current.1, second)]
        let visible = pairs.contains { isVisibleChange(from: $0, to: $1) }
        let jump = pairs.contains { isOrderOfMagnitude(from: $0, to: $1) }
        if jump || (visible && sinceUpdate >= minTicks) { accept(first, second) }
        return shown ?? (first, second)
    }

    private func isVisibleChange(from old: Double, to new: Double) -> Bool {
        RateScale.displayKey(old) != RateScale.displayKey(new) && abs(new - old) >= max(old, new) * relative
    }

    private func isOrderOfMagnitude(from old: Double, to new: Double) -> Bool {
        let low = max(min(old, new), floor), high = max(max(old, new), floor)
        return high / low >= 10
    }

    private mutating func accept(_ first: Double, _ second: Double) {
        shown = (first, second)
        sinceUpdate = 0
    }
}
