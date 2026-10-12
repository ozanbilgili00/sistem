import Foundation
import SystemKit

/// Names for the Settings page. Which kinds a module supports lives in SystemKit (``WidgetKind/supported(by:)``).
extension WidgetKind {
    func title(for module: ModuleID) -> LocalizedStringResource {
        switch self {
        case .text: "Değer"
        case .chart: "Mini grafik"
        case .ring: "Halka"
        case .bars: module == .cpu ? "Çekirdek çubukları" : "Çubuklar"
        case .sparkline: "Çizgi grafik"
        case .battery: "Pil simgesi"
        case .arrows: module == .disk ? "Okuma ve yazma okları" : "Ağ okları"
        }
    }

    func detail(for module: ModuleID) -> LocalizedStringResource {
        switch self {
        case .text: "Yüzde ya da derece olarak sayı."
        case .chart: "Son bir dakikanın dolu grafiği."
        case .ring: "Doluluk halkası."
        case .bars: module == .cpu ? "Her çekirdek için bir çubuk." : "Uygulama, bağlı ve sıkıştırılmış bellek için üç çubuk."
        case .sparkline: "Son bir dakikanın ince çizgisi."
        case .battery: "Dolum düzeyi ve şarj göstergesi."
        case .arrows: module == .disk ? "Okuma ve yazma hızı, iki satır." : "İndirme ve yükleme hızı, iki satır."
        }
    }
}
