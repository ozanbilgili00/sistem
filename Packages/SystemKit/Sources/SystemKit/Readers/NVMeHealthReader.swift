import CPrivate
import Foundation

/// SMART / Health log of the internal NVMe SSD.
public struct DiskHealth: Sendable, Equatable {
    /// Bit field of NVMe critical warnings; 0 is healthy.
    public var criticalWarning: UInt8
    public var temperatureCelsius: Double?
    /// Percent of spare blocks left (100 is new).
    public var availableSpare: Int
    public var availableSpareThreshold: Int
    /// The drive's own wear estimate; can exceed 100.
    public var percentageUsed: Int
    public var bytesRead: UInt64
    public var bytesWritten: UInt64
    public var powerCycles: UInt64
    public var powerOnHours: UInt64
    public var unsafeShutdowns: UInt64
    public var mediaErrors: UInt64

    public var isHealthy: Bool { criticalWarning == 0 && mediaErrors == 0 }

    public init(criticalWarning: UInt8, temperatureCelsius: Double?, availableSpare: Int, availableSpareThreshold: Int,
                percentageUsed: Int, bytesRead: UInt64, bytesWritten: UInt64, powerCycles: UInt64, powerOnHours: UInt64,
                unsafeShutdowns: UInt64, mediaErrors: UInt64) {
        self.criticalWarning = criticalWarning
        self.temperatureCelsius = temperatureCelsius
        self.availableSpare = availableSpare
        self.availableSpareThreshold = availableSpareThreshold
        self.percentageUsed = percentageUsed
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
        self.powerCycles = powerCycles
        self.powerOnHours = powerOnHours
        self.unsafeShutdowns = unsafeShutdowns
        self.mediaErrors = mediaErrors
    }

    /// One NVMe "data unit" is 1000 blocks of 512 bytes.
    static let bytesPerDataUnit: UInt64 = 512_000

    init(_ raw: SistemNVMeHealth) {
        // 0 K means the drive reports no temperature.
        self.init(criticalWarning: raw.criticalWarning,
                  temperatureCelsius: raw.temperatureKelvin == 0 ? nil : Double(raw.temperatureKelvin) - 273.15,
                  availableSpare: Int(raw.availableSpare), availableSpareThreshold: Int(raw.availableSpareThreshold),
                  percentageUsed: Int(raw.percentageUsed),
                  bytesRead: raw.dataUnitsRead.multipliedReportingOverflow(by: Self.bytesPerDataUnit).partialValue,
                  bytesWritten: raw.dataUnitsWritten.multipliedReportingOverflow(by: Self.bytesPerDataUnit).partialValue,
                  powerCycles: raw.powerCycles, powerOnHours: raw.powerOnHours,
                  unsafeShutdowns: raw.unsafeShutdowns, mediaErrors: raw.mediaErrors)
    }
}

/// Reads the NVMe SMART log through `IONVMeSMARTUserClient`. The user client is
/// opened once and kept. Needs no privileges for the internal SSD on Apple Silicon
/// (checked on an M5 Pro Mac, macOS 27); returns nil from `init` where the system
/// refuses — external enclosures usually do.
///
/// Not thread-safe: confine to one executor.
public final class NVMeHealthReader {
    private let handle: UnsafeMutableRawPointer

    public init?() {
        guard let handle = SistemNVMeOpen() else { return nil }
        self.handle = handle
    }

    deinit { SistemNVMeClose(handle) }

    public func read() -> DiskHealth? {
        var raw = SistemNVMeHealth()
        guard SistemNVMeRead(handle, &raw) == 0 else { return nil }
        return DiskHealth(raw)
    }
}
