/// Latest values and history on the main actor.
///
/// Deliberately not `@Observable`: a tick would otherwise invalidate every view
/// that touched any buffer. Consumers subscribe with ``observe(_:)`` and pull what
/// they draw, on their own schedule (PLAN.md §3-C).
@MainActor
public final class MetricStore {
    public static let historyLength = 300

    public private(set) var cpu: CPUSample?
    public private(set) var cpuUser = RingBuffer(capacity: historyLength)
    public private(set) var cpuSystem = RingBuffer(capacity: historyLength)

    public private(set) var memory: MemorySample?
    /// Fractions of physical memory, stacked in this order in charts.
    public private(set) var memoryApp = RingBuffer(capacity: historyLength)
    public private(set) var memoryWired = RingBuffer(capacity: historyLength)
    public private(set) var memoryCompressed = RingBuffer(capacity: historyLength)

    public private(set) var processes: ProcessSample?

    public private(set) var gpu: GPUSample?
    /// Device utilisation, 0...1.
    public private(set) var gpuDevice = RingBuffer(capacity: historyLength)

    public private(set) var power: PowerSample?
    /// Watts, not fractions: callers scale them for drawing.
    public private(set) var gpuPower = RingBuffer(capacity: historyLength)
    public private(set) var cpuPower = RingBuffer(capacity: historyLength)

    public private(set) var cpuFrequency: CPUFrequencySample?

    public private(set) var disk: DiskSample?
    /// Capacity list, kept from the last refresh (samples only carry it now and then).
    public private(set) var diskVolumes: [DiskVolume] = []
    /// Bytes per second.
    public private(set) var diskRead = RingBuffer(capacity: historyLength)
    public private(set) var diskWrite = RingBuffer(capacity: historyLength)
    public private(set) var diskHealth: DiskHealth?

    public private(set) var network: NetworkSample?
    /// Bytes per second.
    public private(set) var networkDown = RingBuffer(capacity: historyLength)
    public private(set) var networkUp = RingBuffer(capacity: historyLength)
    public private(set) var networkInfo: NetworkInfoSample?
    public private(set) var temperature: TemperatureSample?
    public private(set) var sensors: SensorSample?
    /// °C, not fractions: hottest CPU core sensor and hottest GPU sensor.
    public private(set) var cpuTemperature = RingBuffer(capacity: historyLength)
    public private(set) var gpuTemperature = RingBuffer(capacity: historyLength)
    public private(set) var path: PathState?
    /// Newest first, in memory only.
    public private(set) var connectionEvents: [ConnectionEvent] = []
    public static let connectionEventLimit = 50
    public private(set) var publicIP: PublicIPState = .off
    public private(set) var latency: LatencyState = .off
    /// Milliseconds of each successful probe.
    public private(set) var latencyHistory = RingBuffer(capacity: 60)

    /// Bumped once per delivered snapshot.
    public private(set) var generation = 0

    private var observers: [Int: () -> Void] = [:]
    private var nextObserverID = 0

    public init() {}

    public func ingest(_ snapshot: Snapshot) {
        if let sample = snapshot.cpu {
            cpu = sample
            cpuUser.append(sample.user)
            cpuSystem.append(sample.system)
        }
        if let sample = snapshot.memory {
            memory = sample
            memoryApp.append(sample.fraction(sample.app))
            memoryWired.append(sample.fraction(sample.wired))
            memoryCompressed.append(sample.fraction(sample.compressed))
        }
        if let sample = snapshot.processes {
            processes = sample
        }
        if let sample = snapshot.gpu {
            gpu = sample
            gpuDevice.append(sample.device)
        }
        if let sample = snapshot.power {
            power = sample
            if let watts = sample.gpu { gpuPower.append(watts) }
            if let watts = sample.cpu { cpuPower.append(watts) }
        }
        if let sample = snapshot.cpuFrequency {
            cpuFrequency = sample
        }
        if let sample = snapshot.disk {
            disk = sample
            if let volumes = sample.volumes { diskVolumes = volumes }
            diskRead.append(Float(sample.readRate))
            diskWrite.append(Float(sample.writeRate))
        }
        if let health = snapshot.diskHealth {
            diskHealth = health
        }
        if let sample = snapshot.network {
            network = sample
            networkDown.append(Float(sample.down))
            networkUp.append(Float(sample.up))
        }
        if let sample = snapshot.networkInfo {
            networkInfo = sample
        }
        if let sample = snapshot.temperature {
            temperature = sample
            if let celsius = sample.headline { cpuTemperature.append(celsius) }
            if let celsius = sample.gpuHottest { gpuTemperature.append(celsius) }
        }
        if let sample = snapshot.sensors {
            sensors = sample
        }
        if let state = snapshot.path {
            path = state
        }
        if !snapshot.connectionEvents.isEmpty {
            connectionEvents.insert(contentsOf: snapshot.connectionEvents.reversed(), at: 0)
            if connectionEvents.count > Self.connectionEventLimit {
                connectionEvents.removeLast(connectionEvents.count - Self.connectionEventLimit)
            }
        }
        if let state = snapshot.publicIP {
            publicIP = state
        }
        if let state = snapshot.latency {
            latency = state
            if case .measured(let milliseconds, _) = state { latencyHistory.append(Float(milliseconds)) }
            if case .off = state { latencyHistory.removeAll() }
        }
        generation &+= 1
        for observer in observers.values { observer() }
    }

    /// Calls `handler` after every ingest until the token is cancelled or dropped.
    public func observe(_ handler: @escaping () -> Void) -> ObservationToken {
        let id = nextObserverID
        nextObserverID += 1
        observers[id] = handler
        return ObservationToken { [weak self] in self?.observers[id] = nil }
    }
}

/// Ends an observation when cancelled or deallocated.
@MainActor
public final class ObservationToken {
    private var cancellation: (() -> Void)?

    init(_ cancellation: @escaping () -> Void) { self.cancellation = cancellation }

    public func cancel() {
        cancellation?()
        cancellation = nil
    }

    isolated deinit { cancel() }
}
