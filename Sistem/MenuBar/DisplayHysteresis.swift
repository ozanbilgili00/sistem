/// Keeps a menu bar number from redrawing on every wobble.
///
/// On recent macOS every change to a status item is re-rendered on the CPU once
/// per display's menu bar (`NSStatusItem _updateReplicants`, ~7 ms on three
/// displays), so redraws, not sampling, dominate idle cost — and they track how
/// jumpy the value is, i.e. how busy the user is. Two limits, measured on this
/// Mac 2026-10-04:
/// - A change must reach 1.5 points (rounded values 2 apart). Idle CPU wobbles
///   4-6-5-6 %: rounded changes on 72 % of ticks, 14 % with this threshold. A
///   smaller real difference still shows after `patience` ticks.
/// - At most one update per `minTicks` ticks (4 s at the default interval;
///   Activity Monitor refreshes every 5 s), unless the jump is `bigJump` or more.
///   This bounds the cost however busy the machine is.
struct DisplayHysteresis {
    /// Fractions: 0.015 is 1.5 percentage points.
    var threshold: Float = 0.015
    var bigJump: Float = 0.05
    var patience = 5
    var minTicks = 2

    private var shown: Float?
    private var pending = 0
    private var sinceUpdate = 0

    mutating func filter(_ value: Float?) -> Float? {
        guard let value else { return shown }
        sinceUpdate += 1
        guard let current = shown else {
            accept(value)
            return value
        }
        let difference = abs(value - current)
        if difference >= bigJump {
            accept(value)
        } else if difference >= threshold {
            if sinceUpdate >= minTicks { accept(value) }
        } else if difference >= 0.005 {  // rounds to a different whole percent
            pending += 1
            if pending >= patience, sinceUpdate >= minTicks { accept(value) }
        } else {
            pending = 0
        }
        return shown
    }

    private mutating func accept(_ value: Float) {
        shown = value
        pending = 0
        sinceUpdate = 0
    }
}
