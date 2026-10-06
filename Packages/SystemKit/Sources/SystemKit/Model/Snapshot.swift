/// Everything one tick read, handed from the sampler to the main actor. Value
/// types only — no IOKit handle ever leaves the sampler.
public struct Snapshot: Sendable {
    public var cpu: CPUSample?
    public var memory: MemorySample?
    public var processes: ProcessSample?

    public init(cpu: CPUSample? = nil, memory: MemorySample? = nil, processes: ProcessSample? = nil) {
        self.cpu = cpu
        self.memory = memory
        self.processes = processes
    }
}
