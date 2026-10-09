import Darwin

/// One `proc_pid_rusage` reading. Two readings make a ``UsageRate``.
///
/// Works for any process owned by the same user without privileges; root-owned
/// processes return nil (EPERM).
public struct ProcessUsage: Sendable {
    public let cpuTime: Duration
    /// What Activity Monitor shows in its Memory column.
    public let physFootprint: UInt64
    /// Package-idle plus interrupt wakeups since the process started.
    public let wakeups: UInt64
    public let energyNanojoules: UInt64
    /// CPU time of child processes that have exited and been reaped (`system_profiler`, `ps`).
    /// Stays put while the app spawns nothing, which is how the "no subprocess" gates are shown.
    public let childCPUTime: Duration
    public let sampledAt: ContinuousClock.Instant

    public static func read(pid: pid_t) -> ProcessUsage? {
        var info = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        guard status == 0 else { return nil }
        // CPU times arrive in Mach absolute-time ticks, not nanoseconds; on Apple
        // Silicon one tick is 125/3 ns, so skipping this undercounts CPU ~40x.
        let ticks = info.ri_user_time + info.ri_system_time
        return ProcessUsage(
            cpuTime: .nanoseconds(Int64(MachTime.nanoseconds(fromTicks: ticks))),
            physFootprint: info.ri_phys_footprint,
            wakeups: info.ri_pkg_idle_wkups + info.ri_interrupt_wkups,
            energyNanojoules: info.ri_energy_nj,
            childCPUTime: .nanoseconds(Int64(MachTime.nanoseconds(fromTicks: info.ri_child_user_time + info.ri_child_system_time))),
            sampledAt: .now
        )
    }

    public static func current() -> ProcessUsage? { read(pid: getpid()) }

    public func rate(since earlier: ProcessUsage) -> UsageRate {
        let elapsed = earlier.sampledAt.duration(to: sampledAt).seconds
        guard elapsed > 0 else { return UsageRate(cpuPercent: 0, wakeupsPerSecond: 0, milliwatts: 0, footprintMB: footprintMB, childCPUMilliseconds: 0) }
        let cpu = (cpuTime - earlier.cpuTime).seconds
        return UsageRate(
            cpuPercent: cpu / elapsed * 100,
            wakeupsPerSecond: Double(wakeups &- earlier.wakeups) / elapsed,
            milliwatts: Double(energyNanojoules &- earlier.energyNanojoules) / elapsed / 1_000_000,
            footprintMB: footprintMB,
            childCPUMilliseconds: (childCPUTime - earlier.childCPUTime).seconds * 1000
        )
    }

    public var footprintMB: Double { Double(physFootprint) / 1_048_576 }
}

/// Resource use between two readings. CPU is a share of one core.
public struct UsageRate: Sendable, Equatable {
    public let cpuPercent: Double
    public let wakeupsPerSecond: Double
    public let milliwatts: Double
    public let footprintMB: Double
    /// CPU spent by child processes that finished in the window; 0 means none ran.
    public let childCPUMilliseconds: Double
}

enum MachTime {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func nanoseconds(fromTicks ticks: UInt64) -> UInt64 {
        ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
    }
}

extension Duration {
    var seconds: Double {
        let (s, attoseconds) = components
        return Double(s) + Double(attoseconds) / 1e18
    }
}
