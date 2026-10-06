import SistemUI
import SwiftUI
import SystemKit

/// The three tabs every live module page has.
enum ModuleTab: Hashable { case overview, module, widgets }

struct ModulePageHeader: View {
    let module: ModuleID
    @Binding var tab: ModuleTab

    var body: some View {
        HStack(alignment: .top) {
            PageHeader(Text(module.title), subtitle: Text(module.summary))
            Picker("Bölüm", selection: $tab) {
                Text("Genel bakış").tag(ModuleTab.overview)
                Text("Modül").tag(ModuleTab.module)
                Text("Widget'lar").tag(ModuleTab.widgets)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }
}

struct MenuBarToggleRow: View {
    let module: ModuleID
    let settings: SettingsStore

    var body: some View {
        SettingRow("Menü çubuğunda göster") {
            Toggle("Menü çubuğunda göster", isOn: Binding(
                get: { settings.isInMenuBar(module) },
                set: { settings.setInMenuBar(module, $0) }
            )).labelsHidden().toggleStyle(.switch)
        }
    }
}

extension LiveFeed {
    /// How far back a full history chart reaches at the current interval.
    var historyMinutes: Int {
        let interval = engine?.config.interval ?? 2
        return Int((Double(MetricStore.historyLength) * interval / 60).rounded())
    }
}
