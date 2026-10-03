/// The ten monitoring modules, in sidebar order.
public enum ModuleID: String, CaseIterable, Codable, Identifiable, Sendable {
    case dashboard, cpu, gpu, ram, disk, sensors, network, battery, bluetooth, clock

    public var id: String { rawValue }

    /// What the menu bar shows on first launch: CPU, RAM and GPU as percentages,
    /// sensors as the hottest CPU temperature.
    public static let defaultMenuBar: [ModuleID] = [.cpu, .ram, .gpu, .sensors]
}
