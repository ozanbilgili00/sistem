/// Everything one tick read, handed from the sampler to the main actor. Value
/// types only — no IOKit handle ever leaves the sampler.
public struct Snapshot: Sendable {
    public var cpu: CPUSample?
    public var memory: MemorySample?
    public var processes: ProcessSample?
    public var gpu: GPUSample?
    public var power: PowerSample?
    public var cpuFrequency: CPUFrequencySample?
    public var disk: DiskSample?
    public var diskHealth: DiskHealth?
    public var network: NetworkSample?
    public var networkInfo: NetworkInfoSample?
    /// The few temperatures the menu bar shows; also derived from every full read.
    public var temperature: TemperatureSample?
    public var sensors: SensorSample?
    /// Connectivity, from `NWPathMonitor` events rather than a tick.
    public var path: PathState?
    public var connectionEvents: [ConnectionEvent] = []
    public var publicIP: PublicIPState?
    public var latency: LatencyState?

    public init(cpu: CPUSample? = nil, memory: MemorySample? = nil, processes: ProcessSample? = nil,
                gpu: GPUSample? = nil, power: PowerSample? = nil, cpuFrequency: CPUFrequencySample? = nil,
                disk: DiskSample? = nil, diskHealth: DiskHealth? = nil, network: NetworkSample? = nil, networkInfo: NetworkInfoSample? = nil,
                temperature: TemperatureSample? = nil, sensors: SensorSample? = nil,
                path: PathState? = nil, connectionEvents: [ConnectionEvent] = [],
                publicIP: PublicIPState? = nil, latency: LatencyState? = nil) {
        self.cpu = cpu
        self.memory = memory
        self.processes = processes
        self.gpu = gpu
        self.power = power
        self.cpuFrequency = cpuFrequency
        self.disk = disk
        self.diskHealth = diskHealth
        self.network = network
        self.networkInfo = networkInfo
        self.temperature = temperature
        self.sensors = sensors
        self.path = path
        self.connectionEvents = connectionEvents
        self.publicIP = publicIP
        self.latency = latency
    }
}

/// What the slow network read returns: Wi-Fi link quality and the Mac's addresses.
public struct NetworkInfoSample: Sendable, Equatable {
    /// nil on a Mac without Wi-Fi.
    public var wifi: WiFiSample?
    public var addresses: [LocalAddress]

    public init(wifi: WiFiSample?, addresses: [LocalAddress]) {
        self.wifi = wifi
        self.addresses = addresses
    }
}
