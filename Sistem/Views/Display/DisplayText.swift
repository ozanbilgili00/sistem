import SwiftUI
import SystemKit

/// Wording shared by the page, the popover and the log.
enum DisplayText {
    /// The display's own name, or a generic one when macOS gave none (Sidecar, some adapters).
    static func name(_ info: DisplayInfo) -> String {
        if !info.name.isEmpty { return info.name }
        return info.isBuiltIn ? String(localized: "Dahili ekran") : String(localized: "Harici ekran")
    }

    static func resolution(_ mode: DisplayMode?) -> String {
        mode.map { "\($0.width) × \($0.height)" } ?? "—"
    }

    static func pixels(_ mode: DisplayMode?) -> String {
        mode.map { "\($0.pixelWidth) × \($0.pixelHeight)" } ?? "—"
    }

    static func refresh(_ mode: DisplayMode?) -> String {
        guard let mode, mode.refreshRate > 0 else { return "—" }
        return "\(Int(mode.refreshRate.rounded())) Hz"
    }

    static func scale(_ mode: DisplayMode?) -> String {
        guard let mode else { return "—" }
        return mode.scale == mode.scale.rounded() ? "\(Int(mode.scale))×" : String(format: "%.1f×", mode.scale)
    }

    static func size(_ size: DisplayModeCatalog.Size) -> String {
        size.isHiDPI ? "\(size.width) × \(size.height) HiDPI" : "\(size.width) × \(size.height)"
    }

    static func hdr(_ info: DisplayInfo) -> String {
        guard info.supportsHDR else { return String(localized: "Desteklemiyor") }
        let headroom = String(format: "%.1f×", info.edrCurrent)
        return info.isShowingHDR ? String(localized: "Etkin, \(headroom)") : String(localized: "Destekliyor, şu an kapalı")
    }

    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded())) %" }

    static func control(_ control: VCPControl) -> LocalizedStringKey {
        switch control {
        case .brightness: "Parlaklık"
        case .contrast: "Kontrast"
        case .volume: "Ses"
        case .inputSource: "Giriş"
        }
    }

    static func controlSymbol(_ control: VCPControl) -> String {
        switch control {
        case .brightness: "sun.max"
        case .contrast: "circle.lefthalf.filled"
        case .volume: "speaker.wave.2"
        case .inputSource: "cable.connector"
        }
    }

    static func unsupported(_ reason: DDCUnsupportedReason) -> LocalizedStringKey {
        switch reason {
        case .builtIn: "Dahili ekranın parlaklığı sistem tarafından yönetilir; buradan yalnızca okunur."
        case .noChannel: "Bu ekran için donanım denetimi (DDC) bulunamadı. Sidecar, DisplayLink, bazı yuva ve HDMI bağlantıları DDC iletmez. Yazılımsal karartma yine çalışır."
        case .noAnswer: "Monitör DDC isteklerine yanıt vermiyor. DDC/CI monitörün menüsünde kapalı olabilir. Yazılımsal karartma yine çalışır."
        }
    }

    static func eventTitle(_ kind: DisplayEventKind) -> LocalizedStringKey {
        switch kind {
        case .connected: "Bağlandı"
        case .disconnected: "Çıkarıldı"
        case .modeChanged: "Mod değişti"
        case .layoutChanged: "Düzen değişti"
        case .modeReverted: "Eski moda dönüldü"
        }
    }

    static func eventSymbol(_ kind: DisplayEventKind) -> String {
        switch kind {
        case .connected: "plus.circle"
        case .disconnected: "minus.circle"
        case .modeChanged: "arrow.triangle.2.circlepath"
        case .layoutChanged: "rectangle.3.group"
        case .modeReverted: "arrow.uturn.backward"
        }
    }
}
