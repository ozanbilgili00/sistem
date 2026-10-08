import Foundation
import Testing
@testable import SystemKit

@Test func sensorValidityRejectsSentinels() {
    // HID `tdev` sentinel, an unpopulated SMC sensor, NaN, infinities, out-of-range.
    for bad in [-9201.14, 0, .nan, .infinity, -51, 150.5, -306_783_232] {
        #expect(!SensorValidity.isValidTemperature(bad), "\(bad)")
    }
    for good in [-10.0, 0.4, 28.5, 92, 150] {
        #expect(SensorValidity.isValidTemperature(good), "\(good)")
    }
    #expect(!SensorValidity.isValid(-1, kind: .power))
    #expect(!SensorValidity.isValid(61, kind: .voltage))
    #expect(SensorValidity.isValid(-0.4, kind: .current))
    #expect(!SensorValidity.isValid(25_000, kind: .fan))
    #expect(SensorValidity.isValid(0, kind: .fan))  // a stopped fan is a real reading
}

@Test func smcPrefixSearchMatchesFullWalk() throws {
    let smc = try #require(SMC())
    let all = smc.allKeys()
    for prefix in ["T", "F", "P", "V", "I", "Tp", "TPD", "ZZ"] {
        #expect(smc.keys(withPrefix: prefix) == all.filter { $0.hasPrefix(prefix) }, "prefix \(prefix)")
    }
    #expect(smc.keys(withPrefix: "").isEmpty)
}

@Test func sensorCatalogListsOnlyValidSensors() throws {
    let reader = try #require(SensorReader())
    let catalog = reader.catalog
    #expect(!catalog.sensors.isEmpty)
    let sample = reader.sample()
    #expect(sample.values.count == catalog.sensors.count)
    // Every value is either dropped or valid for its kind: nothing like -9200 °C.
    for (info, value) in zip(catalog.sensors, sample.values) {
        guard let value else { continue }
        #expect(SensorValidity.isValid(Double(value), kind: info.kind), "\(info.key) \(value)")
    }
    let temperatures = sample.readings(of: .temperature).map(\.value)
    #expect(!temperatures.isEmpty)
    #expect(temperatures.allSatisfy { $0 >= Float(SensorValidity.admissionFloor) - 1 && $0 < 150 })
    // No duplicated keys, and no zero-valued temperature.
    #expect(Set(catalog.sensors.map(\.key)).count == catalog.sensors.count)
    #expect(!temperatures.contains(0))
    for fan in sample.fans {
        #expect(fan.info.maxRPM >= fan.info.minRPM && fan.info.maxRPM > 0)
        if let rpm = fan.rpm { #expect((0...20_000).contains(rpm)) }
    }
}

@Test func sensorDerivedValuesAreConsistent() throws {
    let reader = try #require(SensorReader())
    let sample = reader.sample()
    let t = sample.temperature
    if reader.catalog.isKnownModel {
        let cpu = sample.readings(of: .temperature, group: .cpuSuper) + sample.readings(of: .temperature, group: .cpuPerformance)
        let hottest = try #require(cpu.map(\.value).max())
        let average = try #require(t.cpuAverage)
        #expect(t.cpuHottest == hottest)
        #expect(average <= hottest && average >= (cpu.map(\.value).min() ?? 0))
        #expect(t.gpuHottest == sample.readings(of: .temperature, group: .gpu).map(\.value).max())
        // The menu bar read covers the same sensors, so within a moment's drift it agrees.
        let light = reader.sampleTemperature()
        #expect(abs((light.cpuHottest ?? 0) - hottest) < 8)
        #expect(light.gpuHottest == nil)
        #expect(reader.sampleTemperature(includeGPU: true).gpuHottest != nil)
        #expect(reader.headlineReadCount < reader.fullReadCount)
    }
    #expect(t.hottest != nil)
    #expect(t.headline != nil)
}

@Test func unknownModelListsRawKeysOnly() throws {
    let reader = try #require(SensorReader(model: "Mac99,9"))
    let catalog = reader.catalog
    #expect(!catalog.isKnownModel)
    #expect(!catalog.sensors.isEmpty)
    for info in catalog.sensors {
        #expect(info.group == .other)
        #expect(info.label == .raw(info.key))
    }
    // No CPU group to take the headline from: it falls back to the hottest of all.
    let light = reader.sampleTemperature()
    #expect(light.cpuHottest == nil && light.hottest != nil && light.headline == light.hottest)
}

@Test func missingSMCMeansNoReader() {
    #expect(SensorReader(smc: nil) == nil)
}

@Test func verifiedModelNamesAreStable() throws {
    #expect(SensorNaming.rule(for: "Tp00", model: "Mac17,8")?.group == .cpuSuper)
    #expect(SensorNaming.rule(for: "Tm1Y", model: "Mac17,8")?.group == .cpuPerformance)
    #expect(SensorNaming.rule(for: "Tg43", model: "Mac17,8")?.group == .gpu)
    #expect(SensorNaming.rule(for: "TB1T", model: "Mac17,8")?.group == .battery)
    #expect(SensorNaming.rule(for: "Tp00", model: "Mac1,1") == nil)
    #expect(SensorNaming.rule(for: "Ts0a", model: "Mac17,8") == nil)
}

/// A key read allocates a temporary buffer and returns a Double; a catalog sample returns
/// arrays. None of it may accumulate: more than 10 000 SMC reads of each kind.
@Test func sensorReadersDoNotLeak() throws {
    let reader = try #require(SensorReader())
    _ = reader.catalog
    let smc = try #require(SMC())
    let key = try #require(smc.key("PSTR"))
    for _ in 0..<500 { _ = smc.readNumber(key) }
    _ = try footprintStaysFlat(margin: 3 * 1024 * 1024) {
        for _ in 0..<10_000 { _ = smc.readNumber(key) }
        // 40 full reads ≈ 10 500 keys, 200 menu bar reads ≈ 12 600 keys.
        for _ in 0..<40 { _ = reader.sample() }
        for _ in 0..<200 { _ = reader.sampleTemperature(includeGPU: true) }
    }
}
