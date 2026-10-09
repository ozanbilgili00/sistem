import Foundation
import Testing
@testable import SystemKit

private func description(_ values: [String: Any]) -> CFDictionary { values as CFDictionary }

private func base() -> [String: Any] { [
    "Type": "InternalBattery", "Is Present": true, "Current Capacity": 80, "Max Capacity": 100,
    "Power Source State": "Battery Power", "Is Charging": false, "Is Charged": false,
    "Time to Empty": 215, "Time to Full Charge": 0,
] }

private func with(_ changes: [String: Any]) -> CFDictionary {
    description(base().merging(changes) { $1 })
}

@Test func batteryDescriptionStates() throws {
    let discharging = try #require(BatteryReader.parse(with([:])))
    #expect(discharging.state == .discharging && discharging.percent == 80)
    #expect(discharging.minutesRemaining == 215 && discharging.remainingText == "3:35")
    #expect(!discharging.isOnPower && !discharging.isEstimating)

    let charging = try #require(BatteryReader.parse(with([
        "Power Source State": "AC Power", "Is Charging": true, "Time to Full Charge": 65, "Time to Empty": 0,
    ])))
    #expect(charging.state == .charging && charging.minutesRemaining == 65 && charging.remainingText == "1:05")

    // Held at a charge limit: on power, not charging, no estimate to show (this Mac, 2026-10-08).
    let held = try #require(BatteryReader.parse(with(["Power Source State": "AC Power", "Time to Empty": 0])))
    #expect(held.state == .pluggedNotCharging && held.minutesRemaining == nil && !held.isEstimating)

    let charged = try #require(BatteryReader.parse(with(["Power Source State": "AC Power", "Is Charged": true, "Current Capacity": 100])))
    #expect(charged.state == .charged && charged.percent == 100 && charged.minutesRemaining == nil)
}

@Test func batteryEstimateStates() throws {
    // -1 is "still working it out"; 0 on battery is "no estimate" too, but not "estimating".
    let estimating = try #require(BatteryReader.parse(with(["Time to Empty": -1])))
    #expect(estimating.minutesRemaining == nil && estimating.isEstimating)
    let zero = try #require(BatteryReader.parse(with(["Time to Empty": 0])))
    #expect(zero.minutesRemaining == nil && !zero.isEstimating)
    // Garbage minutes are not shown.
    let huge = try #require(BatteryReader.parse(with(["Time to Empty": 9_999_999])))
    #expect(huge.minutesRemaining == nil)
    // Percent follows Current/Max when Max isn't 100, and stays inside 0...100.
    let scaled = try #require(BatteryReader.parse(with(["Current Capacity": 3_000, "Max Capacity": 6_000])))
    #expect(scaled.percent == 50)
    let over = try #require(BatteryReader.parse(with(["Current Capacity": 120])))
    #expect(over.percent == 100)
}

@Test func nonBatterySourcesAreIgnored() {
    #expect(BatteryReader.parse(with(["Type": "UPS"])) == nil)
    #expect(BatteryReader.parse(with(["Is Present": false])) == nil)
    #expect(BatteryReader.parse(with(["Max Capacity": 0])) == nil)
    #expect(BatteryReader.parse(description(["Type": "InternalBattery"])) == nil)
}

@Test func adapterDetailsKeepOnlyWattsAndName() throws {
    let adapter = try #require(BatteryReader.parseAdapter(description([
        "Watts": 140, "Name": "140W USB-C Power Adapter", "SerialString": "XXXXXXXX", "IsWireless": false,
    ])))
    #expect(adapter == AdapterInfo(watts: 140, name: "140W USB-C Power Adapter", isWireless: false))
    #expect(BatteryReader.parseAdapter(description(["Watts": 99_999])) == nil)
    #expect(BatteryReader.parseAdapter(description([:])) == nil)
}

@Test func batteryHealthMath() {
    var health = BatteryHealth(volts: 12.3, amps: -1.5)
    #expect(abs((health.batteryWatts ?? 0) + 18.45) < 0.001)
    health.amps = nil
    #expect(health.batteryWatts == nil)
}

@Test func liveBatteryReadIsConsistent() throws {
    let reader = BatteryReader()
    let status = reader.sample()
    switch status {
    case .notPresent:
        #expect(status.sample == nil)  // desktop Mac: a clear "no battery", not a zero
    case .present(let sample):
        #expect((0...100).contains(sample.percent))
        #expect(sample.isOnPower == (sample.state != .discharging))
        if sample.state == .discharging || sample.state == .charging {
            if let minutes = sample.minutesRemaining { #expect((1..<100_000).contains(minutes)) }
        } else {
            #expect(sample.minutesRemaining == nil)
        }
        #expect(sample.isOnPower == (sample.adapter != nil) || sample.adapter == nil)
        if let health = sample.health {
            if let capacity = health.maximumCapacityPercent { #expect((1...100).contains(capacity)) }
            if let volts = health.volts { #expect((1...30).contains(volts)) }
            if let celsius = health.temperatureCelsius { #expect(SensorValidity.isValidTemperature(celsius)) }
        }
    }
}

/// The power source is read once and then only when told it changed.
@Test func powerSourceIsReadOnlyOnChange() {
    let reader = BatteryReader()
    for _ in 0..<50 { _ = reader.sample() }
    #expect(reader.powerSourceReads == 1)
    reader.markChanged()
    _ = reader.sample()
    _ = reader.sample()
    #expect(reader.powerSourceReads == 2)
}

@Test func batteryReaderDoesNotLeak() throws {
    let reader = BatteryReader()
    for _ in 0..<200 { _ = reader.sample() }
    _ = try footprintStaysFlat(margin: 3 * 1024 * 1024) {
        for _ in 0..<10_000 { _ = reader.sample() }
        for _ in 0..<2_000 {  // the event path: reread power too
            reader.markChanged()
            _ = reader.sample()
        }
    }
}
