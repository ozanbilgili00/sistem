import SistemUI
import SwiftUI
import SystemKit

struct DisplayPage: View {
    @Bindable var settings: SettingsStore
    @State private var tab: ModuleTab

    init(settings: SettingsStore, tab: ModuleTab = .overview) {
        self.settings = settings
        _tab = State(initialValue: tab == .widgets ? .overview : tab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ModulePageHeader(module: .display, tab: $tab, showsWidgets: false)
            switch tab {
            case .overview, .widgets: DisplayOverview(settings: settings)
            case .module: DisplayModuleSettings(settings: settings)
            }
        }
    }
}

private struct DisplayOverview: View {
    let settings: SettingsStore
    @Environment(DisplayModel.self) private var model

    var body: some View {
        let state = model.state
        VStack(alignment: .leading, spacing: 14) {
            if !settings.displayEnabled {
                Card {
                    Text("Ekran modülü kapalı. Modül sekmesinden açabilirsiniz.").font(.sistemBody).foregroundStyle(Palette.inkSecondary)
                }
            } else {
                if let pending = state.pending { ModeTrialBanner(pending: pending, model: model) }
                if state.entries.isEmpty {
                    Card { Text("Bağlı ekran bulunamadı.").font(.sistemBody).foregroundStyle(Palette.inkSecondary) }
                }
                ForEach(state.entries) { entry in DisplayCard(entry: entry, model: model) }
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionLabel("Bağlantı günlüğü")
                        DisplayEventList(events: state.events)
                    }
                }
                Text("Ekran bilgisi sistem değişiklik bildirdiğinde güncellenir; zamanlayıcı yoktur. Donanım değerleri (DDC) yalnızca bu sayfa ya da açılır pencere görünürken bir kez okunur. Günlük yalnızca bellekte tutulur.")
                    .font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
            }
        }
        .onAppear { model.viewAppeared() }
        .onDisappear { model.viewDisappeared() }
    }
}

private struct DisplayModuleSettings: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Card(padding: 0) {
                VStack(spacing: 0) {
                    SettingRow("Ekran modülünü etkinleştir", detail: "Kapalıyken sistemden hiçbir bildirim alınmaz; karartma ve gece tonu da bırakılır.") {
                        Toggle("Ekran modülünü etkinleştir", isOn: $settings.displayEnabled).labelsHidden().toggleStyle(.switch)
                    }
                    RowDivider()
                    SettingRow("Menü çubuğunda göster", detail: "Ekran simgesi ekler; tıklayınca ekran başına kaydırıcılar açılır.") {
                        Toggle("Menü çubuğunda göster", isOn: $settings.displayMenuBar).labelsHidden().toggleStyle(.switch)
                            .disabled(!settings.displayEnabled)
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Geri alma")
                    Text("Çözünürlük ve yenileme hızı değişikliği deneme olarak uygulanır ve yalnızca bu uygulama için geçerlidir; 15 saniye içinde onaylanmazsa ya da Sistem kapanırsa eski mod geri gelir. Karartma ve gece tonu da uygulama kapanınca (çökse bile) sistem tarafından bırakılır.")
                        .font(.sistemBody).foregroundStyle(Palette.inkSecondary)
                    Text("Parlaklık tuşlarıyla harici monitörü yönetmek bu sürümde yok.")
                        .font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
                }
            }
        }
    }
}
