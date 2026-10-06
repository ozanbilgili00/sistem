import Foundation

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

    static func decimal(_ value: Double, digits: Int = 2) -> String {
        value.formatted(.number.precision(.fractionLength(digits)))
    }
}
