import Darwin

/// CPU load over one sampling interval. Fractions are of total capacity, 0...1.
public struct CPUSample: Sendable, Equatable {
    public var user: Float
    public var system: Float
    /// Per logical CPU, in logical-id order (see `HardwareInfo.clusters`).
    public var cores: [Float]
    public var loadAverage: LoadAverage

    public var total: Float { user + system }
    public var idle: Float { max(0, 1 - total) }

    public init(user: Float, system: Float, cores: [Float], loadAverage: LoadAverage) {
        self.user = user
        self.system = system
        self.cores = cores
        self.loadAverage = loadAverage
    }
}

public struct LoadAverage: Sendable, Equatable {
    public var one: Double
    public var five: Double
    public var fifteen: Double

    public init(one: Double, five: Double, fifteen: Double) {
        self.one = one
        self.five = five
        self.fifteen = fifteen
    }

    public static func current() -> LoadAverage {
        var values = [Double](repeating: 0, count: 3)
        guard getloadavg(&values, 3) == 3 else { return LoadAverage(one: 0, five: 0, fifteen: 0) }
        return LoadAverage(one: values[0], five: values[1], fifteen: values[2])
    }
}

/// Reads per-CPU tick counters from `host_processor_info` and turns two readings
/// into a ``CPUSample``. The same counters Activity Monitor uses.
///
/// Two leaks to avoid here, both easy to miss: the kernel hands back the counter
/// array in freshly `vm_allocate`d memory that must be `vm_deallocate`d, and every
/// `mach_host_self()` call takes a new port reference — so the port is cached.
public struct CPULoadReader {
    private let host = mach_host_self()
    /// Previous reading, flattened `[cpu * CPU_STATE_MAX + state]`; empty until primed.
    private var previous: [UInt32] = []

    public init() {}

    /// Forget the previous reading; the next `sample()` only primes. Call after a
    /// pause so a long sleep isn't averaged into one sample.
    public mutating func reset() { previous.removeAll(keepingCapacity: true) }

    /// nil on the first call after init or `reset()`, which only primes.
    public mutating func sample() -> CPUSample? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let states = Int(CPU_STATE_MAX)
        let count = Int(cpuCount) * states
        let current = UnsafeRawPointer(info).bindMemory(to: UInt32.self, capacity: count)
        defer {
            if previous.count != count { previous = [UInt32](repeating: 0, count: count) }
            for i in 0..<count { previous[i] = current[i] }
        }
        guard previous.count == count else { return nil }

        var cores = [Float]()
        cores.reserveCapacity(Int(cpuCount))
        var user: UInt64 = 0, system: UInt64 = 0, total: UInt64 = 0
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * states
            // Counters are 32-bit and wrap; wrapping subtraction keeps deltas right.
            func delta(_ state: Int32) -> UInt64 {
                UInt64(current[base + Int(state)] &- previous[base + Int(state)])
            }
            let u = delta(CPU_STATE_USER) + delta(CPU_STATE_NICE)
            let s = delta(CPU_STATE_SYSTEM)
            let all = u + s + delta(CPU_STATE_IDLE)
            cores.append(all == 0 ? 0 : Float(u + s) / Float(all))
            user += u
            system += s
            total += all
        }
        guard total > 0 else { return nil }
        return CPUSample(
            user: Float(user) / Float(total),
            system: Float(system) / Float(total),
            cores: cores,
            loadAverage: .current()
        )
    }
}
