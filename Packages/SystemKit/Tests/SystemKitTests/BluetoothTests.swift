import Foundation
import Testing
@testable import SystemKit

/// Device names here are made up; real ones are personal data.
private let fixture = """
{"SPBluetoothDataType":[{
 "controller_properties":{"controller_state":"attrib_on","controller_address":"00:11:22:33:44:55"},
 "device_connected":[
  {"Kulaklık A":{"device_address":"AA:BB:CC:00:00:01","device_batteryLevelLeft":"%100","device_batteryLevelRight":"%90","device_batteryLevelCase":"%45","device_minorType":"Headphones"}},
  {"Kulaklık A":{"device_address":"AA:BB:CC:00:00:02","device_services":"0x400000 < BLE >"}},
  {"Klavye":{"device_address":"AA-BB-CC-00-00-03","device_minorType":"Keyboard","device_batteryLevel":"%67"}}
 ],
 "device_not_connected":[
  {"Fare":{"device_address":"AA:BB:CC:00:00:04","device_minorType":"Mouse","device_batteryLevelMain":"%250"}},
  {"Garip":{"device_address":"not-an-address","device_batteryLevelMain":"abc"}},
  {"  ":{"device_address":"AA:BB:CC:00:00:05"}}
 ]}]}
"""

@Test func profilerOutputParses() throws {
    let sample = try #require(BluetoothProfile.parse(Data(fixture.utf8)))
    #expect(sample.isPoweredOn == true)
    // The two entries of the headset become one row; the blank name is dropped.
    #expect(sample.devices.map(\.name).sorted() == ["Fare", "Garip", "Klavye", "Kulaklık A"])
    let headset = try #require(sample.devices.first { $0.name == "Kulaklık A" })
    #expect(headset.isConnected && headset.kind == .headphones && headset.lowestBattery == 45)
    #expect(headset.batteries.count == 3)
    let keyboard = try #require(sample.devices.first { $0.name == "Klavye" })
    #expect(keyboard.id == "AA:BB:CC:00:00:03" && keyboard.batteries == [.init(part: .main, percent: 67)] && keyboard.kind == .keyboard)
    // 250 % and "abc" are not battery levels; a bad address falls back to the name.
    let mouse = try #require(sample.devices.first { $0.name == "Fare" })
    #expect(!mouse.isConnected && mouse.batteries.isEmpty && mouse.kind == .mouse)
    #expect(sample.devices.first { $0.name == "Garip" }?.id == "name:garip")
    #expect(sample.connected.count == 2)
}

@Test func malformedProfilerOutputIsRejected() {
    for bad in ["", "not json", "[]", "{}", "{\"SPBluetoothDataType\":[]}", "{\"SPBluetoothDataType\":[1]}"] {
        #expect(BluetoothProfile.parse(Data(bad.utf8)) == nil, "\(bad)")
    }
    #expect(BluetoothProfile.parse(Data(count: 5_000_000)) == nil)
    // A well-formed section with no devices is an empty list, not an error.
    #expect(BluetoothProfile.parse(Data("{\"SPBluetoothDataType\":[{}]}".utf8))?.devices == [])
}

@Test func percentAndAddressValidation() {
    #expect(BluetoothProfile.percent("%80") == 80)
    #expect(BluetoothProfile.percent("80 %") == 80)
    #expect(BluetoothProfile.percent(0) == 0)
    #expect(BluetoothProfile.percent("-5") == 5)  // the sign is dropped, never a negative level
    #expect(BluetoothProfile.percent("101") == nil)
    #expect(BluetoothProfile.percent(nil) == nil)
    #expect(BluetoothProfile.normalizedAddress("aa-bb-cc-dd-ee-ff") == "AA:BB:CC:DD:EE:FF")
    #expect(BluetoothProfile.normalizedAddress("AA:BB:CC:DD:EE") == nil)
    #expect(BluetoothProfile.normalizedAddress("ZZ:BB:CC:DD:EE:FF") == nil)
}

@Suite(.serialized) struct BluetoothLaunchTests {
    @Test func refreshRunsTheChildOnceAtATime() async throws {
        let reader = BluetoothReader()
        let calls = LockedCounter()
        reader.runner = { calls.bump(); Thread.sleep(forTimeInterval: 0.3); return Data(fixture.utf8) }
        let delivered = LockedCounter()
        #expect(reader.refresh { _ in delivered.bump() })
        #expect(!reader.refresh { _ in delivered.bump() })  // still running: no second child
        try await Task.sleep(for: .seconds(0.8))
        #expect(calls.value == 1 && delivered.value == 1)
        #expect(reader.refresh { _ in delivered.bump() })  // free again
        try await Task.sleep(for: .seconds(0.8))
        #expect(calls.value == 2)
    }

    /// The gate: with no Bluetooth consumer the sampler never starts `system_profiler`, however many ticks run.
    @Test func closedBluetoothUILaunchesNothing() async throws {
        let before = BluetoothReader.launchCount
        let sampler = SamplerActor { _ in }
        sampler.send(SamplerConfig(interval: 0.04, metrics: [.cpu, .battery], paused: false))
        try await Task.sleep(for: .seconds(2))  // ~50 ticks: past two full Bluetooth periods
        sampler.send(SamplerConfig(interval: 0.04, metrics: [], paused: true))
        #expect(BluetoothReader.launchCount == before)
    }

    @Test func openBluetoothUILaunchesIt() async throws {
        let before = BluetoothReader.launchCount
        let sampler = SamplerActor { _ in }
        sampler.send(SamplerConfig(interval: 0.04, metrics: [.bluetooth], paused: false))
        try await Task.sleep(for: .seconds(2))
        sampler.send(SamplerConfig(interval: 0.04, metrics: [], paused: true))
        let launches = BluetoothReader.launchCount - before
        // One immediately, then every 30th tick (1.2 s): not one per tick.
        #expect((1...4).contains(launches), "launches \(launches)")
    }

    @Test func realProfilerOutputParses() async throws {
        let data = try #require(BluetoothReader.runSystemProfiler())
        let sample = try #require(BluetoothProfile.parse(data))
        for device in sample.devices {
            #expect(!device.name.isEmpty && device.name.count <= 64)
            for battery in device.batteries { #expect((0...100).contains(battery.percent)) }
        }
    }

    @Test func readerDoesNotLeak() async throws {
        let reader = BluetoothReader()
        let data = Data(fixture.utf8)
        reader.runner = { data }
        _ = try footprintStaysFlat(margin: 3 * 1024 * 1024) {
            // Each parse runs inside a dispatch block, which drains its autorelease pool when it ends.
            for _ in 0..<10_000 { autoreleasepool { _ = BluetoothProfile.parse(data) } }
        }
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
