import Darwin
import Testing
@testable import SystemKit

@Test func hardwareClustersAddUpToPhysicalCPU() {
    let info = HardwareInfo.current()
    #expect(!info.modelIdentifier.isEmpty)
    #expect(info.memoryBytes > 0)
    #expect(!info.clusters.isEmpty)
    #expect(Int64(info.totalCores) == Sysctl.integer("hw.physicalcpu"))
}

@Test func readsOwnProcessUsage() throws {
    let usage = try #require(ProcessUsage.current())
    #expect(usage.physFootprint > 0)
}

/// Guards the Mach-tick conversion by checking against an independent clock, the
/// kernel's process CPU clock. Without the timebase conversion the rusage figure
/// comes out ~42x too small on Apple Silicon.
@Test func cpuTimeMatchesProcessClock() throws {
    func processClock() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }
    let clockBefore = processClock()
    let before = try #require(ProcessUsage.current())
    var spin: UInt64 = 0
    while processClock() - clockBefore < 0.3 { spin &+= 1 }
    let after = try #require(ProcessUsage.current())
    let clockSpent = processClock() - clockBefore

    let measured = (after.cpuTime - before.cpuTime).seconds
    #expect(abs(measured - clockSpent) / clockSpent < 0.1, "rusage \(measured) sn, saat \(clockSpent) sn")
    #expect(spin > 0)
}

@Test func rootProcessesAreUnreadableWithoutPrivileges() {
    // launchd (pid 1) is root-owned: this is why the process list needs `ps` as well.
    #expect(ProcessUsage.read(pid: 1) == nil)
}
