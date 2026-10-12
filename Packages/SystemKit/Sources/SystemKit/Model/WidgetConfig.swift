import Foundation

/// The ways a module can draw itself in the menu bar. A module can combine the ones it supports; they appear left to
/// right in `allCases` order. What each module supports is decided in one place, ``supported(by:)``.
public enum WidgetKind: String, CaseIterable, Codable, Identifiable, Sendable {
    /// The battery body with its fill and a bolt while charging.
    case battery
    /// A number: percent, degrees, time.
    case text
    /// Two lines with an arrow each: download over upload (network), read over write (disk).
    case arrows
    /// Filled history of the last minute.
    case chart
    /// Fill ring.
    case ring
    /// One bar per CPU core, or the app / wired / compressed split of memory.
    case bars
    /// A thin line of the last minute, few points.
    case sparkline

    public var id: Self { self }

    /// The widgets a module can draw. The Settings page lists exactly these, and a stored or imported
    /// configuration is cut down to them (``WidgetConfig/sanitized(for:)``), so an unsupported combination never exists.
    public static func supported(by module: ModuleID) -> [WidgetKind] {
        switch module {
        case .cpu, .ram: [.text, .chart, .ring, .bars, .sparkline]
        case .gpu, .sensors: [.text, .chart, .ring, .sparkline]
        // A speed has no fraction to fill a ring with; the disk's ring is its capacity.
        case .disk: [.arrows, .chart, .ring, .sparkline]
        case .network: [.arrows, .chart, .sparkline]
        // The battery changes on system events, so there is no minute of history to chart.
        case .battery: [.battery, .text, .ring]
        case .clock: [.text]
        default: []
        }
    }
}

public struct WidgetConfig: Codable, Equatable, Sendable {
    public var kinds: Set<WidgetKind>
    /// Small module name above the value ("CPU").
    public var showLabel: Bool

    public init(kinds: Set<WidgetKind>, showLabel: Bool) {
        self.kinds = kinds
        self.showLabel = showLabel
    }

    public static let `default` = WidgetConfig(kinds: [.text], showLabel: true)
    /// Battery and clock: the value alone, since the glyph or the digits say what it is.
    public static let plain = WidgetConfig(kinds: [.text], showLabel: false)

    /// What a module shows until the user chooses.
    public static func initial(for module: ModuleID) -> WidgetConfig {
        switch module {
        case .battery, .clock: .plain
        case .disk, .network: WidgetConfig(kinds: [.arrows], showLabel: false)
        default: .default
        }
    }

    public var orderedKinds: [WidgetKind] { WidgetKind.allCases.filter(kinds.contains) }

    /// Only what `module` supports; never empty. An old file that asked for a plain number on a speed module gets the arrows.
    public func sanitized(for module: ModuleID) -> WidgetConfig {
        let supported = Set(WidgetKind.supported(by: module))
        var kept = kinds
        if kept.contains(.text), !supported.contains(.text), supported.contains(.arrows) { kept.insert(.arrows) }
        kept.formIntersection(supported)
        if kept.isEmpty { kept = Self.initial(for: module).kinds }
        return WidgetConfig(kinds: kept, showLabel: showLabel)
    }

    private enum CodingKeys: String, CodingKey { case kinds, showLabel }

    /// Unknown kinds (a newer or hand-edited file) are skipped instead of failing the whole configuration.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let names = try container.decode([String].self, forKey: .kinds)
        kinds = Set(names.compactMap(WidgetKind.init(rawValue:)))
        showLabel = try container.decodeIfPresent(Bool.self, forKey: .showLabel) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(orderedKinds.map(\.rawValue), forKey: .kinds)
        try container.encode(showLabel, forKey: .showLabel)
    }

    /// Reads the stored map of module → configuration from JSON (as bytes or text), sanitized per module.
    /// Unknown modules and modules that cannot have a widget are dropped.
    public static func decodeMap(_ data: Data) -> [ModuleID: WidgetConfig]? {
        guard let decoded = try? JSONDecoder().decode([String: WidgetConfig].self, from: data) else { return nil }
        var result: [ModuleID: WidgetConfig] = [:]
        for (key, value) in decoded {
            guard let module = ModuleID(rawValue: key), !WidgetKind.supported(by: module).isEmpty else { continue }
            result[module] = value.sanitized(for: module)
        }
        return result
    }
}
