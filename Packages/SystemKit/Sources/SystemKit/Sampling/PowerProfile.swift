/// How much the user lets the sampler slow down (PLAN.md Faz 8).
///
/// `automatic` is the behaviour before profiles existed: the "slow down on battery"
/// switch decides. The other two ignore that switch.
public enum PowerProfile: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Slow down on battery, in Low Power Mode and when hot, if the user allows it.
    case automatic
    /// Always at least twice the interval; four times on battery or in Low Power Mode.
    case saver
    /// Never slow down for battery or Low Power Mode; only a hot Mac still does.
    case precise

    public var id: String { rawValue }

    /// Factor applied to the user's base interval.
    public func multiplier(for state: PowerPolicy.State, slowDownOnBattery: Bool) -> Double {
        switch self {
        case .automatic: PowerPolicy.multiplier(for: state, slowDownOnBattery: slowDownOnBattery)
        case .saver: PowerPolicy.multiplier(for: state, slowDownOnBattery: true) * 2
        case .precise: PowerPolicy.multiplier(for: state, slowDownOnBattery: false)
        }
    }
}
