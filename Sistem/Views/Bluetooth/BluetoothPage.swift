import SistemUI
import SwiftUI
import SystemKit

struct BluetoothPage: View {
    @Bindable var settings: SettingsStore
    @State private var tab: ModuleTab

    init(settings: SettingsStore, tab: ModuleTab = .overview) {
        self.settings = settings
        _tab = State(initialValue: tab == .widgets ? .overview : tab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ModulePageHeader(module: .bluetooth, tab: $tab, showsWidgets: false)
            switch tab {
            case .overview, .widgets: BluetoothOverview()
            case .module: BluetoothModuleSettings(settings: settings)
            }
        }
    }
}

private struct BluetoothOverview: View {
    @Environment(LiveFeed.self) private var feed

    var body: some View {
        let _ = feed.frame
        let sample = feed.store.bluetooth
        VStack(alignment: .leading, spacing: 14) {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        SectionLabel("Cihazlar")
                        Spacer()
                        if let on = sample?.isPoweredOn {
                            if on { Pill(Text("Açık"), tone: .good) } else { Pill(Text("Kapalı"), tone: .neutral) }
                        }
                    }
                    BluetoothDeviceList(sample: sample)
                }
            }
            Text("Cihaz listesi ve pil seviyeleri 60 saniyede bir yenilenir ve yalnızca bu sayfa ya da açılır pencere görünürken okunur.")
                .font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
        }
        .liveMetric(.bluetooth)
    }
}

private struct BluetoothModuleSettings: View {
    let settings: SettingsStore
    @State private var access = BluetoothAccess.current

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Card(padding: 0) { MenuBarToggleRow(module: .bluetooth, settings: settings) }
            Card(padding: 0) {
                SettingRow(Text("Bluetooth izni"), detail: Text(detail)) {
                    HStack(spacing: 10) {
                        Pill(Text(statusName), tone: access == .allowed ? .good : access == .notDetermined ? .neutral : .warning)
                        switch access {
                        case .notDetermined:
                            Button("İzin iste") {
                                BluetoothAccess.request()
                                // The prompt answers a moment later; look again when it has.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { access = .current }
                            }
                            .buttonStyle(AccentButtonStyle())
                        case .denied:
                            Button("Sistem Ayarları") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(QuietButtonStyle())
                        default:
                            EmptyView()
                        }
                    }
                }
            }
            Text("İzin olmadan da cihazlar, bağlantı durumu ve pil seviyeleri listelenir. İzin verilirse bağlantı durumu doğrudan sistemden de okunur.")
                .font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
        }
        .onAppear { access = .current }
    }

    private var statusName: LocalizedStringKey {
        switch access {
        case .allowed: "Verildi"
        case .notDetermined: "Sorulmadı"
        case .denied: "Reddedildi"
        case .restricted: "Kısıtlı"
        }
    }

    private var detail: LocalizedStringResource {
        switch access {
        case .allowed: "Bağlantı durumu sistemden doğrudan okunuyor."
        case .notDetermined: "Henüz sorulmadı. Düğmeye basınca macOS izin ister."
        case .denied: "Reddedildi. Dilerseniz Sistem Ayarları > Gizlilik ve Güvenlik > Bluetooth'tan açabilirsiniz."
        case .restricted: "Bu Mac'te Bluetooth izni kısıtlı."
        }
    }
}
