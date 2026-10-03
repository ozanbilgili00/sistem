import SistemUI
import SwiftUI
import SystemKit

/// Placeholder for a module until its phase lands. The dashboard already shows
/// static hardware facts — read once, no timers.
struct ModulePage: View {
    let module: ModuleID
    let settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(Text(module.title), subtitle: Text(module.summary))

            if module == .dashboard {
                HardwareCard()
            }

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        SectionLabel("Durum")
                        Spacer()
                        if settings.menuBarModules.contains(module), let unit = module.menuBarUnit {
                            Pill(Text("Menü çubuğunda · \(Text(unit))"), tone: .accent)
                        }
                        Pill(Text("Faz \(module.phase)"), tone: .neutral)
                    }
                    Text("Bu modül Faz \(module.phase) ile geliyor.")
                        .font(.sistemBody)
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
        }
    }
}

private struct HardwareCard: View {
    // Read once per view lifetime: a handful of sysctl calls, no polling.
    @State private var info = HardwareInfo.current()

    var body: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                row("Model tanımlayıcı", info.modelIdentifier)
                RowDivider()
                row("İşlemci", info.chip)
                RowDivider()
                row("Çekirdekler", info.clusters.map { "\($0.count) \($0.name)" }.joined(separator: " · "))
                RowDivider()
                row("Bellek", info.memoryBytes.formatted(.byteCount(style: .memory)))
            }
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        SettingRow(title) {
            Text(value).font(.sistemValue).foregroundStyle(Palette.ink).textSelection(.enabled)
        }
    }
}
