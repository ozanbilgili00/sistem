import Darwin
import Foundation
import Synchronization
import Testing
@testable import SystemKit

// MARK: GPU

@Test func gpuReaderReportsPlausibleValues() throws {
    let reader = try #require(GPUReader())
    let sample = try #require(reader.sample())
    for fraction in [sample.device, sample.renderer, sample.tiler] {
        #expect((0...1).contains(fraction))
    }
    #expect(sample.memoryInUse > 0)
    #expect(sample.memoryAllocated > 0)
    // Memory is system RAM shared with the CPU: it can't exceed it.
    #expect(sample.memoryInUse < UInt64(Sysctl.integer("hw.memsize") ?? 0))
}

@Test func gpuStatisticsParsing() {
    let sample = GPUReader.parse([
        "Device Utilization %": 24, "Renderer Utilization %": 23, "Tiler Utilization %": 13,
        "In use system memory": 773_439_488, "Alloc system memory": 2_565_505_024,
    ] as CFDictionary)
    #expect(sample == GPUSample(device: 0.24, renderer: 0.23, tiler: 0.13,
                                memoryInUse: 773_439_488, memoryAllocated: 2_565_505_024))
    // Out-of-range driver values are clamped, missing optional keys degrade.
    let odd = GPUReader.parse(["Device Utilization %": 130] as CFDictionary)
    #expect(odd?.device == 1 && odd?.renderer == 1 && odd?.tiler == 0 && odd?.memoryInUse == 0)
    // Without the headline number there is no sample at all.
    #expect(GPUReader.parse(["Tiler Utilization %": 5] as CFDictionary) == nil)
    #expect(GPUReader.parse([:] as CFDictionary) == nil)
}

/// Every read returns a new dictionary the reader must release; a missing
/// `takeRetainedValue` costs a few hundred bytes a call.
@Test func gpuReaderDoesNotLeak() throws {
    let reader = try #require(GPUReader())
    for _ in 0..<500 { _ = reader.sample() }
    // 20 000 reads: a leaked dictionary per read is ~600 B each, 12 MB in all.
    _ = try footprintStaysFlat(margin: 3 * 1024 * 1024) {
        for _ in 0..<20_000 { _ = reader.sample() }
    }
}

// MARK: Power

@Test func energyUnitsConvertToWatts() {
    func close(_ value: Double?, to expected: Double) -> Bool { value.map { abs($0 - expected) < 1e-9 } ?? false }
    #expect(close(PowerReader.watts(energy: 29_000_000_000, unit: "nJ", seconds: 1), to: 29))
    #expect(close(PowerReader.watts(energy: 29_000_000, unit: "uJ", seconds: 1), to: 29))
    #expect(close(PowerReader.watts(energy: 14_500, unit: "mJ", seconds: 0.5), to: 29))
    #expect(PowerReader.watts(energy: 5, unit: "kWh", seconds: 1) == nil)
    #expect(PowerReader.watts(energy: -1, unit: "nJ", seconds: 1) == nil)
    #expect(PowerReader.watts(energy: 1, unit: "nJ", seconds: 0) == nil)
}

@Test func powerReaderReportsPlausibleWatts() throws {
    let reader = PowerReader()
    #expect(reader.isAvailable)
    let first = reader.sample()
    // The first sample only primes the energy counters; the SMC half is instant.
    #expect(first.gpu == nil && first.ane == nil)
    #expect(first.cpu != nil && first.system != nil)
    Thread.sleep(forTimeInterval: 0.5)
    let second = reader.sample()
    let cpu = try #require(second.cpu)
    let system = try #require(second.system)
    let gpu = try #require(second.gpu)
    #expect((0..<300).contains(cpu), "cpu \(cpu)")
    #expect((0..<400).contains(system), "sistem \(system)")
    #expect((0..<200).contains(gpu), "gpu \(gpu)")
    #expect((second.ane ?? 0) >= 0 && (second.ane ?? 0) < 50)
    reader.reset()
    #expect(reader.sample().gpu == nil)
}

@Test func powerReaderDegradesWithoutIOReport() throws {
    let smcOnly = PowerReader(library: nil, smc: SMC())
    #expect(smcOnly.isAvailable)
    _ = smcOnly.sample()
    Thread.sleep(forTimeInterval: 0.1)
    let sample = smcOnly.sample()
    #expect(sample.gpu == nil && sample.ane == nil)
    #expect(sample.cpu != nil && sample.system != nil)

    let nothing = PowerReader(library: nil, smc: nil)
    #expect(!nothing.isAvailable)
    #expect(nothing.sample() == PowerSample())
}

@Test func powerReaderDegradesWithoutSMC() throws {
    let ioreportOnly = PowerReader(library: IOReport.library, smc: nil)
    _ = ioreportOnly.sample()
    Thread.sleep(forTimeInterval: 0.4)
    let sample = ioreportOnly.sample()
    #expect(sample.cpu == nil && sample.system == nil)
    #expect(sample.gpu != nil)
}

/// Each IOReport sample is a CFDictionary of every subscribed channel; dropping one
/// without release grows the footprint by kilobytes a tick. A real sample costs
/// ~4 ms, so 400 reads of each reader (800 samples a window) take a few seconds.
@Test func powerAndFrequencyReadersDoNotLeak() throws {
    let library = try #require(IOReport.library)
    let subscription = try #require(library.performanceSubscription())
    subscription.reuseWindow = 0  // every call must take (and release) a real sample
    let power = PowerReader(subscription: subscription)
    let frequency = try #require(CPUFrequencyReader(subscription: subscription))
    for _ in 0..<100 {
        _ = power.sample()
        _ = frequency.sample()
    }
    _ = try footprintStaysFlat(margin: 4 * 1024 * 1024) {
        for _ in 0..<400 {
            _ = power.sample()
            _ = frequency.sample()
        }
    }
}

@Test func ioreportFilterKeepsOnlyWantedChannels() throws {
    let library = try #require(IOReport.library)
    let subscription = try #require(library.subscribe(to: [("Energy Model", nil)]) { $0.name == "GPU Energy" })
    let a = try #require(subscription.sample())
    Thread.sleep(forTimeInterval: 0.1)
    let b = try #require(subscription.sample())
    let names = subscription.readings(from: a, to: b).map(\.channel.name)
    #expect(names == ["GPU Energy"])
    // A filter nothing passes yields no subscription rather than an empty one.
    #expect(library.subscribe(to: [("Energy Model", nil)]) { _ in false } == nil)
}

@Test func performanceSubscriptionSharesOneSamplePerTick() throws {
    let library = try #require(IOReport.library)
    let subscription = try #require(library.performanceSubscription())
    let first = try #require(subscription.sample())
    let second = try #require(subscription.sample())
    #expect(first.time == second.time, "second caller within the window must reuse the sample")
    let groups = Set(subscription.readings(from: first, to: second).map(\.channel.group))
    #expect(groups == ["Energy Model", "CPU Stats"])
    Thread.sleep(forTimeInterval: 0.3)
    #expect(try #require(subscription.sample()).time > first.time)
}

// MARK: CPU frequency

@Test func dvfsTablesParse() {
    func table(_ pairs: [(UInt32, UInt32)]) -> Data {
        var data = Data()
        for (frequency, voltage) in pairs {
            withUnsafeBytes(of: frequency.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: voltage.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
    // kHz, as newer chips store CPU ladders.
    #expect(DVFSTables.parse(table([(1_308_000, 760), (1_620_000, 785), (4_608_000, 1120)])) == [1308, 1620, 4608])
    // Hz, as older ones do.
    #expect(DVFSTables.parse(table([(600_000_000, 600), (2_064_000_000, 900)])) == [600, 2064])
    // A zero entry is a GPU or fabric ladder, not a CPU's.
    #expect(DVFSTables.parse(table([(0, 125), (338_000_000, 595), (1_620_000_000, 1010)])) == nil)
    // Not ascending, ragged, too short, or an absurd clock.
    #expect(DVFSTables.parse(table([(2_000_000, 1), (1_000_000, 1)])) == nil)
    #expect(DVFSTables.parse(Data(count: 20)) == nil)
    #expect(DVFSTables.parse(table([(1_000_000, 1)])) == nil)
    #expect(DVFSTables.parse(table([(100, 1), (200, 1)])) == nil)
}

@Test func ladderLookupNeverGuesses() {
    let super20 = (0..<20).map { Float(1300 + $0 * 170) }
    let perf15 = (0..<15).map { Float(1344 + $0 * 200) }
    let tables = ["a": super20, "b": perf15, "c": perf15]
    #expect(DVFSTables.ladder(states: 20, in: tables) == super20)
    // Two tables with identical clocks (clusters differing only in voltage) are one answer.
    #expect(DVFSTables.ladder(states: 15, in: tables) == perf15)
    #expect(DVFSTables.ladder(states: 7, in: tables) == nil)
    // Two different ladders of the same length are ambiguous: no answer, not a coin flip.
    #expect(DVFSTables.ladder(states: 15, in: ["x": perf15, "y": perf15.map { $0 + 100 }]) == nil)
}

@Test func ioreportStateNamesDecode() {
    #expect(CPUFrequencyReader.ladderIndex(of: "V0P14") == 0)
    #expect(CPUFrequencyReader.ladderIndex(of: "V14P0") == 14)
    #expect(CPUFrequencyReader.ladderIndex(of: "V19P0") == 19)
    for name in ["IDLE", "DOWN", "OFF", "", "P1", "V", "VxPy"] { #expect(CPUFrequencyReader.ladderIndex(of: name) == nil) }
    #expect(CPUFrequencyReader.classLetter("PCPU3") == "P")
    #expect(CPUFrequencyReader.classLetter("MCPU12") == "M")
    #expect(CPUFrequencyReader.classLetter("ECPU0") == "E")
    for name in ["PCPU", "ANE0", "GPU0", "MCPM0", ""] { #expect(CPUFrequencyReader.classLetter(name) == nil) }
    #expect(CPUFrequencyReader.rank("P") < CPUFrequencyReader.rank("M"))
    #expect(CPUFrequencyReader.rank("M") < CPUFrequencyReader.rank("E"))
}

@Test func cpuFrequencyReaderMatchesCoreClasses() throws {
    let reader = try #require(CPUFrequencyReader())
    let hardware = HardwareInfo.current()
    #expect(reader.sample() == nil, "first call only primes")

    // One busy thread per core of the fastest class (kept few: this test shares the
    // machine with the others), so that class has activity to measure.
    let deadline = Date().addingTimeInterval(0.6)
    let workers = (0..<(hardware.clusters.first?.count ?? 1)).map { _ in
        Thread {
            var x = 1.0
            while Date() < deadline { for _ in 0..<50_000 { x = x * 1.000_000_1 + 0.000_000_1 } }
        }
    }
    for worker in workers {
        worker.qualityOfService = .userInteractive
        worker.start()
    }
    Thread.sleep(forTimeInterval: 0.7)
    let sample = try #require(reader.sample())
    #expect(sample.clusters.map(\.name) == hardware.clusters.map(\.name))
    #expect(sample.clusters.map(\.coreCount) == hardware.clusters.map(\.count))
    for cluster in sample.clusters {
        #expect((0...1).contains(cluster.activeFraction))
        if let level = cluster.performanceLevel { #expect((0...1).contains(level)) }
        let maxMHz = try #require(cluster.maxMHz, "no ladder for \(cluster.name)")
        if let average = cluster.averageMHz { #expect(average > 500 && average <= maxMHz, "\(cluster.name) \(average) of \(maxMHz) MHz") }
    }
    let fastest = try #require(sample.clusters.first)
    #expect(fastest.activeFraction > 0.3, "\(fastest.name) was loaded but reads \(fastest.activeFraction)")
    #expect(fastest.averageMHz != nil && fastest.performanceLevel != nil)
}

@Test func cpuFrequencyWithoutLadderFallsBackToPerformanceLevel() throws {
    let reader = try #require(CPUFrequencyReader(tables: [:]))
    _ = reader.sample()
    var spin = 0.0
    let until = Date().addingTimeInterval(0.3)
    while Date() < until { spin += 1 }
    let sample = try #require(reader.sample())
    for cluster in sample.clusters {
        #expect(cluster.averageMHz == nil && cluster.maxMHz == nil)
    }
    #expect(sample.clusters.contains { $0.performanceLevel != nil })
    #expect(spin > 0)
}

@Test func cpuFrequencyReaderNeedsIOReport() {
    #expect(CPUFrequencyReader(library: nil) == nil)
}

// MARK: Sampler and store

@Test func samplerReadsGPUPowerAndFrequencyOnlyWhenWanted() async throws {
    let seen = Mutex((gpu: 0, power: 0, frequency: 0))
    let sampler = SamplerActor { snapshot in
        seen.withLock {
            if snapshot.gpu != nil { $0.gpu += 1 }
            if snapshot.power != nil { $0.power += 1 }
            if snapshot.cpuFrequency != nil { $0.frequency += 1 }
        }
    }
    // Only the GPU widget's metric: no IOReport, no SMC (PLAN.md §3-A).
    sampler.send(SamplerConfig(interval: 1, metrics: [.gpu], paused: false))
    try await Task.sleep(for: .milliseconds(2_600))
    let gpuOnly = seen.withLock { $0 }
    #expect(gpuOnly.gpu >= 2)
    #expect(gpuOnly.power == 0 && gpuOnly.frequency == 0)

    sampler.send(SamplerConfig(interval: 1, metrics: [.gpu, .power, .cpuFrequency], paused: false))
    try await Task.sleep(for: .milliseconds(2_600))
    let all = seen.withLock { $0 }
    #expect(all.power >= 2 && all.frequency >= 2)

    sampler.send(SamplerConfig(interval: 1, metrics: [], paused: false))
}

@MainActor @Test func storeKeepsGPUAndPowerHistory() {
    let store = MetricStore()
    store.ingest(Snapshot(gpu: GPUSample(device: 0.4, renderer: 0.3, tiler: 0.1, memoryInUse: 1, memoryAllocated: 2)))
    store.ingest(Snapshot(power: PowerSample(cpu: 5, gpu: 12, ane: nil, system: 30)))
    store.ingest(Snapshot(power: PowerSample(cpu: 6, gpu: nil, ane: nil, system: 31)))
    #expect(store.gpu?.device == 0.4)
    #expect(store.gpuDevice.values() == [0.4])
    #expect(store.gpuPower.values() == [12])  // a missing reading adds no zero to the history
    #expect(store.cpuPower.values() == [5, 6])
    #expect(store.power?.system == 31)
}
