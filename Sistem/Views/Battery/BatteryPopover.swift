import SistemUI
import SwiftUI
import SystemKit

struct BatteryPopover: View {
    let settings: SettingsStore
    let openWindow: () -> Void
    @Environment(LiveFeed.self) private var feed

    var body: some View {
        let _ = feed.frame
        let status = feed.store.battery
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Batarya").font(.sistemHeading).foregroundStyle(Palette.ink)
                Spacer()
                if let adapter = status?.sample?.adapter, let watts = adapter.watts {
                    Text(verbatim: "\(watts) W").font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
                }
            }

            BatteryChargeSummary(status: status, ringSize: 76, lineWidth: 9)

            if let sample = status?.sample {
                if sample.health?.maximumCapacityPercent != nil || sample.health?.cycleCount != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel("Sağlık")
                        BatteryHealthRows(health: sample.health)
                    }
                }
                if sample.health?.batteryWatts != nil || sample.health?.systemWatts != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel("Güç")
                        BatteryElectricRows(health: sample.health, unit: settings.temperatureUnit, compact: true)
                    }
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
        .liveMetric(.battery)
    }
}
