/// Something the sampler can read. A metric is read only while some consumer —
/// a menu bar widget, an open popover, a visible page — has asked for it.
public enum Metric: String, CaseIterable, Sendable {
    case cpu
    case memory
    /// Top-process lists. Costly (≈900 rusage calls + `ps`), so only while a
    /// list is on screen.
    case processes

    /// How often it is read, in base ticks (PLAN.md §3-A): CPU and RAM every tick,
    /// sensors every 2nd, battery every 15th, Bluetooth every 30th.
    public var everyTicks: Int {
        switch self {
        case .cpu, .memory, .processes: 1
        }
    }
}
