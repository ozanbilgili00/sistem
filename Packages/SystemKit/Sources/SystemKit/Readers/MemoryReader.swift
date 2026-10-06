import Darwin

/// System memory, split the way Activity Monitor splits it. Bytes throughout.
public struct MemorySample: Sendable, Equatable {
    public enum Pressure: Int, Sendable { case normal = 1, warning = 2, critical = 4 }

    public var total: UInt64
    /// Anonymous memory apps hold, minus what they marked purgeable.
    public var app: UInt64
    public var wired: UInt64
    /// Physical memory the compressor occupies (not the larger uncompressed size).
    public var compressed: UInt64
    /// File-backed plus purgeable: reclaimable on demand.
    public var cached: UInt64
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public var pressure: Pressure

    public var used: UInt64 { app + wired + compressed }
    public var free: UInt64 { total > used + cached ? total - used - cached : 0 }

    public func fraction(_ bytes: UInt64) -> Float { total == 0 ? 0 : Float(Double(bytes) / Double(total)) }
    public var usedFraction: Float { fraction(used) }

    public init(total: UInt64, app: UInt64, wired: UInt64, compressed: UInt64, cached: UInt64,
                swapUsed: UInt64, swapTotal: UInt64, pressure: Pressure) {
        self.total = total
        self.app = app
        self.wired = wired
        self.compressed = compressed
        self.cached = cached
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
        self.pressure = pressure
    }
}

/// Reads `host_statistics64(HOST_VM_INFO64)`, `vm.swapusage` and the kernel's
/// pressure level. Stateless apart from cached constants; about 10 µs a read.
///
/// The split (PLAN.md §1-9) matches Activity Monitor: App = internal − purgeable,
/// Wired = wire, Compressed = compressor pages, Cached = external + purgeable.
/// Wired and Compressed checked against `top` PhysMem on 2026-10-04.
public struct MemoryReader {
    private let host = mach_host_self()
    private let pageSize = UInt64(Sysctl.integer("hw.pagesize") ?? 16_384)
    private let total = UInt64(Sysctl.integer("hw.memsize") ?? 0)

    public init() {}

    public func sample() -> MemorySample? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let anonymous = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let swap = Self.swapUsage()
        return MemorySample(
            total: total,
            app: (anonymous > purgeable ? anonymous - purgeable : 0) * pageSize,
            wired: UInt64(stats.wire_count) * pageSize,
            compressed: UInt64(stats.compressor_page_count) * pageSize,
            cached: (UInt64(stats.external_page_count) + purgeable) * pageSize,
            swapUsed: swap.used,
            swapTotal: swap.total,
            pressure: MemorySample.Pressure(rawValue: Int(Sysctl.integer("kern.memorystatus_vm_pressure_level") ?? 1)) ?? .normal
        )
    }

    private static func swapUsage() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }
}
