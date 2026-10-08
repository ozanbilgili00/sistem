import Foundation

/// How the sensors menu bar item reads out: the user's unit and whether it shows the
/// GPU under the CPU.
struct SensorsDisplay: Equatable {
    var unit: SettingsStore.TemperatureUnit = .celsius
    var stacked = false
}

/// Temperatures on the menu bar's 0...1 scale (ring fill, chart height, hysteresis):
/// 30 °C is empty, 100 °C is full.
enum SensorScale {
    static let low: Float = 30
    static let high: Float = 100
    /// One degree, as a fraction.
    static let degree: Float = 1 / (high - low)

    static func fraction(_ celsius: Float) -> Float { max(0, min(1, (celsius - low) / (high - low))) }
    static func celsius(_ fraction: Float) -> Float { fraction * (high - low) + low }
}
