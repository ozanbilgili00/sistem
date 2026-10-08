/// Something the sampler can read. A metric is read only while some consumer —
/// a menu bar widget, an open popover, a visible page — has asked for it.
public enum Metric: String, CaseIterable, Sendable {
    case cpu
    case memory
    /// Top-process lists. Costly (≈900 rusage calls + `ps`), so only while a
    /// list is on screen.
    case processes
    /// GPU load and memory: one registry property read. All the GPU menu bar widget needs.
    case gpu
    /// Watts: CPU and system from the SMC, GPU and ANE from IOReport energy counters.
    /// Separate from `.gpu` so a menu bar widget alone never pays for the IOReport
    /// delta; only a view that shows power asks for it.
    case power
    /// Per-cluster CPU clock from IOReport DVFS residencies. Only the CPU page.
    case cpuFrequency
    /// Drive throughput every tick; volume capacity on every 15th (inside the reader).
    case disk
    /// NVMe SMART: wear, spare blocks, bytes written. Changes over weeks, so every
    /// 30th tick, and only the Disk page asks.
    case diskHealth
    /// Interface byte counters: total, per interface.
    case network
    /// Wi-Fi link details and local addresses: slower, and only the network page
    /// and popover show them.
    case networkInfo

    /// How often it is read, in base ticks (PLAN.md §3-A): CPU and RAM every tick,
    /// sensors every 2nd, battery every 15th, Bluetooth every 30th.
    public var everyTicks: Int {
        switch self {
        case .cpu, .memory, .processes, .gpu, .power, .cpuFrequency, .disk, .network: 1
        case .networkInfo: 5
        case .diskHealth: 30
        }
    }
}
