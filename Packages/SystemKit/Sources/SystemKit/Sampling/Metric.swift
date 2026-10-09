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

    /// CPU core temperatures only (63 SMC keys, ~0.7 ms of CPU): all the menu bar item
    /// needs. Separate from `.sensors` so a widget alone never pays for the full list.
    case temperature
    /// `.temperature` plus the GPU's sensors, for the two-line CPU/GPU widget.
    case temperatureStack
    /// Every sensor: temperatures, fans, voltages, currents, power (~260 keys, ~3.5 ms of
    /// CPU). Only while the Sensors page or popover is on screen.
    case sensors

    /// Charge, state and time remaining arrive as power-source events (no polling); a tick
    /// only rereads the electrical details. Every 15th tick as a safety net.
    case battery
    /// Paired devices and their battery levels via `system_profiler`: a child process, so
    /// only while a Bluetooth page or popover is on screen, every 30th tick.
    case bluetooth

    /// Capacity of the startup volume alone (one resource-value read). For the "disk
    /// nearly full" notification rule; the Disk page gets the same figure from `.disk`.
    case diskSpace
    /// Connectivity from `NWPathMonitor` events. Reads nothing on a tick: it only keeps the
    /// monitor running, so the sampler never wakes for it.
    case connectivity

    /// How often it is read, in base ticks (PLAN.md §3-A): CPU and RAM every tick,
    /// sensors every 2nd, battery every 15th, Bluetooth every 30th.
    public var everyTicks: Int {
        switch self {
        case .cpu, .memory, .processes, .gpu, .power, .cpuFrequency, .disk, .network: 1
        case .networkInfo: 5
        case .temperature, .temperatureStack, .sensors: 2
        case .battery: 15
        case .diskHealth, .bluetooth: 30
        case .diskSpace: 15
        case .connectivity: 1
        }
    }

    /// True for metrics that arrive as events: the sampler's timer has nothing to do for them.
    public var isEventDriven: Bool { self == .connectivity }
}
