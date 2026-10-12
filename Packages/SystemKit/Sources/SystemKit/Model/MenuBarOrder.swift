import Foundation

/// The order of the sections in the menu bar strip. Every section the strip can hold has a place here, shown or not, so a
/// section that is switched off and on again returns to where it was. Pure and testable; the app stores it under
/// ``defaultsKey`` and in the exported settings file.
public enum MenuBarOrder {
    public static let defaultsKey = "menuBarOrder"

    /// Every section, in the order of a fresh install: the module widgets, then the cup, the display and the servers.
    public static let allSections: [ModuleID] = ModuleID.menuBarCandidates + [.keepAwake, .display, .servers]

    /// A stored order made valid: unknown names, names that are no section and repeats are dropped (the first one counts),
    /// and sections the list lacks are added at their default places, so a section a newer build adds still appears.
    public static func sanitized(_ raw: [String]) -> [ModuleID] {
        var seen = Set<ModuleID>()
        var order: [ModuleID] = []
        for name in raw {
            guard let section = ModuleID(rawValue: name), allSections.contains(section), seen.insert(section).inserted else { continue }
            order.append(section)
        }
        for section in allSections where !seen.contains(section) {
            // Right after the section that precedes it by default, if that is in the list; at the end otherwise.
            let defaultIndex = allSections.firstIndex(of: section) ?? 0
            let anchor = allSections[..<defaultIndex].reversed().compactMap { order.firstIndex(of: $0) }.first
            order.insert(section, at: anchor.map { $0 + 1 } ?? 0)
            seen.insert(section)
        }
        return order
    }

    /// The sections of `visible`, in `order`.
    public static func arranged(_ visible: [ModuleID], by order: [ModuleID]) -> [ModuleID] {
        order.filter(visible.contains)
    }

    /// `section` one place earlier (or later) among the sections that are shown. Hidden sections keep their relative places.
    public static func moved(_ section: ModuleID, up: Bool, in order: [ModuleID], visible: [ModuleID]) -> [ModuleID] {
        let shown = arranged(visible, by: order)
        guard let position = shown.firstIndex(of: section) else { return order }
        let neighbour = up ? position - 1 : position + 1
        guard shown.indices.contains(neighbour), let from = order.firstIndex(of: section), let to = order.firstIndex(of: shown[neighbour]) else { return order }
        var result = order
        result.swapAt(from, to)
        return result
    }

    public static func load(from defaults: UserDefaults) -> [ModuleID] {
        sanitized(defaults.stringArray(forKey: defaultsKey) ?? [])
    }

    public static func save(_ order: [ModuleID], to defaults: UserDefaults) {
        defaults.set(order.map(\.rawValue), forKey: defaultsKey)
    }
}
