import SistemUI
import SwiftUI
import SystemKit

struct KeepAwakePage: View {
    @Bindable var settings: SettingsStore
    @State private var tab: ModuleTab

    init(settings: SettingsStore, tab: ModuleTab = .overview) {
        self.settings = settings
        _tab = State(initialValue: tab == .widgets ? .overview : tab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ModulePageHeader(module: .keepAwake, tab: $tab, showsWidgets: false)
            switch tab {
            case .overview, .widgets: KeepAwakeOverview(settings: settings)
            case .module: KeepAwakeModuleSettings(settings: settings)
            }
        }
    }
}

private struct KeepAwakeOverview: View {
    let settings: SettingsStore
    @Environment(LiveFeed.self) private var feed
    @Environment(KeepAwakeModel.self) private var model

    var body: some View {
        let _ = feed.frame  // also moves the remaining time along
        let state = model.state
        VStack(alignment: .leading, spacing: 14) {
            Card {
                VStack(alignment: .leading, spacing: 16) {
                    SectionLabel("Durum")
                    KeepAwakeStatusSummary(state: state, enabled: settings.keepAwakeEnabled, remaining: model.remaining())
                    KeepAwakeControls(state: state, enabled: settings.keepAwakeEnabled,
                                      start: { model.start(duration: $0 > 0 ? $0 : nil) }, stop: model.stop)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionLabel("Neden uyanık?")
                        AwakeHolderList(sample: feed.store.assertions)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionLabel("Tetikleyiciler")
                        AwakeTriggerSummary(state: state, config: model.config)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Text("Liste, sistemin uyku engellerini (pmset -g assertions ile aynı kaynak) gösterir; yalnızca bu sayfa ya da açılır pencere görünürken birkaç saniyede bir okunur.")
                .font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
        }
        .liveMetric(.assertions)
    }
}

private struct KeepAwakeModuleSettings: View {
    @Bindable var settings: SettingsStore
    @Environment(AlertNotifier.self) private var notifier

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Card(padding: 0) {
                VStack(spacing: 0) {
                    SettingRow("Uyanık Tut'u etkinleştir", detail: "Menü çubuğuna bir fincan simgesi ekler. Kapalıyken hiçbir şey okunmaz ve tutulmaz.") {
                        Toggle("Uyanık Tut'u etkinleştir", isOn: Binding(
                            get: { settings.keepAwakeEnabled },
                            set: {
                                settings.keepAwakeEnabled = $0
                                // The protection notification needs permission; asked only on this click, never at launch.
                                if $0 { notifier.requestIfNeeded() }
                            }
                        )).labelsHidden().toggleStyle(.switch)
                    }
                    RowDivider()
                    SettingRow("Ekranı da açık tut", detail: "Kapalıyken ekran sönebilir, sistem çalışmaya devam eder.") {
                        Toggle("Ekranı da açık tut", isOn: $settings.keepAwakeDisplay).labelsHidden().toggleStyle(.switch)
                    }
                    RowDivider()
                    SettingRow("Simgeye tıklayınca", detail: "Sağ tık diğer süreleri gösterir.") {
                        Picker("Süre", selection: $settings.keepAwakeDuration) {
                            ForEach(SettingsStore.keepAwakeDurationChoices, id: \.self) { Text(KeepAwakeText.durationMenuTitle($0)).tag($0) }
                        }.labelsHidden().fixedSize()
                    }
                }
            }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(AwakeTrigger.allCases.enumerated()), id: \.element) { index, trigger in
                        if index > 0 { RowDivider() }
                        SettingRow(Text(KeepAwakeText.name(trigger)), detail: Text(KeepAwakeText.detail(trigger))) {
                            HStack(spacing: 12) {
                                if trigger == .network {
                                    Picker("Eşik", selection: $settings.keepAwakeNetworkThreshold) {
                                        ForEach(AwakeTrigger.networkThresholdChoices, id: \.self) { Text(verbatim: KeepAwakeText.megabytes($0)).tag($0) }
                                    }.labelsHidden().fixedSize()
                                }
                                Toggle(KeepAwakeText.name(trigger), isOn: binding(for: trigger)).labelsHidden().toggleStyle(.switch)
                            }
                        }
                    }
                }
            }
            Text("Tetikleyiciler varsayılan olarak kapalıdır. Koşul bittikten 2 dakika sonra Mac'in uyumasına izin verilir; çalışan işlemler 30 saniyede bir ve uygulama açılınca taranır.")
                .font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Koruma")
                    Text("Her zaman açık: pil yüzde 15 ve altına inerse (pildeyken), sistem ısınmayı ciddi olarak bildirirse ya da en sıcak sensör 60 saniye boyunca 90 °C ve üstünde kalırsa uyanık tutma bırakılır ve bildirim gelir. Sıcaklık 75 °C altına inene kadar yeniden başlatılamaz.")
                        .font(.sistemBody).foregroundStyle(Palette.inkSecondary)
                    Text("Kapağı kapatınca Mac yine uyur; kapak kapalı modu bu sürümde yok.")
                        .font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
                }
            }
        }
    }

    private func binding(for trigger: AwakeTrigger) -> Binding<Bool> {
        Binding(
            get: { settings.keepAwakeTriggers.contains(trigger) },
            set: { on in
                if on { settings.keepAwakeTriggers.insert(trigger) } else { settings.keepAwakeTriggers.remove(trigger) }
            }
        )
    }
}
