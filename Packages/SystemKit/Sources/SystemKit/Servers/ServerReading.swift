import Foundation

public struct CPUCounters: Equatable, Sendable {
    public var busy: UInt64
    public var total: UInt64
}

public struct NetCounters: Equatable, Sendable {
    public var received: UInt64
    public var sent: UInt64
}

public struct ContainerReading: Equatable, Sendable, Identifiable {
    public var name: String
    /// 0...n × 100 percent of one core, as Docker reports it.
    public var cpuPercent: Double?
    public var memoryUsed: UInt64?
    public var memoryLimit: UInt64?
    public init(name: String, cpuPercent: Double?, memoryUsed: UInt64?, memoryLimit: UInt64?) {
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryUsed = memoryUsed
        self.memoryLimit = memoryLimit
    }
    public var id: String { name }
}

/// One answer of a server, validated: every field is either absent or inside a plausible range.
public struct ServerReading: Equatable, Sendable {
    public var kind: ServerKind
    public var cores: Int?
    /// Linux: ticks since boot. The share of busy time comes from two readings.
    public var cpuCounters: CPUCounters?
    /// macOS: `top` already averages over a second.
    public var cpuFraction: Double?
    public var memoryTotal: UInt64?
    public var memoryUsed: UInt64?
    public var swapTotal: UInt64?
    public var swapUsed: UInt64?
    public var load: [Double]?
    public var uptime: TimeInterval?
    public var diskTotal: UInt64?
    public var diskUsed: UInt64?
    public var net: NetCounters?
    public var containers: [ContainerReading] = []

    public init(kind: ServerKind) { self.kind = kind }

    /// Nothing usable in it. A reading like this is "bad output", not an empty server.
    var isEmpty: Bool {
        cpuCounters == nil && cpuFraction == nil && memoryTotal == nil && load == nil && uptime == nil && diskTotal == nil
            && net == nil && containers.isEmpty
    }
}

/// What the interface shows: ratios and rates, computed from a reading and the one before it.
public struct ServerMetrics: Equatable, Sendable {
    public var cpu: Double?
    public var cores: Int?
    public var memoryUsed: UInt64?
    public var memoryTotal: UInt64?
    public var swapUsed: UInt64?
    public var swapTotal: UInt64?
    public var load: [Double]?
    public var uptime: TimeInterval?
    public var diskUsed: UInt64?
    public var diskTotal: UInt64?
    public var receiveRate: Double?
    public var sendRate: Double?
    public var containers: [ContainerReading]
    public var date: Date

    public init(cpu: Double? = nil, cores: Int? = nil, memoryUsed: UInt64? = nil, memoryTotal: UInt64? = nil, swapUsed: UInt64? = nil,
                swapTotal: UInt64? = nil, load: [Double]? = nil, uptime: TimeInterval? = nil, diskUsed: UInt64? = nil, diskTotal: UInt64? = nil,
                receiveRate: Double? = nil, sendRate: Double? = nil, containers: [ContainerReading] = [], date: Date) {
        self.cpu = cpu
        self.cores = cores
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
        self.load = load
        self.uptime = uptime
        self.diskUsed = diskUsed
        self.diskTotal = diskTotal
        self.receiveRate = receiveRate
        self.sendRate = sendRate
        self.containers = containers
        self.date = date
    }

    public var memoryFraction: Double? {
        guard let used = memoryUsed, let total = memoryTotal, total > 0 else { return nil }
        return min(1, Double(used) / Double(total))
    }

    public var diskFraction: Double? {
        guard let used = diskUsed, let total = diskTotal, total > 0 else { return nil }
        return min(1, Double(used) / Double(total))
    }

    /// `previous` is the reading before this one with its time. A counter that went backwards (reboot, wrap) gives no rate.
    public static func make(_ reading: ServerReading, at date: Date, previous: (reading: ServerReading, date: Date)?) -> ServerMetrics {
        var cpu = reading.cpuFraction
        var receive: Double?
        var send: Double?
        if let previous, date > previous.date {
            let seconds = date.timeIntervalSince(previous.date)
            if let now = reading.cpuCounters, let before = previous.reading.cpuCounters, now.total > before.total, now.busy >= before.busy {
                cpu = min(1, Double(now.busy - before.busy) / Double(now.total - before.total))
            }
            if let now = reading.net, let before = previous.reading.net {
                if now.received >= before.received { receive = Double(now.received - before.received) / seconds }
                if now.sent >= before.sent { send = Double(now.sent - before.sent) / seconds }
            }
        }
        return ServerMetrics(cpu: cpu, cores: reading.cores, memoryUsed: reading.memoryUsed, memoryTotal: reading.memoryTotal,
                             swapUsed: reading.swapUsed, swapTotal: reading.swapTotal, load: reading.load, uptime: reading.uptime,
                             diskUsed: reading.diskUsed, diskTotal: reading.diskTotal, receiveRate: receive, sendRate: send,
                             containers: reading.containers, date: date)
    }
}

/// Reads a server's answer. The text is untrusted: bounded in size and line length, every number checked,
/// unknown or broken lines skipped. nil = the answer is not one of ours (wrong header, no `END`, nothing usable).
public enum ServerReadingParser {
    public static let sizeLimit = 64 * 1024
    static let lineLimit = 512
    static let containerLimit = 100
    static let byteLimit: UInt64 = 1 << 50
    static let tickLimit: UInt64 = 1 << 62

    public static func parse(_ data: Data, expecting kind: ServerKind) -> ParseOutcome {
        guard data.count <= sizeLimit else { return .invalid }
        return parse(String(decoding: data, as: UTF8.self), expecting: kind)
    }

    public enum ParseOutcome: Equatable, Sendable {
        case reading(ServerReading)
        /// The remote side has no Docker.
        case toolMissing
        case invalid
    }

    static func parse(_ text: String, expecting kind: ServerKind) -> ParseOutcome {
        guard text.utf8.count <= sizeLimit else { return .invalid }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        let expectedHeader: String
        switch kind {
        case .linux: expectedHeader = "SISTEM1 linux"
        case .macOS: expectedHeader = "SISTEM1 macos"
        case .docker, .localDocker: expectedHeader = "SISTEM1 docker"
        }
        guard lines.first == expectedHeader, lines.last == ServerScripts.end else { return .invalid }
        var reading = ServerReading(kind: kind)
        var boot: Double?
        var now: Double?
        var seen = Set<String>()
        for line in lines.dropFirst().dropLast() {
            guard line.utf8.count <= lineLimit else { continue }
            if line == "NODOCKER" { return .toolMissing }
            if line == "DOCKERFAIL" { return .invalid }
            let isContainer = line.hasPrefix("ctr ")
            let fields = line.split(separator: " ", maxSplits: isContainer ? 1 : 9, omittingEmptySubsequences: true).map(String.init)
            guard let key = fields.first else { continue }
            // One line per key: a repeated key is dropped, never merged.
            if !isContainer, !seen.insert(key).inserted { continue }
            let values = fields.dropFirst()
            switch key {
            case "cpu" where kind == .linux:
                let ticks = values.compactMap { UInt64($0) }
                guard ticks.count >= 4, ticks.count == values.count, ticks.allSatisfy({ $0 < tickLimit }) else { continue }
                let (sum, overflow) = ticks.reduce((UInt64(0), false)) { acc, value in
                    let result = acc.0.addingReportingOverflow(value)
                    return (result.partialValue, acc.1 || result.overflow)
                }
                guard !overflow else { continue }
                let idle = ticks[3] + (ticks.count > 4 ? ticks[4] : 0)
                guard idle <= sum else { continue }
                reading.cpuCounters = CPUCounters(busy: sum - idle, total: sum)
            case "cores":
                if let value = values.first.flatMap({ Int($0) }), (1...4096).contains(value) { reading.cores = value }
            case "mem" where kind == .linux:
                let numbers = values.compactMap { UInt64($0) }
                guard numbers.count == 4, numbers.allSatisfy({ $0 < byteLimit / 1024 }) else { continue }
                let (total, available, swapTotal, swapFree) = (numbers[0] * 1024, numbers[1] * 1024, numbers[2] * 1024, numbers[3] * 1024)
                if total > 0, available <= total {
                    reading.memoryTotal = total
                    reading.memoryUsed = total - available
                }
                if swapTotal > 0, swapFree <= swapTotal {
                    reading.swapTotal = swapTotal
                    reading.swapUsed = swapTotal - swapFree
                }
            case "memsize" where kind == .macOS:
                if let total = values.first.flatMap({ UInt64($0) }), total > 0, total < byteLimit { reading.memoryTotal = total }
            case "vm" where kind == .macOS:
                let pages = values.compactMap { UInt64($0) }
                guard pages.count == 7, pages.allSatisfy({ $0 < byteLimit }), (4_096...65_536).contains(pages[0]) else { continue }
                // Used = active + wired + compressed: what cannot be handed back without paging, like Activity Monitor's "used".
                let used = (pages[2] &+ pages[5] &+ pages[6]) &* pages[0]
                if used < byteLimit { reading.memoryUsed = used }
            case "load":
                let numbers = values.compactMap { Double($0) }
                guard numbers.count == 3, numbers.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < 100_000 }) else { continue }
                reading.load = numbers
            case "up" where kind == .linux:
                if let seconds = values.first.flatMap({ Double($0) }), seconds.isFinite, seconds >= 0, seconds < 3.2e9 { reading.uptime = seconds }
            case "boot" where kind == .macOS:
                boot = values.first.flatMap { Double($0) }
            case "now" where kind == .macOS:
                now = values.first.flatMap { Double($0) }
            case "cpupct" where kind == .macOS:
                let numbers = values.compactMap { Double($0) }
                guard numbers.count == 3, numbers.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 100.5 }) else { continue }
                reading.cpuFraction = min(1, max(0, 1 - numbers[2] / 100))
            case "net":
                let numbers = values.compactMap { UInt64($0) }
                guard numbers.count == 2, numbers.allSatisfy({ $0 < tickLimit }) else { continue }
                reading.net = NetCounters(received: numbers[0], sent: numbers[1])
            case "disk":
                let numbers = values.compactMap { UInt64($0) }
                guard numbers.count == 2, numbers.allSatisfy({ $0 < byteLimit / 1024 }), numbers[0] > 0, numbers[1] <= numbers[0] else { continue }
                reading.diskTotal = numbers[0] * 1024
                reading.diskUsed = numbers[1] * 1024
            case "ctr":
                guard reading.containers.count < containerLimit, let container = parseContainer(values.first ?? "") else { continue }
                reading.containers.append(container)
            default:
                continue
            }
        }
        if let boot, let now, now >= boot, now - boot < 3.2e9 { reading.uptime = now - boot }
        return reading.isEmpty && kind != .docker && kind != .localDocker ? .invalid : .reading(reading)
    }

    /// `name|12.34%|50.1MiB / 1.9GiB`.
    static func parseContainer(_ text: String) -> ContainerReading? {
        let parts = text.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, isContainerName(parts[0]) else { return nil }
        var cpu: Double?
        if parts[1].hasSuffix("%"), let value = Double(parts[1].dropLast()), value.isFinite, value >= 0, value < 100_000 { cpu = value }
        var used: UInt64?
        var limit: UInt64?
        let memory = parts[2].components(separatedBy: " / ")
        if memory.count == 2 {
            used = byteCount(memory[0])
            limit = byteCount(memory[1])
        }
        return ContainerReading(name: parts[0], cpuPercent: cpu, memoryUsed: used, memoryLimit: limit)
    }

    /// Docker's own rule for container names, plus a length limit.
    static func isContainerName(_ name: String) -> Bool {
        guard (1...64).contains(name.utf8.count), let first = name.first, first.isASCII, first.isLetter || first.isNumber else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }
    }

    /// "50.1MiB", "1.9GiB", "512kB", "0B".
    static func byteCount(_ text: String) -> UInt64? {
        let units: [(String, Double)] = [("TiB", 1_099_511_627_776), ("GiB", 1_073_741_824), ("MiB", 1_048_576), ("KiB", 1_024),
                                         ("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        for (suffix, factor) in units where trimmed.hasSuffix(suffix) {
            guard let value = Double(trimmed.dropLast(suffix.count)), value.isFinite, value >= 0 else { return nil }
            let bytes = value * factor
            return bytes < Double(byteLimit) ? UInt64(bytes) : nil
        }
        return nil
    }
}
