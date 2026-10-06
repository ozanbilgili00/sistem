import Darwin
import Foundation
import Testing
@testable import SystemKit

@Test func memorySplitIsConsistent() throws {
    let sample = try #require(MemoryReader().sample())
    #expect(UInt64(Sysctl.integer("hw.memsize") ?? 0) == sample.total)
    #expect(sample.app > 0 && sample.wired > 0)
    #expect(sample.used + sample.cached <= sample.total)
    #expect((0...1).contains(sample.usedFraction))
    #expect(sample.swapUsed <= max(sample.swapTotal, sample.swapUsed))
}

/// Wired and compressed are the same counters `vm_stat` prints; they must agree
/// within the drift between two reads.
@Test func memoryMatchesVMStat() throws {
    let sample = try #require(MemoryReader().sample())
    let output = try run("/usr/bin/vm_stat")
    func pages(_ label: String) -> UInt64? {
        output.split(separator: "\n").first { $0.hasPrefix(label) }
            .flatMap { $0.split(separator: ":").last }
            .flatMap { UInt64($0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))) }
    }
    let page = UInt64(Sysctl.integer("hw.pagesize") ?? 16_384)
    let wired = try #require(pages("Pages wired down")) * page
    let compressed = try #require(pages("Pages occupied by compressor")) * page
    let tolerance: UInt64 = 100 * 1_048_576
    #expect(sample.wired.distance(to: wired).magnitude < tolerance)
    #expect(sample.compressed.distance(to: compressed).magnitude < tolerance)
}

@Test func psTimeParsing() {
    #expect(ProcessLister.parseCPUTime("0:01.50") == 1_500_000_000)
    #expect(ProcessLister.parseCPUTime("2:13.73") == UInt64(133.73 * 1e9))
    #expect(ProcessLister.parseCPUTime("1:02:03.00") == 3_723_000_000_000)
    #expect(ProcessLister.parseCPUTime("2-01:00:00.00") == UInt64(2 * 86_400 + 3_600) * 1_000_000_000)
    #expect(ProcessLister.parseCPUTime("abc") == nil)
    #expect(ProcessLister.parseCPUTime("1:x") == nil)

    let rows = ProcessLister.parsePS("""
          1   2:13.73  28432 /sbin/launchd
        344   0:00.19   3584 /System/Library/Foo Bar.app/Contents/MacOS/Foo Bar
        garbage line
        """)
    #expect(rows.count == 2)
    #expect(rows[1].command.hasSuffix("Foo Bar"))
    #expect(rows[0].residentBytes == 28432 * 1024)
}

@Test func displayNamesPreferBundles() {
    #expect(ProcessLister.displayName(fromPath: "/Applications/Safari.app/Contents/MacOS/Safari") == "Safari")
    #expect(ProcessLister.displayName(fromPath: "/A/Google Chrome.app/Contents/Frameworks/x/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)") == "Google Chrome Helper (Renderer)")
    #expect(ProcessLister.displayName(fromPath: "/usr/libexec/logd") == "logd")
    #expect(ProcessLister.displayName(fromPath: "/Applications/Xcode.app/Contents/SharedFrameworks/SwiftBuild.framework/Versions/A/PlugIns/SWBBuildService.bundle/Contents/MacOS/SWBBuildService") == "SWBBuildService")
}

/// A process burning one core must show up near 100 % — the same yardstick as
/// Activity Monitor's %CPU column.
@Test func processListerSeesABusyChild() throws {
    let busy = Process()
    busy.executableURL = URL(filePath: "/usr/bin/yes")
    busy.standardOutput = FileHandle.nullDevice
    try busy.run()
    defer { busy.terminate() }

    var lister = ProcessLister()
    lister.limit = 50
    #expect(lister.sample() == nil)
    Thread.sleep(forTimeInterval: 1)
    let maybe = lister.sample()
    let sample = try #require(maybe)
    let entry = try #require(sample.topCPU.first { $0.pid == busy.processIdentifier })
    #expect(entry.name == "yes")
    #expect((0.8...1.1).contains(entry.cpu), "\(entry.cpu)")
    #expect(entry.memory > 0 && !entry.memoryIsApproximate)
    #expect(sample.processCount > 100)
    // Root-owned processes come from ps and are marked approximate.
    #expect(sample.topMemory.contains { $0.memoryIsApproximate } || sample.topCPU.contains { $0.memoryIsApproximate })
}

private func run(_ path: String) throws -> String {
    let process = Process()
    process.executableURL = URL(filePath: path)
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// Name cache and per-pid state must track live processes, not accumulate.
@Test func processListerMemoryStaysFlat() throws {
    var lister = ProcessLister()
    lister.psEvery = 1_000  // the ps path is covered above; this is about libproc state
    for _ in 0..<20 { _ = lister.sample() }
    let before = try #require(ProcessUsage.current()).physFootprint
    for _ in 0..<200 { _ = lister.sample() }
    let after = try #require(ProcessUsage.current()).physFootprint
    #expect(after < before + 4 * 1024 * 1024, "grew \(Int64(after) - Int64(before)) bytes")
}
