import SistemUI
import SwiftUI
import SystemKit

struct DiskPopover: View {
    let settings: SettingsStore
    let openWindow: () -> Void
    @Environment(LiveFeed.self) private var feed

    var body: some View {
        let _ = feed.frame
        let store = feed.store
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "Disk").font(.sistemHeading).foregroundStyle(Palette.ink)
                Spacer()
                Text(verbatim: store.disk?.devices.first?.name ?? "").font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
            }

            DiskThroughputSummary(sample: store.disk, compact: true)

            Card(padding: 10) {
                DiskHistory(store: store, span: 90).frame(height: 56)
            }

            DiskVolumeList(volumes: store.diskVolumes, limit: 4)

            HStack {
                Button("Ayrıntılar", action: openWindow).buttonStyle(AccentButtonStyle())
                Spacer()
                Button("Çık") { NSApp.terminate(nil) }.buttonStyle(QuietButtonStyle())
            }
        }
        .padding(16)
        .frame(width: 300)
        .background(Palette.background)
        .liveMetric(.disk)
    }
}
