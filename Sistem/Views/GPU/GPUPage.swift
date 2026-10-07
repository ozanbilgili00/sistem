import SistemUI
import SwiftUI
import SystemKit

struct GPUPage: View {
    @Bindable var settings: SettingsStore
    @State private var tab: ModuleTab

    init(settings: SettingsStore, tab: ModuleTab = .overview) {
        self.settings = settings
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ModulePageHeader(module: .gpu, tab: $tab)
            switch tab {
            case .overview: GPUOverview()
            case .module: GPUModuleSettings(settings: settings)
            case .widgets: WidgetSettings(module: .gpu, settings: settings)
            }
        }
    }
}

private struct GPUOverview: View {
    @Environment(LiveFeed.self) private var feed
    @State private var hardware = HardwareInfo.current()

    var body: some View {
        let _ = feed.frame
        let sample = feed.store.gpu
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionLabel("Kullanım")
                        GPUUsageSummary(sample: sample)
                    }
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                }
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionLabel("Bellek")
                        GPUMemoryRows(sample: sample, total: hardware.memoryBytes)
                    }
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel("Güç")
                    PowerRows(power: feed.store.power, rows: [.gpu, .ane, .system])
                    Text("Neural Engine için kullanım yüzdesi sistemde yayımlanmıyor; yalnızca harcadığı güç okunabiliyor.")
                        .font(.sistemCaption)
                        .foregroundStyle(Palette.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        SectionLabel("Geçmiş")
                        Spacer()
                        Text("Son \(feed.historyMinutes) dakika").font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
                    }
                    GPUHistory(store: feed.store).frame(height: 150)
                }
            }
        }
        .liveMetric(.gpu)
        .liveMetric(.power)
    }
}

private struct GPUModuleSettings: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                MenuBarToggleRow(module: .gpu, settings: settings)
                RowDivider()
                SettingRow("Gücü göster", detail: "Açılır pencerede GPU ve Neural Engine gücü.") {
                    Toggle("Gücü göster", isOn: $settings.gpuShowPower).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }
}
