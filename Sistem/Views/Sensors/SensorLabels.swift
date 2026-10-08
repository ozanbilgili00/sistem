import Foundation
import SystemKit

extension SensorInfo {
    /// The name shown in lists. A Mac whose key names aren't verified shows the SMC key itself.
    var title: String {
        switch label {
        case .raw(let key): key
        case .named(let base): base.title
        case .indexed(let base, let index): base.title(index: index)
        }
    }
}

extension SensorLabelBase {
    var title: String {
        switch self {
        case .socCPUHottest: String(localized: "SoC CPU bölgesi (en sıcak)")
        case .socHotspot: String(localized: "SoC en sıcak nokta")
        case .dcIn: String(localized: "DC girişi")
        case .batteryPack: String(localized: "Batarya paketi")
        case .system: String(localized: "Sistem toplamı")
        case .adapter: String(localized: "Adaptör girişi")
        case .cpu: "CPU"
        default: title(index: 1)
        }
    }

    /// The Nth sensor of a family. Numbered in key order: the SMC doesn't say which
    /// physical core a sensor belongs to.
    func title(index n: Int) -> String {
        switch self {
        case .superCore: String(localized: "Super sensörü \(n)")
        case .performanceCore: String(localized: "Performance sensörü \(n)")
        case .gpuUnit: String(localized: "GPU sensörü \(n)")
        case .socCPU: String(localized: "SoC CPU bölgesi \(n)")
        case .socRegionA: String(localized: "SoC bölgesi A-\(n)")
        case .socRegionB: String(localized: "SoC bölgesi B-\(n)")
        case .battery: String(localized: "Batarya sensörü \(n)")
        case .nand: String(localized: "SSD sensörü \(n)")
        case .fan: String(localized: "Fan \(n)")
        default: title
        }
    }
}

extension SensorGroup {
    var title: LocalizedStringResource {
        switch self {
        case .cpuSuper: "CPU · Super çekirdekler"
        case .cpuPerformance: "CPU · Performance çekirdekler"
        case .gpu: "GPU"
        case .memory: "Bellek"
        case .soc: "SoC"
        case .ssd: "SSD"
        case .battery: "Batarya"
        case .other: "Diğer sensörler"
        }
    }
}
