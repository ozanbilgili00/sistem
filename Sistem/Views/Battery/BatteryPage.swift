import SistemUI
import SwiftUI
import SystemKit

struct BatteryPage: View {
    @Bindable var settings: SettingsStore
    @State private var tab: ModuleTab

    init(settings: SettingsStore, tab: ModuleTab = .overview) {
        self.settings = settings
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ModulePageHeader(module: .battery, tab: $tab)
            switch tab {
            case .overview: BatteryOverview(settings: settings)
            case .module: BatteryModuleSettings(settings: settings)
            case .widgets: WidgetSettings(module: .battery, settings: settings)
            }
        }
    }
}

private struct BatteryOverview: View {
    let settings: SettingsStore
    @Environment(LiveFeed.self) private var feed

    var body: some View {
        let _ = feed.frame
        let status = feed.store.battery
        VStack(alignment: .leading, spacing: 14) {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel("Şarj")
                    BatteryChargeSummary(status: status)
                }
            }
            if let sample = status?.sample {
                HStack(alignment: .top, spacing: 14) {
                    Card {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionLabel("Sağlık")
                            BatteryHealthRows(health: sample.health)
                        }
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionLabel("Elektrik")
                            BatteryElectricRows(health: sample.health, unit: settings.temperatureUnit)
                        }
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                if let adapter = sample.adapter {
                    Card {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionLabel("Adaptör")
                            BatteryAdapterRows(adapter: adapter)
                        }
                    }
                }
                Text("Yüzde, durum ve kalan süre sistem bildirimiyle gelir; sürekli okunmaz. Elektrik değerleri 30 saniyede bir yenilenir.")
                    .font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
            }
        }
        .liveMetric(.battery)
    }
}

private struct BatteryModuleSettings: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Card(padding: 0) {
                MenuBarToggleRow(module: .battery, settings: settings)
            }
            Text("Yüzde ve kalan süre macOS'un kendi güç kaynağı bilgisinden alınır; bu yüzden sistemin gösterdiğiyle aynıdır.")
                .font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
        }
    }
}
