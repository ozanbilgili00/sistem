import SwiftUI
import SystemKit

extension AlertKind {
    var title: LocalizedStringResource {
        switch self {
        case .cpuLoad: "CPU yükü"
        case .memoryPressure: "Bellek baskısı"
        case .cpuTemperature: "CPU sıcaklığı"
        case .diskFree: "Boş disk alanı"
        case .batteryLow: "Pil seviyesi"
        case .networkDown: "Ağ bağlantısı"
        }
    }

    var summary: LocalizedStringResource {
        switch self {
        case .cpuLoad: "CPU kullanımı eşiğin üstünde kalırsa."
        case .memoryPressure: "macOS bellek baskısını yükseltirse."
        case .cpuTemperature: "En sıcak çekirdek eşiği aşarsa."
        case .diskFree: "Başlangıç diskinde boş alan eşiğin altına inerse."
        case .batteryLow: "Pilde çalışırken şarj eşiğin altına inerse."
        case .networkDown: "Bağlantı kesilir ve geri gelmezse."
        }
    }

    var thresholdTitle: LocalizedStringResource { self == .memoryPressure ? "Düzey" : "Eşik" }

    /// A threshold choice as the picker shows it. Temperatures follow the user's unit.
    func label(forThreshold value: Double, unit: SettingsStore.TemperatureUnit) -> Text {
        switch self.unit {
        case .percent: Text(verbatim: "%\(Int(value))")
        case .celsius: Text(verbatim: "\(Int(unit.convert(Float(value)).rounded()))\(unit.symbol)")
        case .gigabytes: Text(verbatim: "\(Int(value)) GB")
        case .pressure: value >= 4 ? Text("Kritik") : Text("Uyarı")
        case .none: Text(verbatim: "")
        }
    }

    static func label(forDuration seconds: Double) -> Text {
        seconds >= 60 ? Text("\(Int(seconds / 60)) dk") : Text("\(Int(seconds)) sn")
    }
}

extension PowerProfile {
    var title: LocalizedStringResource {
        switch self {
        case .automatic: "Otomatik"
        case .saver: "Pil tasarrufu"
        case .precise: "Hassas"
        }
    }

    var detail: LocalizedStringResource {
        switch self {
        case .automatic: "Pilde ve Düşük Güç Modu'nda aralık uzar; aşağıdaki anahtar bunu kapatabilir."
        case .saver: "Her zaman en az iki kat seyrek ölçer; pilde dört kat."
        case .precise: "Pilde bile yavaşlamaz. Yalnızca Mac aşırı ısınırsa seyrekleşir."
        }
    }
}
