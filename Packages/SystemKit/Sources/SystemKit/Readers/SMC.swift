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

    /// A key whose metadata is known, for repeated cheap reads (see ``readNumber(_:)``).
    public struct Key: Sendable, Hashable {
        let code: UInt32
        let info: SMCKeyInfoData
        public let name: String
        public let type: String
        public var size: Int { Int(info.dataSize) }
        public static func == (a: Key, b: Key) -> Bool { a.code == b.code }
        public func hash(into hasher: inout Hasher) { hasher.combine(code) }
    }

    /// Looks a key up once: type and size never change, so later reads skip the
    /// metadata call and cost a single IOKit round trip. nil if the key doesn't exist.
    public func key(_ name: String) -> Key? {
        guard let code = FourCC(name) else { return nil }
        return key(code: code.rawValue)
    }

    func key(code: UInt32) -> Key? {
        var info = SMCKeyInfoData()
        guard SMCReadKeyInfo(connection, code, &info) == 0 else { return nil }
        return Key(code: code, info: info, name: FourCC(rawValue: code).string, type: FourCC(rawValue: info.dataType).string)
    }

    /// Numeric value of a known key, without allocating: only for the 4-byte `flt `
    /// layout (every sensor this app reads); nil for other types or a failed read.
    public func readNumber(_ key: Key) -> Double? {
        guard key.size == 4, key.info.dataType == Self.floatType else { return nil }
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32) { buffer in
            guard SMCReadBytesWithInfo(connection, key.code, key.info, buffer.baseAddress!) == 0 else { return nil }
            let bits = UInt32(buffer[0]) | UInt32(buffer[1]) << 8 | UInt32(buffer[2]) << 16 | UInt32(buffer[3]) << 24
            return Double(Float(bitPattern: bits))
        }
    }

    private static let floatType = FourCC("flt ")!.rawValue

    /// Every key whose name starts with `prefix` (1 to 3 characters), found by binary
    /// search over the SMC's index order, which is sorted by name. A few dozen calls
    /// instead of walking all ~3600 keys. Verified against a full walk in the tests.
    public func keys(withPrefix prefix: String) -> [String] {
        let bytes = Array(prefix.utf8)
        guard (1...3).contains(bytes.count) else { return [] }
        let low = bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } << UInt32(8 * (4 - bytes.count))
        let high = low | (UInt32.max >> UInt32(8 * bytes.count))
        let count = keyCount
        func code(at index: Int) -> UInt32? {
            var code: UInt32 = 0
            return SMCKeyAtIndex(connection, UInt32(index), &code) == 0 ? code : nil
        }
        // First index whose key is >= low.
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            guard let c = code(at: mid) else { return [] }
            if c < low { lo = mid + 1 } else { hi = mid }
        }
        var result: [String] = []
        var index = lo
        while index < count, let c = code(at: index), c <= high {
            result.append(FourCC(rawValue: c).string)
            index += 1
        }
        return result
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
