import Dispatch

/// What the sampler should be doing right now. Computed on the main actor from
/// demand, power policy and pause state; the sampler just obeys it.
public struct SamplerConfig: Sendable, Equatable {
    /// Seconds between base ticks, after the power policy's multiplier.
    public var interval: Double
    public var metrics: Set<Metric>
    public var paused: Bool

    public init(interval: Double, metrics: Set<Metric>, paused: Bool) {
        self.interval = interval
        self.metrics = metrics
        self.paused = paused
    }

    /// True when the timer has nothing to do and should not exist at all.
    public var isIdle: Bool { paused || metrics.isEmpty }
}

/// The one place readers live and the one timer that wakes the app.
///
/// Runs on a private serial `.utility` queue that is also the actor's executor, so
/// the timer handler is already isolated and non-Sendable readers (IOKit, SMC,
/// HID handles in later phases) never cross threads. Nothing but ``Snapshot``
/// values leaves.
public actor SamplerActor {
    private let queue = DispatchSerialQueue(label: "sistem.sampler", qos: .utility)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let deliver: @Sendable (Snapshot) -> Void
    private let pathMonitor: NetworkPathMonitor
    private var config = SamplerConfig(interval: 2, metrics: [], paused: true)
    private var timer: DispatchSourceTimer?
    private var tick = 0

    private var cpu = CPULoadReader()
    private let memory = MemoryReader()
    private var processes = ProcessLister()
    // Opened on first demand and then kept: the IOKit service, SMC connection and
    // IOReport subscriptions are made once (PLAN.md §3-B). nil = unavailable here.
    private lazy var gpu = GPUReader()
    // The two IOReport readers share one subscription, and with it one sample per
    // tick: the CPU and energy groups cost ~4 ms of CPU to sample, however few
    // channels are wanted.
    private lazy var performance = IOReport.library?.performanceSubscription()
    private lazy var power: PowerReader? = {
        let reader = PowerReader(subscription: performance)
        return reader.isAvailable ? reader : nil
    }()
    private lazy var cpuFrequency = CPUFrequencyReader(subscription: performance)
    // Drive services are matched once; hot-plug callbacks land on this queue.
    private lazy var disk = DiskReader(queue: queue)
    // nil where the system refuses SMART (external drives, virtual machines).
    private lazy var health = NVMeHealthReader()
    private var network = NetworkReader()
    private lazy var wifi = WiFiReader()
    /// Metrics that were just asked for and read slower than every tick: read once at
    /// the next tick so a page doesn't sit empty for several intervals.
    private var due: Set<Metric> = []

    /// `deliver` is called on the sampler queue after every tick that read anything.
    public init(pathMonitor: NetworkPathMonitor = NetworkPathMonitor(), deliver: @escaping @Sendable (Snapshot) -> Void) {
        self.pathMonitor = pathMonitor
        self.deliver = deliver
    }

    /// FIFO, unlike spawning a Task per change, so the last config sent wins.
    public nonisolated func send(_ config: SamplerConfig) {
        queue.async { self.assumeIsolated { $0.apply(config) } }
    }

    private func apply(_ new: SamplerConfig) {
        let old = config
        config = new
        guard !new.isIdle else {
            timer?.cancel()
            timer = nil
            return
        }
        // Prime newly wanted metrics, and everything after a pause, so the first
        // delta covers one interval rather than the whole time we weren't looking.
        let primeAll = old.isIdle
        for metric in new.metrics where primeAll || !old.metrics.contains(metric) {
            prime(metric)
            if metric.everyTicks > 1 { due.insert(metric) }
        }
        if timer == nil || old.interval != new.interval { schedule() }
    }

    private func schedule() {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        let interval = DispatchTimeInterval.milliseconds(Int(config.interval * 1000))
        // 20 % leeway lets the kernel fold our wakeup into someone else's.
        source.schedule(deadline: .now() + interval, repeating: interval,
                        leeway: .milliseconds(Int(config.interval * 200)))
        source.setEventHandler { [weak self] in
            self?.assumeIsolated { $0.fire() }
        }
        source.activate()
        timer = source
    }

    private func prime(_ metric: Metric) {
        switch metric {
        case .cpu:
            cpu.reset()
            _ = cpu.sample()
        case .memory:
            break  // stateless
        case .processes:
            processes.reset()
            _ = processes.sample()
        case .gpu:
            break  // stateless
        case .power:
            power?.reset()
            _ = power?.sample()
        case .cpuFrequency:
            cpuFrequency?.reset()
            _ = cpuFrequency?.sample()
        case .disk:
            disk.prime()
        case .diskHealth:
            break  // stateless
        case .network:
            network.reset()
            _ = network.sample()
        case .networkInfo:
            break  // stateless
        }
    }

    private func fire() {
        tick &+= 1
        var snapshot = Snapshot()
        var read = false
        for metric in config.metrics where tick % metric.everyTicks == 0 || due.contains(metric) {
            switch metric {
            case .cpu:
                snapshot.cpu = cpu.sample()
            case .memory:
                snapshot.memory = memory.sample()
            case .processes:
                snapshot.processes = processes.sample()
            case .gpu:
                snapshot.gpu = gpu?.sample()
            case .power:
                snapshot.power = power?.sample()
            case .cpuFrequency:
                snapshot.cpuFrequency = cpuFrequency?.sample()
            case .disk:
                snapshot.disk = disk.sample()
            case .diskHealth:
                snapshot.diskHealth = health?.read()
            case .network:
                snapshot.network = network.sample().map {
                    var sample = $0
                    sample.primary = pathMonitor.primaryInterfaceName
                    return sample
                }
            case .networkInfo:
                snapshot.networkInfo = NetworkInfoSample(wifi: wifi.sample(), addresses: NetworkReader.localAddresses())
            }
            read = true
        }
        due.removeAll()
        if read { deliver(snapshot) }
    }
}
