import CPrivate
import Foundation

/// Apple's vendor HID sensors: on Apple Silicon this is where temperatures live
/// (the SMC no longer exposes them on M5).
///
/// The client and its service list are created once; `read()` only copies one event
/// per service. Not thread-safe: confine to one executor.
public final class HIDSensorClient {
    public enum Kind: String, Sendable, CaseIterable, Codable {
        case temperature, current, voltage

        var usagePage: Int { self == .temperature ? 0xFF00 : 0xFF08 }
        var usage: Int {
            switch self {
            case .temperature: 5
            case .current: 2
            case .voltage: 3
            }
        }
        var eventType: Int64 {
            Int64(self == .temperature ? kSistemHIDEventTypeTemperature : kSistemHIDEventTypePower)
        }
    }

    public struct Service: Sendable, Hashable {
        public let index: Int
        public let name: String
    }

    public let kind: Kind
    public let services: [Service]
    private let client: IOHIDEventSystemClient
    private let handles: [IOHIDServiceClient]

    public convenience init?(kind: Kind) {
        self.init(usagePage: kind.usagePage, usage: kind.usage, kind: kind)
    }

    /// Raw matching, for discovery of other vendor usages.
    public init?(usagePage: Int, usage: Int, kind: Kind) {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return nil }
        let matching = ["PrimaryUsagePage": usagePage, "PrimaryUsage": usage] as CFDictionary
        _ = IOHIDEventSystemClientSetMatching(client, matching)
        let handles = (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]) ?? []
        self.kind = kind
        self.client = client
        self.handles = handles
        self.services = handles.enumerated().map { index, handle in
            let name = IOHIDServiceClientCopyProperty(handle, "Product" as CFString) as? String
            return Service(index: index, name: name ?? "Sensor \(index)")
        }
    }

    /// One value per service, in `services` order; nil where the sensor gave nothing.
    public func read() -> [Double?] {
        let field = Int32(truncatingIfNeeded: kind.eventType << 16)
        return handles.map { handle in
            guard let event = IOHIDServiceClientCopyEvent(handle, kind.eventType, 0, 0) else { return nil }
            return IOHIDEventGetFloatValue(event, field)
        }
    }

    /// Some sensors report sentinel garbage (e.g. -9200 °C on M5 `tdev` sensors).
    public static func isPlausibleTemperature(_ celsius: Double) -> Bool {
        (-40...150).contains(celsius)
    }
}
