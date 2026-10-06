/// Static facts about this Mac, read once.
public struct HardwareInfo: Sendable, Equatable {
    /// One class of CPU core. Names come from the hardware ("Super", "Performance",
    /// "Efficiency") — never assume which classes exist or in what order. An M5 Pro
    /// has Super + Performance and no efficiency cores at all.
    public struct CoreCluster: Sendable, Hashable {
        public let name: String
        public let count: Int
        /// Which logical CPU ids (indices into `CPUSample.cores`) belong here.
        public let logicalCPUs: Range<Int>
    }

    public let modelIdentifier: String
    public let chip: String
    public let memoryBytes: UInt64
    /// Fastest class first (perflevel 0).
    public let clusters: [CoreCluster]

    public var totalCores: Int { clusters.reduce(0) { $0 + $1.count } }

    public static func current() -> HardwareInfo {
        let levels = Int(Sysctl.integer("hw.nperflevels") ?? 0)
        let raw: [(name: String, physical: Int, logical: Int)] = (0..<levels).compactMap { level in
            guard let physical = Sysctl.integer("hw.perflevel\(level).physicalcpu") else { return nil }
            let logical = Sysctl.integer("hw.perflevel\(level).logicalcpu") ?? physical
            let name = Sysctl.string("hw.perflevel\(level).name") ?? "Cluster \(level)"
            return (name, Int(physical), Int(logical))
        }
        // Logical CPU ids run from the slowest class up: on an M1 cpu0-3 are
        // Efficiency, on an M5 Pro cpu0-11 are Performance and cpu12-17 Super
        // (checked against IODeviceTree `cluster-type`). So assign id ranges
        // walking the perflevels backwards.
        var next = 0
        var ranges = [Range<Int>](repeating: 0..<0, count: raw.count)
        for index in raw.indices.reversed() {
            ranges[index] = next..<(next + raw[index].logical)
            next += raw[index].logical
        }
        return HardwareInfo(
            modelIdentifier: Sysctl.string("hw.model") ?? "Mac",
            chip: Sysctl.string("machdep.cpu.brand_string") ?? "Apple Silicon",
            memoryBytes: UInt64(Sysctl.integer("hw.memsize") ?? 0),
            clusters: raw.indices.map { CoreCluster(name: raw[$0].name, count: raw[$0].physical, logicalCPUs: ranges[$0]) }
        )
    }
}
