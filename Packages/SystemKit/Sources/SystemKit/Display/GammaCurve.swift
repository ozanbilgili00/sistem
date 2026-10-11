import Foundation

/// Per-channel transfer tables for ``GammaBackend``: software dimming and the night tone.
public struct GammaTable: Sendable, Equatable {
    public var red: [Float]
    public var green: [Float]
    public var blue: [Float]

    public static let size = 256
}

public enum GammaCurve {
    /// Dimming never goes below this: a screen at zero can not be found again.
    public static let minimumDim: Float = 0.1
    /// Channel gains at full night tone: red untouched, blue cut hard (about 2700 K).
    public static let nightGains: (red: Float, green: Float, blue: Float) = (1.0, 0.82, 0.55)

    /// Linear ramp scaled per channel. `dim` 1 and `warmth` 0 give the identity table.
    public static func table(dim: Float, warmth: Float) -> GammaTable {
        let dim = min(1, max(minimumDim, dim.isFinite ? dim : 1))
        let warmth = min(1, max(0, warmth.isFinite ? warmth : 0))
        func gain(_ night: Float) -> Float { dim * (1 - warmth * (1 - night)) }
        let gains = (red: gain(nightGains.red), green: gain(nightGains.green), blue: gain(nightGains.blue))
        func ramp(_ gain: Float) -> [Float] {
            (0..<GammaTable.size).map { Float($0) / Float(GammaTable.size - 1) * gain }
        }
        return GammaTable(red: ramp(gains.red), green: ramp(gains.green), blue: ramp(gains.blue))
    }
}
