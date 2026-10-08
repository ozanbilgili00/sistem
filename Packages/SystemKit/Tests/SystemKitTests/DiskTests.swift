import Darwin
import Foundation
import Testing
@testable import SystemKit
import CPrivate

// MARK: Counters and rates

@Test func diskCountersParseDriverStatistics() {
    let counters = DiskCounters(statistics: [
        "Bytes (Read)": 64_072_253_440, "Bytes (Write)": 18_269_171_712,
        "Operations (Read)": 1_487_166, "Operations (Write)": 1_560_085, "Errors (Read)": 0,
    ] as CFDictionary)
    #expect(counters == DiskCounters(readBytes: 64_072_253_440, writeBytes: 18_269_171_712, readOps: 1_487_166, writeOps: 1_560_085))
    // Operations are optional, the byte counters are not.
    #expect(DiskCounters(statistics: ["Bytes (Read)": 5, "Bytes (Write)": 6] as CFDictionary)?.readOps == 0)
    #expect(DiskCounters(statistics: ["Bytes (Read)": 5] as CFDictionary) == nil)
    #expect(DiskCounters(statistics: [:] as CFDictionary) == nil)
}

@Test func diskRateIsDeltaOverSecondsAndNeverNegative() {
    #expect(DiskReader.rate(from: 1_000, to: 3_000, seconds: 2) == 1_000)
    #expect(DiskReader.rate(from: 1_000, to: 1_000, seconds: 2) == 0)
    // A counter that went backwards (device replaced) is no traffic, not a huge rate.
    #expect(DiskReader.rate(from: 9_000, to: 100, seconds: 2) == 0)
    #expect(DiskReader.rate(from: 0, to: 100, seconds: 0) == 0)
}

@Test func volumeUsedFraction() {
    let volume = DiskVolume(name: "A", mountPoint: "/", total: 1_000, available: 250, kind: .internalDisk)
    #expect(volume.used == 750 && volume.usedFraction == 0.75)
    // More free than total (stale numbers) never underflows.
    #expect(DiskVolume(name: "B", mountPoint: "/b", total: 100, available: 500, kind: .external).used == 0)
    #expect(DiskVolume(name: "C", mountPoint: "/c", total: 0, available: 0, kind: .network).usedFraction == 0)
}

// MARK: Live reader

@Test func diskReaderSeesPhysicalDriveAndVolumes() throws {
    let reader = DiskReader()
    #expect(reader.deviceCount >= 1)
    let sample = reader.sample()
    #expect(sample.readRate == 0 && sample.writeRate == 0, "first sample has no baseline")
    let device = try #require(sample.devices.first)
    #expect(device.bsdName?.hasPrefix("disk") == true)
    #expect(!device.name.isEmpty)
    let volumes = try #require(sample.volumes, "the first sample lists volumes")
    let boot = try #require(volumes.first { $0.isBoot })
    #expect(boot.total > 100_000_000_000 && boot.available <= boot.total)
    #expect(boot.kind == .internalDisk)
    // Disk images are virtual: they must not appear as drives.
    #expect(!sample.devices.contains { $0.name == "Disk Image" })
}

@Test func volumesRefreshOnlyEveryFifteenthSample() {
    let reader = DiskReader()
    var withVolumes: [Int] = []
    for index in 0..<31 where reader.sample().volumes != nil { withVolumes.append(index) }
    #expect(withVolumes == [0, 15, 30])
}

@Test func diskReaderMeasuresAKnownWrite() throws {
    let reader = DiskReader()
    _ = reader.sample()
    reader.prime()
    let directory = FileManager.default.temporaryDirectory.appending(path: "sistem-test-\(getpid())-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appending(path: "load.bin").path
    let megabytes = 64
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    #expect(fd >= 0)
    _ = fcntl(fd, F_NOCACHE, 1)
    let chunk = [UInt8](repeating: 0x5A, count: 1 << 20)
    for _ in 0..<megabytes { _ = chunk.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } }
    fsync(fd)
    close(fd)
    let sample = reader.sample()
    #expect(sample.interval > 0)
    let written = sample.writeRate * sample.interval
    // At least what we wrote (minus caching slack); other processes may add some.
    #expect(written >= Double(megabytes) * 1_048_576 * 0.75, "wrote \(megabytes) MiB, saw \(written / 1_048_576) MiB")
    #expect(written < Double(megabytes) * 1_048_576 * 20)
}

@Test func hotPlugWatcherStartsAndStopsCleanly() throws {
    let queue = DispatchQueue(label: "test.disk.watch")
    // Creating and dropping readers must unregister IOKit and DiskArbitration callbacks
    // before the watcher is freed; a dangling callback would crash here.
    _ = try footprintStaysFlat(margin: 8 * 1024 * 1024) {
        for _ in 0..<40 {
            let reader = DiskReader(queue: queue)
            _ = reader.sample()
        }
        queue.sync {}
    }
    Thread.sleep(forTimeInterval: 0.3)
    queue.sync {}
}

@Test func diskReaderDoesNotLeak() throws {
    // Throughput reads only: capacity refreshes (14 ms each) are left to the next test.
    let reader = DiskReader(volumeInterval: .max)
    for _ in 0..<500 { _ = reader.sample() }
    _ = try footprintStaysFlat(margin: 3 * 1024 * 1024) {
        for _ in 0..<10_000 { _ = reader.sample() }
    }
}

/// `URL` caches resource values and every query returns fresh objects; a refresh that
/// kept either would grow by kilobytes per call.
@Test func volumeRefreshDoesNotLeak() throws {
    let reader = DiskReader(volumeInterval: 1)
    for _ in 0..<20 { _ = reader.sample() }
    _ = try footprintStaysFlat(margin: 3 * 1024 * 1024) {
        for _ in 0..<150 { _ = reader.sample() }
    }
}

// MARK: SMART

/// One test: the SMART user client is exclusive, so two readers open at once (tests run
/// in parallel) would make the second `init` fail.
@Test func nvmeHealthReaderReportsPlausibleValuesAndDoesNotLeak() throws {
    let reader = try #require(NVMeHealthReader(), "SMART should open without root on the internal SSD")
    let health = try #require(reader.read())
    #expect((0...100).contains(health.availableSpare))
    #expect(health.percentageUsed <= 255)
    if let temperature = health.temperatureCelsius { #expect((0..<120).contains(temperature)) }
    #expect(health.bytesWritten > 0 && health.powerOnHours > 0 && health.powerCycles > 0)
    #expect(health.bytesWritten % DiskHealth.bytesPerDataUnit == 0)

    for _ in 0..<500 { _ = reader.read() }
    _ = try footprintStaysFlat(margin: 3 * 1024 * 1024) {
        for _ in 0..<10_000 { _ = reader.read() }
    }
}

@Test func healthConversionHandlesZeroKelvinAndUnits() {
    var raw = SistemNVMeHealth()
    raw.temperatureKelvin = 0
    raw.dataUnitsWritten = 2
    raw.availableSpare = 100
    let health = DiskHealth(raw)
    #expect(health.temperatureCelsius == nil)
    #expect(health.bytesWritten == 1_024_000)
    raw.temperatureKelvin = 303
    #expect(abs((DiskHealth(raw).temperatureCelsius ?? 0) - 29.85) < 0.01)
    #expect(health.isHealthy)
}
