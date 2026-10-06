import SistemUI
import SwiftUI
import SystemKit

struct CPUPage: View {
    @Bindable var settings: SettingsStore
    @State private var tab: ModuleTab

    init(settings: SettingsStore, tab: ModuleTab = .overview) {
        self.settings = settings
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ModulePageHeader(module: .cpu, tab: $tab)
            switch tab {
            case .overview: CPUOverview()
            case .module: CPUModuleSettings(settings: settings)
            case .widgets: WidgetSettings(module: .cpu, settings: settings)
            }
        }
    }
}

private struct CPUOverview: View {
    @Environment(LiveFeed.self) private var feed
    @State private var hardware = HardwareInfo.current()

    var body: some View {
        let _ = feed.frame
        let sample = feed.store.cpu
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionLabel("Kullanım")
                        CPUUsageSummary(sample: sample)
                    }
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                }
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionLabel("Ortalama yük")
                        LoadAverageRow(load: sample?.loadAverage)
                        RowDivider().padding(.leading, -16)
                        HStack {
                            Text("Çekirdekler").font(.sistemBody).foregroundStyle(Palette.inkSecondary)
                            Spacer()
                            Text(verbatim: hardware.clusters.map { "\($0.count) \($0.name)" }.joined(separator: " · "))
                                .font(.sistemValue).foregroundStyle(Palette.ink)
                        }
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
                    CPUHistory(store: feed.store).frame(height: 150)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel("Çekirdek başına")
                    CPUCoreGroups(sample: sample, clusters: hardware.clusters)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel("En çok CPU kullananlar")
                    ProcessList(ranking: .cpu, limit: 10, detailed: true)
                }
            }
        }
        .liveMetric(.cpu)
    }
}

private struct CPUModuleSettings: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                MenuBarToggleRow(module: .cpu, settings: settings)
                RowDivider()
                SettingRow("Çekirdekleri göster", detail: "Açılır pencerede çekirdek başına çubuklar.") {
                    Toggle("Çekirdekleri göster", isOn: $settings.cpuShowCores).labelsHidden().toggleStyle(.switch)
                }
                RowDivider()
                SettingRow("Ortalama yükü göster", detail: "Açılır pencerede 1, 5 ve 15 dakikalık ortalama.") {
                    Toggle("Ortalama yükü göster", isOn: $settings.cpuShowLoadAverage).labelsHidden().toggleStyle(.switch)
                }
                RowDivider()
                SettingRow("Süreçleri göster", detail: "Açılır pencerede en çok CPU kullanan 5 süreç.") {
                    Toggle("Süreçleri göster", isOn: $settings.cpuShowProcesses).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }
}
