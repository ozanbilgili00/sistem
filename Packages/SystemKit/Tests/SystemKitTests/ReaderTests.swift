import Foundation
import Testing
@testable import SystemKit

@Test func fourCCRoundTrips() {
    #expect(FourCC("F0Ac")?.string == "F0Ac")
    #expect(FourCC("#KEY")?.rawValue == 0x234B_4559)
    #expect(FourCC("toolong") == nil)
}

@Test func decodesFixedPointAndFloat() {
    #expect(SMCValue(key: "T", type: "sp78", attributes: 0, bytes: [0x2A, 0x80]).number == 42.5)
    #expect(SMCValue(key: "F", type: "fpe2", attributes: 0, bytes: [0x00, 0x08]).number == 2)
    // 1350.0 as little-endian Float, as F0Mn reads on an M5 Pro.
    #expect(SMCValue(key: "F0Mn", type: "flt ", attributes: 0, bytes: [0x00, 0xC0, 0xA8, 0x44]).number == 1350)
    #expect(SMCValue(key: "W", type: "flag", attributes: 0x40, bytes: [1]).isWritable)
}

@Test func smcReportsKeysAndFans() throws {
    let smc = try #require(SMC())
    #expect(smc.keyCount > 100)
    let fans = try #require(smc.read("FNum")?.number)
    #expect(fans >= 0 && fans <= 4)
}

@Test func hidTemperaturesIncludePlausibleValues() throws {
    let client = try #require(HIDSensorClient(kind: .temperature))
    let values = client.read().compactMap { $0 }
    #expect(!client.services.isEmpty)
    #expect(values.contains(where: HIDSensorClient.isPlausibleTemperature))
}

@Test func ioreportEnergySamplesProduceReadings() throws {
    let library = try #require(IOReport.library)
    let subscription = try #require(library.subscribe(to: [("Energy Model", nil)]))
    let first = try #require(subscription.sample())
    Thread.sleep(forTimeInterval: 0.2)
    let second = try #require(subscription.sample())
    let readings = subscription.readings(from: first, to: second)
    #expect(!readings.isEmpty)
    #expect(readings.contains { ($0.value ?? 0) > 0 })
}
