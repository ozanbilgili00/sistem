import SistemUI
import SwiftUI
import SystemKit

struct GPUPopover: View {
    let settings: SettingsStore
    let openWindow: () -> Void
    @Environment(LiveFeed.self) private var feed
    @State private var hardware = HardwareInfo.current()

    var body: some View {
        let _ = feed.frame
        let sample = feed.store.gpu
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "GPU").font(.sistemHeading).foregroundStyle(Palette.ink)
                Spacer()
                Text(verbatim: hardware.chip).font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
            }

            GPUUsageSummary(sample: sample, ringSize: 72, lineWidth: 8)

            Card(padding: 10) {
                GPUHistory(store: feed.store, span: 90).frame(height: 56)
            }

            GPUMemoryRows(sample: sample, total: hardware.memoryBytes)

            if settings.gpuShowPower {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Güç")
                    PowerRows(power: feed.store.power, rows: [.gpu, .ane, .system])
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
        .liveMetric(.gpu)
        // Power costs an IOReport sample a tick, so it is only asked for when shown.
        .background { if settings.gpuShowPower { Color.clear.liveMetric(.power) } }
    }
}
