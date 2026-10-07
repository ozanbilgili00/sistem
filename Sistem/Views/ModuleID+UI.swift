import SwiftUI
import SystemKit

extension ModuleID {
    var title: LocalizedStringResource {
        switch self {
        case .dashboard: "Gösterge paneli"
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .ram: "RAM"
        case .disk: "Disk"
        case .sensors: "Sensörler"
        case .network: "Ağ"
        case .battery: "Batarya"
        case .bluetooth: "Bluetooth"
        case .clock: "Saat"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .cpu: "cpu"
        case .gpu: "display"
        case .ram: "memorychip"
        case .disk: "internaldrive"
        case .sensors: "thermometer.medium"
        case .network: "network"
        case .battery: "battery.75percent"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .clock: "clock"
        }
    }

    /// The metric that drives this module's live views; nil until its phase lands.
    var metric: Metric? {
        switch self {
        case .cpu: .cpu
        case .gpu: .gpu
        case .ram: .memory
        default: nil
        }
    }

    /// The PLAN.md phase that brings this module to life.
    var phase: Int {
        switch self {
        case .cpu: 2
        case .ram: 3
        case .gpu: 4
        case .disk, .network: 5
        case .sensors: 6
        case .battery, .bluetooth, .clock: 7
        case .dashboard: 8
        }
    }

    var summary: LocalizedStringResource {
        switch self {
        case .dashboard: "Bu Mac'in donanımı, çalışma süresi ve tüm modüllerin özeti."
        case .cpu: "Toplam ve çekirdek başına yük, frekans, ortalama yük ve en çok CPU kullanan süreçler."
        case .gpu: "GPU, render ve tiler kullanımı, Neural Engine ve grafik gücü."
        case .ram: "Uygulama, bağlı, sıkıştırılmış bellek, takas, bellek baskısı ve en çok bellek kullanan süreçler."
        case .disk: "Birimler, doluluk, okuma ve yazma hızı."
        case .sensors: "Çekirdek sıcaklıkları, fan hızları ve güç tüketimi."
        case .network: "İndirme ve yükleme hızı, bağlantı durumu ve Wi-Fi bilgileri."
        case .battery: "Şarj, kalan süre, pil sağlığı, döngü sayısı ve adaptör."
        case .bluetooth: "Bağlı cihazlar ve pil seviyeleri."
        case .clock: "Birden çok saat dilimi ve takvim."
        }
    }

    /// Name in menu bar contexts: the sensors module shows a temperature there.
    var menuBarTitle: LocalizedStringResource {
        self == .sensors ? "Sıcaklık" : title
    }

    /// How this module reads out in the menu bar: temperatures in degrees, the rest
    /// as percentages.
    var menuBarUnit: LocalizedStringResource? {
        switch self {
        case .cpu, .gpu, .ram: "yüzde"
        case .sensors: "derece"
        default: nil
        }
    }
}
