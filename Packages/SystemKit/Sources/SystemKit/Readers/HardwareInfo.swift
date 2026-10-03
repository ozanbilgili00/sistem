/// Static facts about this Mac, read once.
public struct HardwareInfo: Sendable, Equatable {
    /// One class of CPU core. Names come from the hardware ("Super", "Performance",
    /// "Efficiency") — never assume which classes exist or in what order. An M5 Pro
    /// has Super + Performance and no efficiency cores at all.
    public struct CoreCluster: Sendable, Hashable {
        public let name: String
        public let count: Int
    }

    public let modelIdentifier: String
    public let chip: String
    public let memoryBytes: UInt64
    public let clusters: [CoreCluster]

    public var totalCores: Int { clusters.reduce(0) { $0 + $1.count } }

    public static func current() -> HardwareInfo {
        let levels = Int(Sysctl.integer("hw.nperflevels") ?? 0)
        let clusters = (0..<levels).compactMap { level -> CoreCluster? in
            guard let count = Sysctl.integer("hw.perflevel\(level).physicalcpu") else { return nil }
            let name = Sysctl.string("hw.perflevel\(level).name") ?? "Cluster \(level)"
            return CoreCluster(name: name, count: Int(count))
        }
        return HardwareInfo(
            modelIdentifier: Sysctl.string("hw.model") ?? "Mac",
            chip: Sysctl.string("machdep.cpu.brand_string") ?? "Apple Silicon",
            memoryBytes: UInt64(Sysctl.integer("hw.memsize") ?? 0),
            clusters: clusters
        )
    }
}
