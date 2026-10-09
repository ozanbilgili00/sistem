import SistemUI
import SwiftUI
import SystemKit

struct ClockPopover: View {
    let settings: SettingsStore
    let openWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LocalTimeSummary(settings: settings, compact: true)
            Card(padding: 12) { MonthCalendar(compact: true) }
            if !settings.clockZones.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Saat dilimleri")
                    ZoneRows(identifiers: settings.clockZones, showsSeconds: settings.clockDisplay.showsSeconds, limit: 5)
                }
            }
            HStack {
                Button("Ayrıntılar", action: openWindow).buttonStyle(AccentButtonStyle())
                Spacer()
                Button("Çık") { NSApp.terminate(nil) }.buttonStyle(QuietButtonStyle())
            }
        }
        .padding(16)
        .frame(width: 300)
        .background(Palette.background)
    }
}
