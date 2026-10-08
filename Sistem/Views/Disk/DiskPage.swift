import SistemUI
import SwiftUI
import SystemKit

struct DiskPage: View {
    @Bindable var settings: SettingsStore
    @State private var tab: ModuleTab

    init(settings: SettingsStore, tab: ModuleTab = .overview) {
        self.settings = settings
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ModulePageHeader(module: .disk, tab: $tab)
            switch tab {
            case .overview: DiskOverview()
            case .module: DiskModuleSettings(settings: settings)
            case .widgets: WidgetSettings(module: .disk, settings: settings)
            }
        }
    }
}

private struct DiskOverview: View {
    @Environment(LiveFeed.self) private var feed

    var body: some View {
        let _ = feed.frame
        let store = feed.store
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionLabel("Hız")
                        DiskThroughputSummary(sample: store.disk)
                        if let device = store.disk?.devices.first {
                            Text(verbatim: [device.name, device.bsdName].compactMap { $0 }.joined(separator: " · "))
                                .font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                }
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionLabel("Sağlık")
                        DiskHealthRows(health: store.diskHealth)
                    }
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            Card {
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel("Birimler")
                    DiskVolumeList(volumes: store.diskVolumes)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        SectionLabel("Geçmiş")
                        Spacer()
                        Text("Son \(feed.historyMinutes) dakika").font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
                    }
                    DiskHistory(store: store).frame(height: 150)
                    HStack(spacing: 16) {
                        LegendRow("Okuma", color: UsageColors.user, value: Format.rate(store.disk?.readRate))
                        LegendRow("Yazma", color: Palette.warning.opacity(0.55), value: Format.rate(store.disk?.writeRate))
                    }
                }
            }
        }
        .liveMetric(.disk)
        .liveMetric(.diskHealth)
    }
}

private struct DiskModuleSettings: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                MenuBarToggleRow(module: .disk, settings: settings)
                RowDivider()
                SettingRow("Menü çubuğu içeriği", detail: "Değer okuma ve yazma hızını, halka başlangıç biriminin doluluğunu gösterir. Widget'lar sekmesinden seçilir.") {
                    EmptyView()
                }
            }
        }
    }
}
