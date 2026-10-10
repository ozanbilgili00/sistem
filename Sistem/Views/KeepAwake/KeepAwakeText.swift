import SwiftUI
import SystemKit

/// Wording shared by the page, the popover and the menu.
enum KeepAwakeText {
    static func durationMenuTitle(_ seconds: Double) -> String {
        switch seconds {
        case 1_800: String(localized: "30 dakika")
        case 3_600: String(localized: "1 saat")
        case 10_800: String(localized: "3 saat")
        case 28_800: String(localized: "8 saat")
        default: String(localized: "Süresiz")
        }
    }

    static func durationShort(_ seconds: Double) -> LocalizedStringKey {
        switch seconds {
        case 1_800: "30 dk"
        case 3_600: "1 sa"
        case 10_800: "3 sa"
        case 28_800: "8 sa"
        default: "Süresiz"
        }
    }

    /// "42 dk kalan", "2 sa 5 dk kalan", "1 dk'dan az kalan".
    static func remaining(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 1 { return String(localized: "1 dakikadan az kaldı") }
        if minutes < 60 { return String(localized: "\(minutes) dk kaldı") }
        return String(localized: "\(minutes / 60) sa \(minutes % 60) dk kaldı")
    }

    static func name(_ trigger: AwakeTrigger) -> LocalizedStringResource {
        switch trigger {
        case .aiTools: "Yapay zekâ araçları"
        case .build: "Derleme ve Docker"
        case .network: "Büyük ağ trafiği"
        case .charging: "Şarjdayken"
        }
    }

    static func detail(_ trigger: AwakeTrigger) -> LocalizedStringKey {
        switch trigger {
        case .aiTools: "claude, codex, cursor-agent veya ollama çalışırken."
        case .build: "xcodebuild, swift-build veya docker çalışırken."
        case .network: "İndirme ve yükleme toplamı eşiği aştığında."
        case .charging: "Mac prize takılıyken."
        }
    }

    static func protectionTitle(_ reason: ProtectionReason) -> String {
        switch reason {
        case .battery: String(localized: "Pil azaldı")
        case .thermalState: String(localized: "Mac çok ısındı")
        case .temperature: String(localized: "Sıcaklık yüksek")
        }
    }

    static func protectionBody(_ reason: ProtectionReason) -> String {
        switch reason {
        case .battery: String(localized: "Şarj yüzde 15 ve altına indi. Mac'in uyumasına izin verildi.")
        case .thermalState: String(localized: "Sistem ısınma durumunu ciddi olarak bildiriyor. Mac'in uyumasına izin verildi.")
        case .temperature: String(localized: "En sıcak sensör 60 saniyedir 90 °C ve üstünde. Mac'in uyumasına izin verildi.")
        }
    }

    static func protectionLine(_ reason: ProtectionReason) -> LocalizedStringKey {
        switch reason {
        case .battery: "Pil yüzde 15 ve altında: uyanık tutma durduruldu."
        case .thermalState: "Mac çok ısındı: uyanık tutma durduruldu."
        case .temperature: "Sıcaklık 90 °C üstü: uyanık tutma durduruldu. 75 °C altına inince yeniden izin verilir."
        }
    }

    static func megabytes(_ bytesPerSecond: Double) -> String {
        String(localized: "\(Int(bytesPerSecond / 1_000_000)) MB/sn")
    }
}
