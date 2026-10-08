import SistemUI
import SwiftUI
import SystemKit

struct SensorsPage: View {
    @Bindable var settings: SettingsStore
    @State private var tab: ModuleTab

    init(settings: SettingsStore, tab: ModuleTab = .overview) {
        self.settings = settings
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ModulePageHeader(module: .sensors, tab: $tab)
            switch tab {
            case .overview: SensorsOverview(settings: settings)
            case .module: SensorsModuleSettings(settings: settings)
            case .widgets: WidgetSettings(module: .sensors, settings: settings)
            }
        }
    }
}

private struct SensorsOverview: View {
    let settings: SettingsStore
    @Environment(LiveFeed.self) private var feed

    var body: some View {
        let _ = feed.frame
        let store = feed.store
        let unit = settings.temperatureUnit
        VStack(alignment: .leading, spacing: 14) {
            if let sample = store.sensors, !sample.catalog.sensors.isEmpty || !sample.fans.isEmpty {
                loaded(sample, store: store, unit: unit)
            } else if store.sensors != nil {
                Card {
                    Text("Bu Mac'te okunabilir sensör bulunamadı.")
                        .font(.sistemBody).foregroundStyle(Palette.inkSecondary)
                }
            } else {
                Card {
                    Text("Sensörler okunuyor…").font(.sistemBody).foregroundStyle(Palette.inkSecondary)
                }
            }
        }
        .liveMetric(.sensors)
    }

    @ViewBuilder
    private func loaded(_ sample: SensorSample, store: MetricStore, unit: SettingsStore.TemperatureUnit) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel("Sıcaklık")
                    TemperatureSummary(temperature: sample.temperature, unit: unit)
                }
                .frame(maxHeight: .infinity, alignment: .topLeading)
            }
            if !sample.fans.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionLabel("Fanlar")
                        FanRows(fans: sample.fans)
                    }
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)

        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel("Geçmiş")
                    Spacer()
                    Text("Son \(minutes) dakika").font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
                }
                TemperatureHistory(store: store).frame(height: 150)
                HStack(spacing: 16) {
                    LegendRow("CPU", color: UsageColors.user, value: Format.temperatureDetailed(sample.temperature.headline, unit: unit))
                    LegendRow("GPU", color: Palette.warning.opacity(0.55), value: Format.temperatureDetailed(sample.temperature.gpuHottest, unit: unit))
                }
                Text("Ölçek \(Format.temperature(SensorScale.low, unit: unit)) – \(Format.temperature(SensorScale.high, unit: unit)). CPU çizgisi çekirdek sensörlerinin en yükseğidir.")
                    .font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
            }
        }

        ForEach(SensorGroup.allCases, id: \.self) { group in
            let rows = sample.readings(of: .temperature, group: group)
            if !rows.isEmpty {
                SensorGroupCard(group: group, rows: rows, unit: unit)
            }
        }

        let voltage = sample.readings(of: .voltage), current = sample.readings(of: .current), power = sample.readings(of: .power)
        if !voltage.isEmpty || !current.isEmpty || !power.isEmpty {
            HStack(alignment: .top, spacing: 14) {
                if !voltage.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionLabel("Voltaj")
                            SensorValueRows(rows: voltage, format: Format.volts)
                        }
                    }
                }
                if !current.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionLabel("Akım")
                            SensorValueRows(rows: current, format: Format.amps)
                        }
                    }
                }
                if !power.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionLabel("Güç")
                            SensorValueRows(rows: power, format: { Format.watts($0) })
                        }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }

        if !sample.catalog.isKnownModel {
            Text("Bu model için sensör adları doğrulanmadı; sensörler SMC anahtarlarıyla listelenir.")
                .font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
        }
    }

    /// Sensors arrive every other tick, so the 300-sample history reaches twice as far as the others'.
    private var minutes: Int { feed.historyMinutes * 2 }
}

private struct SensorsModuleSettings: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                MenuBarToggleRow(module: .sensors, settings: settings)
                RowDivider()
                SettingRow("İki satırlı gösterim", detail: "Menü çubuğunda CPU'nun altında GPU sıcaklığını da gösterir. GPU sensörleri için her turda 42 anahtar daha okunur.") {
                    Toggle("İki satırlı gösterim", isOn: $settings.sensorsStack).labelsHidden().toggleStyle(.switch)
                }
                RowDivider()
                SettingRow("Sıcaklık birimi", detail: "Genel ayarlardan değiştirilir.") {
                    Text(verbatim: settings.temperatureUnit.symbol).font(.sistemValue).foregroundStyle(Palette.ink)
                }
            }
        }
    }
}
