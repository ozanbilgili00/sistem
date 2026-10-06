import Foundation

/// The ways a module can draw itself in the menu bar. A module can combine them;
/// they appear left to right in `allCases` order.
enum WidgetKind: String, CaseIterable, Codable, Identifiable {
    case text, chart, ring
    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .text: "Değer"
        case .chart: "Mini grafik"
        case .ring: "Halka"
        }
    }

    var detail: LocalizedStringResource {
        switch self {
        case .text: "Yüzde ya da derece olarak sayı."
        case .chart: "Son bir dakikanın çizgisi."
        case .ring: "Doluluk halkası."
        }
    }
}

struct WidgetConfig: Codable, Equatable {
    var kinds: Set<WidgetKind>
    /// Small module name above the value ("CPU").
    var showLabel: Bool

    static let `default` = WidgetConfig(kinds: [.text], showLabel: true)

    var orderedKinds: [WidgetKind] { WidgetKind.allCases.filter(kinds.contains) }
}
