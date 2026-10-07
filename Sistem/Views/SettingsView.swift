import SistemUI
import SwiftUI
import SystemKit

struct SettingsView: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(Text("Ayarlar"), subtitle: Text("Görünüm, güncelleme sıklığı ve menü çubuğu."))

            SectionLabel("Görünüm")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    SettingRow("Tema") {
                        Picker("Tema", selection: $settings.appearance) {
                            Text("Sistem").tag(SettingsStore.Appearance.system)
                            Text("Koyu").tag(SettingsStore.Appearance.dark)
                            Text("Açık").tag(SettingsStore.Appearance.light)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    RowDivider()
                    SettingRow("Dock'ta göster", detail: "Kapalıyken uygulama yalnızca menü çubuğunda yaşar.") {
                        Toggle("Dock'ta göster", isOn: $settings.showInDock).labelsHidden().toggleStyle(.switch)
                    }
                    RowDivider()
                    SettingRow("Sıcaklık birimi") {
                        Picker("Sıcaklık birimi", selection: $settings.temperatureUnit) {
                            ForEach(SettingsStore.TemperatureUnit.allCases) { Text($0.symbol).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }

            SectionLabel("Enerji")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    SettingRow("Güncelleme aralığı", detail: "Daha uzun aralık, daha az pil tüketimi.") {
                        Picker("Güncelleme aralığı", selection: $settings.updateInterval) {
                            ForEach(SettingsStore.intervalChoices, id: \.self) { seconds in
                                Text("\(Int(seconds)) sn").tag(seconds)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    RowDivider()
                    SettingRow("Pilde yavaşla", detail: "Pildeyken ve Düşük Güç Modu'nda aralık iki katına çıkar.") {
                        Toggle("Pilde yavaşla", isOn: $settings.slowDownOnBattery).labelsHidden().toggleStyle(.switch)
                    }
                }
            }

            SectionLabel("Menü çubuğu")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(ModuleID.menuBarCandidates.enumerated()), id: \.element) { index, module in
                        if index > 0 { RowDivider() }
                        SettingRow(Text(module.menuBarTitle), detail: module.menuBarUnit.map { Text($0) }) {
                            HStack(spacing: 10) {
                                if module.metric == nil {
                                    Pill(Text("Faz \(module.phase)"), tone: .neutral)
                                }
                                Toggle(String(localized: module.menuBarTitle), isOn: Binding(
                                    get: { settings.isInMenuBar(module) },
                                    set: { settings.setInMenuBar(module, $0) }
                                )).labelsHidden().toggleStyle(.switch)
                            }
                        }
                    }
                }
            }
            Text("Henüz gelmemiş modüller seçili kalır ve kendi fazlarında görünür. Widget türleri her modülün kendi sayfasındaki Widget'lar sekmesinden seçilir.")
                .font(.sistemCaption)
                .foregroundStyle(Palette.inkTertiary)
        }
    }
}
