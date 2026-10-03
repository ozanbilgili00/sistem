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
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        ForEach(settings.menuBarModules) { module in
                            Pill(Text(module.menuBarTitle), tone: .accent)
                        }
                    }
                    Text("CPU, RAM ve GPU yüzde, sıcaklık derece olarak gösterilir. Sıralama ve seçim Faz 2'de düzenlenebilir olacak.")
                        .font(.sistemCaption)
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
        }
    }
}
