/// Everything one tick read, handed from the sampler to the main actor. Value
/// types only — no IOKit handle ever leaves the sampler.
public struct Snapshot: Sendable {
    public var cpu: CPUSample?
    public var memory: MemorySample?
    public var processes: ProcessSample?
    public var gpu: GPUSample?
    public var power: PowerSample?
    public var cpuFrequency: CPUFrequencySample?

    public init(cpu: CPUSample? = nil, memory: MemorySample? = nil, processes: ProcessSample? = nil,
                gpu: GPUSample? = nil, power: PowerSample? = nil, cpuFrequency: CPUFrequencySample? = nil) {
        self.cpu = cpu
        self.memory = memory
        self.processes = processes
        self.gpu = gpu
        self.power = power
        self.cpuFrequency = cpuFrequency
    }
}
