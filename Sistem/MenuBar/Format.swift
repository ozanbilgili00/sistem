import Foundation
import SystemKit

/// Number formatting shared by the menu bar and the window, so both follow the
/// user's locale the same way (Turkish writes "%12", English "12%").
enum Format {
    static func percent(_ fraction: Float?) -> String {
        guard let fraction else { return "—" }
        return Double(fraction).formatted(.percent.precision(.fractionLength(0)))
    }

    static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return Int64(clamping: value).formatted(.byteCount(style: .memory))
    }

    static func watts(_ value: Float?) -> String {
        guard let value else { return "—" }
        return "\(Double(value).formatted(.number.precision(.fractionLength(1)))) W"
    }

    /// Always gigahertz with two decimals: a CPU clock sits between 1 and 5 GHz, and a
    /// fixed unit keeps a changing value from jumping between "980 MHz" and "1,02 GHz".
    static func gigahertz(_ megahertz: Float?) -> String {
        guard let megahertz else { return "—" }
        return "\(Double(megahertz / 1000).formatted(.number.precision(.fractionLength(2)))) GHz"
    }

    static func decimal(_ value: Double, digits: Int = 2) -> String {
        value.formatted(.number.precision(.fractionLength(digits)))
    }

    /// "12 MB/s": decimal units, two significant digits (see ``RateScale``).
    static func rate(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond else { return "—" }
        let shown = RateScale.displayed(bytesPerSecond)
        let number = shown.value.formatted(.number.precision(.fractionLength(shown.fractionDigits)))
        return "\(number) \(shown.unit)\(String(localized: "/sn"))"
    }

    /// Bytes in the same decimal units as ``rate(_:)``, for totals ("4,5 TB").
    static func bytesDecimal(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return Int64(clamping: value).formatted(.byteCount(style: .file))
    }

    static func integer(_ value: UInt64) -> String { Int64(clamping: value).formatted() }
}
