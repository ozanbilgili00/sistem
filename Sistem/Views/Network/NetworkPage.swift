import SistemUI
import SwiftUI
import SystemKit

struct NetworkPage: View {
    @Bindable var settings: SettingsStore
    @State private var tab: ModuleTab

    init(settings: SettingsStore, tab: ModuleTab = .overview) {
        self.settings = settings
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ModulePageHeader(module: .network, tab: $tab)
            switch tab {
            case .overview: NetworkOverview()
            case .module: NetworkModuleSettings(settings: settings)
            case .widgets: WidgetSettings(module: .network, settings: settings)
            }
        }
    }
}

private struct NetworkOverview: View {
    @Environment(LiveFeed.self) private var feed
    /// Created only with this page; reading the status never prompts.
    @State private var location = LocationModel()

    var body: some View {
        let _ = feed.frame
        let store = feed.store
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionLabel("Hız")
                        NetworkThroughputSummary(sample: store.network)
                    }
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                }
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionLabel("Bağlantı")
                        ConnectionSummary(path: store.path)
                        let extras = NetworkExtrasRows(publicIP: store.publicIP, latency: store.latency)
                        if !extras.isEmpty { extras }
                    }
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        SectionLabel("Geçmiş")
                        Spacer()
                        Text("Son \(feed.historyMinutes) dakika").font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
                    }
                    NetworkHistory(store: store).frame(height: 150)
                    HStack(spacing: 16) {
                        LegendRow("İndirme", color: UsageColors.user, value: Format.rate(store.network?.down))
                        LegendRow("Yükleme", color: Palette.warning.opacity(0.55), value: Format.rate(store.network?.up))
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel("Arayüzler")
                    InterfaceList(sample: store.network, addresses: store.networkInfo?.addresses ?? [], path: store.path)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel("Kablosuz ağ")  // "Wi-Fi" would uppercase to "Wİ-Fİ" in Turkish
                    WiFiCardContent(wifi: store.networkInfo?.wifi, location: location.state, requestLocation: location.request)
                }
            }

            DiagnosticsCard()

            Card {
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel("Bağlantı geçmişi")
                    ConnectionHistoryList(events: store.connectionEvents)
                }
            }
        }
        .liveMetric(.network)
        .liveMetric(.networkInfo)
    }
}

/// Wraps ``LocationAccess`` for SwiftUI. Nothing prompts until `request()`.
@MainActor @Observable
final class LocationModel {
    private(set) var state: LocationAccess.State
    @ObservationIgnored private let access: LocationAccess?

    /// `fixed` is for snapshots: no CoreLocation object at all.
    init(fixed: LocationAccess.State? = nil) {
        if let fixed {
            access = nil
            state = fixed
        } else {
            let access = LocationAccess()
            self.access = access
            state = access.state
            access.onChange = { [weak self] in self?.state = access.state }
        }
    }

    func request() { access?.request() }
}

private struct NetworkModuleSettings: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                MenuBarToggleRow(module: .network, settings: settings)
                RowDivider()
                SettingRow("Genel IP adresini göster",
                           detail: "Bağlantı her değiştiğinde api.ipify.org'a tek bir istek gönderir. Kapalıyken uygulama hiçbir dış istek yapmaz.") {
                    Toggle("Genel IP adresini göster", isOn: $settings.networkPublicIP).labelsHidden().toggleStyle(.switch)
                }
                RowDivider()
                SettingRow("Gecikmeyi ölç",
                           detail: "Ağ ekranı ya da menü çubuğu öğesi görünürken ve prize takılıyken 60 saniyede bir 1.1.1.1'e bağlantı süresini ölçer.") {
                    Toggle("Gecikmeyi ölç", isOn: $settings.networkLatency).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }
}
