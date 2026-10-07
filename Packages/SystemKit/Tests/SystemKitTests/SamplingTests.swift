import AppKit
import Darwin
import Synchronization
import Foundation
import Testing
@testable import SystemKit

@Test func ringBufferKeepsNewestInOrder() {
    var buffer = RingBuffer(capacity: 4)
    #expect(buffer.isEmpty && buffer.last == nil)
    for value in 1...6 { buffer.append(Float(value)) }
    #expect(buffer.count == 4)
    #expect(buffer.values() == [3, 4, 5, 6])
    #expect(buffer[0] == 3 && buffer.last == 6)
    buffer.removeAll()
    #expect(buffer.values().isEmpty)
    buffer.append(9)
    #expect(buffer.values() == [9])
}

@Test func ringBufferDoesNotReallocateOnAppend() {
    var buffer = RingBuffer(capacity: 300)
    let before = withUnsafeBytes(of: buffer) { Array($0) }
    for value in 0..<10_000 { buffer.append(Float(value)) }
    // Same storage reference: the struct's bytes (pointer, head, count aside) unchanged
    // means no new array was allocated.
    let after = withUnsafeBytes(of: buffer) { Array($0) }
    #expect(before.prefix(16) == after.prefix(16))
    #expect(buffer.last == 9_999)
}

@Test func clustersCoverEveryLogicalCPU() {
    let info = HardwareInfo.current()
    let ranges = info.clusters.map(\.logicalCPUs).sorted { $0.lowerBound < $1.lowerBound }
    var next = 0
    for range in ranges {
        #expect(range.lowerBound == next)
        next = range.upperBound
    }
    #expect(Int64(next) == Sysctl.integer("hw.logicalcpu"))
    // The fastest class sits at the top of the id space.
    #expect(info.clusters.first?.logicalCPUs.upperBound == next)
}

@Test func cpuReaderPrimesThenSamples() throws {
    var reader = CPULoadReader()
    #expect(reader.sample() == nil)
    usleep(200_000)
    let maybe = reader.sample()
    let sample = try #require(maybe)
    #expect(Int64(sample.cores.count) == Sysctl.integer("hw.logicalcpu"))
    #expect((0...1).contains(sample.total))
    #expect(sample.cores.allSatisfy { (0...1).contains($0) })
    #expect(sample.loadAverage.one >= 0)
    reader.reset()
    #expect(reader.sample() == nil)
}

/// `host_processor_info` hands back vm_allocate'd memory and `mach_host_self` takes
/// a port reference per call; forgetting either grows the footprint steadily.
@Test func cpuReaderDoesNotLeak() throws {
    var reader = CPULoadReader()
    for _ in 0..<500 { _ = reader.sample() }
    let refsBefore = hostPortSendRefs()
    // A missed vm_deallocate costs at least a 16 KB page per call (~160 MB here);
    // the margin and the retry only absorb tests running in parallel in this process.
    _ = try footprintStaysFlat(margin: 8 * 1024 * 1024) {
        for _ in 0..<10_000 { _ = reader.sample() }
    }
    // mach_host_self() per read would add one send right per call.
    #expect(hostPortSendRefs() < refsBefore + 100)
}

private func hostPortSendRefs() -> Int {
    let host = mach_host_self()  // itself adds one reference
    var refs: mach_port_urefs_t = 0
    mach_port_get_refs(mach_task_self_, host, MACH_PORT_RIGHT_SEND, &refs)
    mach_port_deallocate(mach_task_self_, host)
    return Int(refs)
}

@Test func samplerDeliversOnlyWhenWanted() async throws {
    let received = Mutex(0)
    let sampler = SamplerActor { snapshot in
        if snapshot.cpu != nil { received.withLock { $0 += 1 } }
    }
    sampler.send(SamplerConfig(interval: 0.1, metrics: [.cpu], paused: false))
    try await Task.sleep(for: .milliseconds(450))
    #expect(received.withLock { $0 } >= 2)

    sampler.send(SamplerConfig(interval: 0.1, metrics: [.cpu], paused: true))
    try await Task.sleep(for: .milliseconds(100))
    let paused = received.withLock { $0 }
    try await Task.sleep(for: .milliseconds(400))
    #expect(received.withLock { $0 } == paused)

    sampler.send(SamplerConfig(interval: 0.1, metrics: [], paused: false))
    try await Task.sleep(for: .milliseconds(300))
    #expect(received.withLock { $0 } == paused)
}

@MainActor @Test func demandCountsConsumers() {
    let registry = DemandRegistry()
    var changes = 0
    registry.onChange = { changes += 1 }
    registry.retain(.cpu)
    registry.retain(.cpu)
    registry.release(.cpu)
    #expect(registry.active == [.cpu])
    registry.release(.cpu)
    #expect(registry.active.isEmpty)
    #expect(changes == 2)
}

/// Notifications are posted to this test process's own centers only — nothing
/// system-wide is faked.
@MainActor @Test func engineStopsWhileNobodyCanSee() {
    let engine = SamplingEngine()
    engine.demand.retain(.cpu)
    #expect(engine.config.metrics == [.cpu] && !engine.config.paused)

    let workspace = NSWorkspace.shared.notificationCenter
    workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
    #expect(engine.config.paused && engine.config.isIdle)
    workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
    workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
    #expect(engine.config.paused, "still asleep")
    workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
    #expect(!engine.config.paused)

    workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
    #expect(engine.pauses.reasons == [.sessionInactive])
    workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    #expect(!engine.config.paused)

    engine.demand.release(.cpu)
    #expect(engine.config.isIdle && !engine.config.paused)
}

@MainActor @Test func powerPolicyStretchesInterval() {
    let engine = SamplingEngine()
    engine.baseInterval = 3
    let factor = engine.power.multiplier(slowDownOnBattery: true)
    #expect(engine.config.interval == 3 * factor)
    engine.slowDownOnBattery = false
    #expect(engine.config.interval == 3 * engine.power.multiplier(slowDownOnBattery: false))
}
