import Darwin
import Foundation

/// One row of a top-processes list.
public struct ProcessEntry: Sendable, Equatable, Identifiable {
    public var pid: pid_t
    public var name: String
    /// Share of one core, like Activity Monitor: 1.5 means 150 %.
    public var cpu: Float
    /// `phys_footprint` (Activity Monitor's Memory column) when readable,
    /// otherwise resident size from `ps` — see `memoryIsApproximate`.
    public var memory: UInt64
    public var memoryIsApproximate: Bool
    /// From the process energy counter; nil for processes we can't read.
    public var milliwatts: Float?

    public var id: pid_t { pid }

    public init(pid: pid_t, name: String, cpu: Float, memory: UInt64, memoryIsApproximate: Bool, milliwatts: Float?) {
        self.pid = pid
        self.name = name
        self.cpu = cpu
        self.memory = memory
        self.memoryIsApproximate = memoryIsApproximate
        self.milliwatts = milliwatts
    }
}

public struct ProcessSample: Sendable, Equatable {
    public var topCPU: [ProcessEntry]
    public var topMemory: [ProcessEntry]
    public var processCount: Int

    public init(topCPU: [ProcessEntry], topMemory: [ProcessEntry], processCount: Int) {
        self.topCPU = topCPU
        self.topMemory = topMemory
        self.processCount = processCount
    }
}

/// Lists processes and ranks them by CPU and memory.
///
/// Hybrid by necessity (PLAN.md §1-8): `proc_pid_rusage` is cheap and exact but
/// refuses root-owned processes (~200 here), so for those the setuid `ps` fills
/// in CPU time and resident size. `ps` costs ~20 ms of system time, so it runs on
/// every `psEvery`th sample only; root processes keep their last rate in between.
/// Only ever runs while a list is on screen — the sampler reads it on demand.
public struct ProcessLister {
    public var limit = 10
    public var psEvery = 2

    private struct Reading {
        var start: UInt64
        var cpuNanoseconds: UInt64
        var energy: UInt64?
    }

    private var previous: [pid_t: Reading] = [:]
    private var previousAt: ContinuousClock.Instant?
    private var names: [pid_t: (start: UInt64, name: String)] = [:]
    /// Last known state of processes only `ps` can see: CPU rate and memory.
    private var rootRates: [pid_t: (cpu: Float, memory: UInt64, name: String)] = [:]
    private var rootPrevious: [pid_t: UInt64] = [:]
    private var rootPreviousAt: ContinuousClock.Instant?
    private var round = 0
    private var pidBuffer = [pid_t](repeating: 0, count: 4096)

    public init() {}

    public mutating func reset() {
        previous.removeAll(keepingCapacity: true)
        rootPrevious.removeAll(keepingCapacity: true)
        rootRates.removeAll(keepingCapacity: true)
        previousAt = nil
        rootPreviousAt = nil
        round = 0
    }

    /// nil on the first call after init or `reset()`, which only primes.
    public mutating func sample() -> ProcessSample? {
        let now = ContinuousClock.now
        let pids = listPIDs()
        var current: [pid_t: Reading] = [:]
        current.reserveCapacity(pids.count)
        var entries: [ProcessEntry] = []
        entries.reserveCapacity(pids.count)
        var unreadable = Set<pid_t>()
        let elapsed = previousAt.map { $0.duration(to: now).seconds } ?? 0

        for pid in pids where pid > 0 {
            var info = rusage_info_v6()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            } == 0
            guard ok else { unreadable.insert(pid); continue }
            let reading = Reading(
                start: info.ri_proc_start_abstime,
                cpuNanoseconds: MachTime.nanoseconds(fromTicks: info.ri_user_time + info.ri_system_time),
                energy: info.ri_energy_nj
            )
            current[pid] = reading
            var cpu: Float = 0
            var milliwatts: Float?
            if elapsed > 0, let old = previous[pid], old.start == reading.start {
                cpu = Float(Double(reading.cpuNanoseconds &- min(old.cpuNanoseconds, reading.cpuNanoseconds)) / 1e9 / elapsed)
                if let e = reading.energy, let o = old.energy, e >= o {
                    milliwatts = Float(Double(e - o) / 1e6 / elapsed)
                }
            }
            entries.append(ProcessEntry(pid: pid, name: name(pid, start: reading.start), cpu: cpu,
                                        memory: info.ri_phys_footprint, memoryIsApproximate: false, milliwatts: milliwatts))
        }

        let primed = previousAt != nil
        previous = current
        previousAt = now
        names = names.filter { current[$0.key] != nil || unreadable.contains($0.key) }

        if round % psEvery == 0 { updateRootProcesses(unreadable, at: now) }
        round += 1
        rootRates = rootRates.filter { unreadable.contains($0.key) }
        for (pid, root) in rootRates {
            entries.append(ProcessEntry(pid: pid, name: root.name, cpu: root.cpu, memory: root.memory,
                                        memoryIsApproximate: true, milliwatts: nil))
        }

        guard primed else { return nil }
        let byCPU = entries.sorted { $0.cpu > $1.cpu }.prefix(limit)
        let byMemory = entries.sorted { $0.memory > $1.memory }.prefix(limit)
        return ProcessSample(topCPU: Array(byCPU), topMemory: Array(byMemory), processCount: pids.count)
    }

    private mutating func listPIDs() -> ArraySlice<pid_t> {
        while true {
            let bytes = Int32(pidBuffer.count * MemoryLayout<pid_t>.stride)
            let count = Int(proc_listallpids(&pidBuffer, bytes))
            if count < pidBuffer.count { return pidBuffer[..<max(0, count)] }
            pidBuffer = [pid_t](repeating: 0, count: pidBuffer.count * 2)
        }
    }

    /// Display name: the innermost `.app` bundle name if any ("Google Chrome
    /// Helper (Renderer)"), else the executable name. Cached per pid + start time.
    private mutating func name(_ pid: pid_t, start: UInt64) -> String {
        if let cached = names[pid], cached.start == start { return cached.name }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
        var name = ""
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            name = Self.displayName(fromPath: Self.string(path))
        }
        if name.isEmpty {
            var short = [CChar](repeating: 0, count: 64)
            if proc_name(pid, &short, UInt32(short.count)) > 0 { name = Self.string(short) }
        }
        if name.isEmpty { name = "\(pid)" }
        names[pid] = (start, name)
        return name
    }

    private static func string(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// An app's own executable (`X.app/Contents/MacOS/x`) is named after the
    /// bundle, as Activity Monitor does; anything else that merely lives inside a
    /// bundle (`Xcode.app/…/SWBBuildService`) keeps its executable name.
    static func displayName(fromPath path: String) -> String {
        let components = path.split(separator: "/")
        let n = components.count
        if n >= 4, components[n - 2] == "MacOS", components[n - 3] == "Contents", components[n - 4].hasSuffix(".app") {
            return String(components[n - 4].dropLast(4))
        }
        return components.last.map(String.init) ?? ""
    }

    // MARK: Root processes via ps

    private mutating func updateRootProcesses(_ pids: Set<pid_t>, at now: ContinuousClock.Instant) {
        guard !pids.isEmpty, let rows = Self.runPS() else { return }
        let elapsed = rootPreviousAt.map { $0.duration(to: now).seconds } ?? 0
        var times: [pid_t: UInt64] = [:]
        for row in rows where pids.contains(row.pid) {
            times[row.pid] = row.cpuNanoseconds
            var cpu: Float = 0
            if elapsed > 0, let old = rootPrevious[row.pid], row.cpuNanoseconds >= old {
                cpu = Float(Double(row.cpuNanoseconds - old) / 1e9 / elapsed)
            }
            rootRates[row.pid] = (cpu, row.residentBytes, Self.displayName(fromPath: row.command))
        }
        rootPrevious = times
        rootPreviousAt = now
    }

    struct PSRow: Equatable {
        var pid: pid_t
        var cpuNanoseconds: UInt64
        var residentBytes: UInt64
        var command: String
    }

    /// `/bin/ps` with a fixed argument array — no shell, nothing interpolated.
    private static func runPS() -> [PSRow]? {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/ps")
        process.arguments = ["-axo", "pid=,time=,rss=,comm="]
        process.environment = ["LC_ALL": "C"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return parsePS(String(decoding: data, as: UTF8.self))
    }

    /// Parses `pid time rss command` lines. `time` is `[[dd-]hh:]mm:ss.cc`.
    /// Malformed lines are skipped, never trusted.
    static func parsePS(_ output: String) -> [PSRow] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = pid_t(fields[0]), let rss = UInt64(fields[2]),
                  let time = parseCPUTime(fields[1]) else { return nil }
            return PSRow(pid: pid, cpuNanoseconds: time, residentBytes: rss * 1024, command: String(fields[3]))
        }
    }

    static func parseCPUTime(_ text: Substring) -> UInt64? {
        var days: UInt64 = 0
        var rest = text
        if let dash = rest.firstIndex(of: "-") {
            guard let d = UInt64(rest[..<dash]) else { return nil }
            days = d
            rest = rest[rest.index(after: dash)...]
        }
        let parts = rest.split(separator: ":")
        guard (2...3).contains(parts.count), let seconds = Double(parts.last!) else { return nil }
        var total = seconds
        var multiplier = 60.0
        for part in parts.dropLast().reversed() {
            guard let value = Double(part) else { return nil }
            total += value * multiplier
            multiplier *= 60
        }
        total += Double(days) * 86_400
        return UInt64(total * 1e9)
    }
}
