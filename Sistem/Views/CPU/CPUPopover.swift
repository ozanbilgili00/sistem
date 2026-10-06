import SistemUI
import SwiftUI
import SystemKit

struct CPUPopover: View {
    let settings: SettingsStore
    let openWindow: () -> Void
    let close: () -> Void
    @Environment(LiveFeed.self) private var feed
    @State private var hardware = HardwareInfo.current()

    var body: some View {
        let _ = feed.frame
        let sample = feed.store.cpu
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "CPU").font(.sistemHeading).foregroundStyle(Palette.ink)
                Spacer()
                Text(verbatim: hardware.chip).font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
            }

            CPUUsageSummary(sample: sample, ringSize: 72, lineWidth: 8)

            Card(padding: 10) {
                CPUHistory(store: feed.store, span: 90).frame(height: 56)
            }

            if settings.cpuShowCores {
                CPUCoreGroups(sample: sample, clusters: hardware.clusters, barHeight: 26)
            }

            if settings.cpuShowProcesses {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("En çok CPU kullananlar")
                    ProcessList(ranking: .cpu)
                }
            }

            if settings.cpuShowLoadAverage {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Ortalama yük")
                    LoadAverageRow(load: sample?.loadAverage)
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
        .liveMetric(.cpu)
    }
}
