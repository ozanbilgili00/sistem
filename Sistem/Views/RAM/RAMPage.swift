import SistemUI
import SwiftUI
import SystemKit

struct RAMPage: View {
    @Bindable var settings: SettingsStore
    @State private var tab: ModuleTab

    init(settings: SettingsStore, tab: ModuleTab = .overview) {
        self.settings = settings
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ModulePageHeader(module: .ram, tab: $tab)
            switch tab {
            case .overview: RAMOverview()
            case .module: RAMModuleSettings(settings: settings)
            case .widgets: WidgetSettings(module: .ram, settings: settings)
            }
        }
    }
}

private struct RAMOverview: View {
    @Environment(LiveFeed.self) private var feed

    var body: some View {
        let _ = feed.frame
        let sample = feed.store.memory
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionLabel("Kullanım")
                        RAMUsageSummary(sample: sample)
                    }
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                }
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionLabel("Durum")
                        RAMStatusRows(sample: sample)
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
                    RAMHistory(store: feed.store).frame(height: 150)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel("En çok bellek kullananlar")
                    ProcessList(ranking: .memory, limit: 10, detailed: true)
                }
            }
        }
        .liveMetric(.memory)
    }
}

private struct RAMModuleSettings: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                MenuBarToggleRow(module: .ram, settings: settings)
                RowDivider()
                SettingRow("Süreçleri göster", detail: "Açılır pencerede en çok bellek kullanan 5 süreç.") {
                    Toggle("Süreçleri göster", isOn: $settings.ramShowProcesses).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }
}
