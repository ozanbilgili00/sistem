import CPrivate
import IOKit

/// A connection to the System Management Controller. Open once and reuse — opening
/// the user client is the expensive part (PLAN.md §3-B).
///
/// Not thread-safe: confine to one executor.
public final class SMC {
    private let connection: io_connect_t

    public init?() {
        let connection = SMCOpen()
        guard connection != IO_OBJECT_NULL else { return nil }
        self.connection = connection
    }

    deinit { SMCClose(connection) }

    public func read(_ key: String) -> SMCValue? {
        guard let code = FourCC(key) else { return nil }
        return read(code: code.rawValue)
    }

    func read(code: UInt32) -> SMCValue? {
        var info = SMCKeyInfoData()
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SMCReadKey(connection, code, &info, &bytes) == 0 else { return nil }
        let size = min(Int(info.dataSize), 32)
        return SMCValue(
            key: FourCC(rawValue: code).string,
            type: FourCC(rawValue: info.dataType).string,
            attributes: info.dataAttributes,
            bytes: Array(bytes.prefix(size))
        )
    }

    /// Number of keys the SMC exposes (`#KEY`).
    public var keyCount: Int {
        guard let value = read("#KEY"), value.bytes.count == 4 else { return 0 }
        return Int(value.bytes.bigEndianUInt)
    }

    /// Every key, by index. Slow-ish (a few thousand calls) — discovery only.
    public func allKeys() -> [String] {
        (0..<keyCount).compactMap { index in
            var code: UInt32 = 0
            guard SMCKeyAtIndex(connection, UInt32(index), &code) == 0 else { return nil }
            return FourCC(rawValue: code).string
        }
    }
}

public struct SMCValue: Sendable, Equatable {
    public let key: String
    /// Four-character type code, e.g. "flt ", "ui8 ", "sp78".
    public let type: String
    public let attributes: UInt8
    public let bytes: [UInt8]

    /// Bit 0x40 of the key attributes marks a key the SMC accepts writes to. Writing
    /// still needs root; this only says whether trying makes sense.
    public var isWritable: Bool { attributes & 0x40 != 0 }

    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// Numeric value for the common types; nil for strings and unknown layouts.
    /// Floats are little-endian on Apple Silicon; integer and fixed-point types keep
    /// the SMC's historical big-endian layout.
    public var number: Double? {
        switch type {
        case "flt " where bytes.count == 4:
            return Double(Float(bitPattern: UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24))
        case "ui8 ", "ui16", "ui32", "flag":
            return Double(bytes.bigEndianUInt)
        case "si8 " where bytes.count == 1:
            return Double(Int8(bitPattern: bytes[0]))
        case "si16" where bytes.count == 2:
            return Double(Int16(bitPattern: UInt16(bytes.bigEndianUInt)))
        case "si32" where bytes.count == 4:
            return Double(Int32(bitPattern: UInt32(bytes.bigEndianUInt)))
        default:
            // Fixed point: "fpXY" unsigned / "spXY" signed, Y = fraction bits (hex).
            guard bytes.count == 2, type.count == 4,
                  type.hasPrefix("fp") || type.hasPrefix("sp"),
                  let fraction = Int(String(type.last!), radix: 16) else { return nil }
            let raw = UInt16(bytes.bigEndianUInt)
            let value = type.hasPrefix("sp") ? Double(Int16(bitPattern: raw)) : Double(raw)
            return value / Double(1 << fraction)
        }
    }
}

/// A four-character SMC code packed big-endian into a UInt32.
struct FourCC {
    let rawValue: UInt32

    init(rawValue: UInt32) { self.rawValue = rawValue }

    init?(_ string: String) {
        let scalars = Array(string.utf8)
        guard scalars.count == 4 else { return nil }
        rawValue = scalars.reduce(0) { $0 << 8 | UInt32($1) }
    }

    var string: String {
        let bytes = [24, 16, 8, 0].map { UInt8((rawValue >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

extension [UInt8] {
    var bigEndianUInt: UInt64 { reduce(0) { $0 << 8 | UInt64($1) } }
}
