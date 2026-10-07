import Foundation
import IOKit

/// GPU load and memory over the last moment, as the driver reports it. Fractions
/// are 0...1; the driver publishes whole percents.
public struct GPUSample: Sendable, Equatable {
    /// "Device Utilization %": how busy the GPU as a whole was. The menu bar number.
    public var device: Float
    /// Fragment / render work.
    public var renderer: Float
    /// Vertex / tiling work.
    public var tiler: Float
    /// Bytes of system memory the GPU has mapped right now.
    public var memoryInUse: UInt64
    /// Bytes the driver has allocated for the GPU, mapped or not.
    public var memoryAllocated: UInt64

    public init(device: Float, renderer: Float, tiler: Float, memoryInUse: UInt64, memoryAllocated: UInt64) {
        self.device = device
        self.renderer = renderer
        self.tiler = tiler
        self.memoryInUse = memoryInUse
        self.memoryAllocated = memoryAllocated
    }
}

/// Reads the `PerformanceStatistics` dictionary of the GPU's IOAccelerator service.
///
/// The service is looked up once and kept; a read is one registry property fetch
/// (no tree walk, ~20 µs), which hands back a new dictionary the reader releases.
/// Keys checked against `ioreg -r -c IOAccelerator -l` on an M5 Pro (2026-10-06).
///
/// Not thread-safe: confine to one executor.
public final class GPUReader {
    private let service: io_service_t
    private let key = "PerformanceStatistics" as CFString

    /// nil when no accelerator publishes performance statistics (virtual machines).
    public init?() {
        var iterator: io_iterator_t = IO_OBJECT_NULL
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        let key = "PerformanceStatistics" as CFString
        // Apple Silicon has one; on a Mac with two GPUs the first one that reports
        // statistics wins.
        var found: io_service_t = IO_OBJECT_NULL
        while case let candidate = IOIteratorNext(iterator), candidate != IO_OBJECT_NULL {
            if found == IO_OBJECT_NULL, Self.statistics(of: candidate, key: key) != nil {
                found = candidate
            } else {
                IOObjectRelease(candidate)
            }
        }
        guard found != IO_OBJECT_NULL else { return nil }
        service = found
    }

    deinit { IOObjectRelease(service) }

    public func sample() -> GPUSample? {
        Self.statistics(of: service, key: key).flatMap(Self.parse)
    }

    /// `IORegistryEntryCreateCFProperty` follows the Create rule: the dictionary is
    /// ours, and `takeRetainedValue` is what balances it.
    private static func statistics(of service: io_service_t, key: CFString) -> CFDictionary? {
        guard let property = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0)?
            .takeRetainedValue(), CFGetTypeID(property) == CFDictionaryGetTypeID() else { return nil }
        return unsafeDowncast(property, to: CFDictionary.self)
    }

    /// Plain CF calls rather than bridging to `NSDictionary`: no autoreleased
    /// temporaries, so a read leaves nothing behind for a pool to collect.
    static func parse(_ statistics: CFDictionary) -> GPUSample? {
        func number(_ key: String) -> Int64? {
            let key = key as CFString
            guard let raw = CFDictionaryGetValue(statistics, Unmanaged.passUnretained(key).toOpaque()) else { return nil }
            let value = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
            guard CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
            var result: Int64 = 0
            return CFNumberGetValue(unsafeDowncast(value, to: CFNumber.self), .sInt64Type, &result) ? result : nil
        }
        func percent(_ key: String) -> Float? {
            number(key).map { min(1, max(0, Float($0) / 100)) }
        }
        guard let device = percent("Device Utilization %") else { return nil }
        return GPUSample(
            device: device,
            renderer: percent("Renderer Utilization %") ?? device,
            tiler: percent("Tiler Utilization %") ?? 0,
            memoryInUse: UInt64(max(0, number("In use system memory") ?? 0)),
            memoryAllocated: UInt64(max(0, number("Alloc system memory") ?? 0))
        )
    }
}
