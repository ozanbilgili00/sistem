/// The ten monitoring modules, in sidebar order.
public enum ModuleID: String, CaseIterable, Codable, Identifiable, Sendable {
    case dashboard, cpu, gpu, ram, disk, sensors, network, battery, bluetooth, clock

    public var id: String { rawValue }

    /// Modules that can have a menu bar item, in the order Settings lists them.
    public static let menuBarCandidates: [ModuleID] = [.cpu, .ram, .gpu, .disk, .network, .sensors]

    /// What the menu bar shows on first launch. Every item costs idle wakeups (each
    /// redraw is rendered once per display), so GPU is opt-in: on this Mac it adds
    /// ~0.5 wakeups/s and pushes three items to the 2/s budget (2026-10-07). Disk and
    /// network are opt-in for the same reason.
    public static let defaultMenuBar: [ModuleID] = [.cpu, .ram, .sensors]
}
