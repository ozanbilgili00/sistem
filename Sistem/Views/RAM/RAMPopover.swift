import SistemUI
import SwiftUI
import SystemKit

struct RAMPopover: View {
    let settings: SettingsStore
    let openWindow: () -> Void
    @Environment(LiveFeed.self) private var feed

    var body: some View {
        let _ = feed.frame
        let sample = feed.store.memory
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "RAM").font(.sistemHeading).foregroundStyle(Palette.ink)
                Spacer()
                Text(verbatim: Format.bytes(sample?.total)).font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
            }

            RAMUsageSummary(sample: sample, ringSize: 72, lineWidth: 8)

            Card(padding: 10) {
                RAMHistory(store: feed.store, span: 90).frame(height: 56)
            }

            RAMStatusRows(sample: sample)

            if settings.ramShowProcesses {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("En çok bellek kullananlar")
                    ProcessList(ranking: .memory)
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
        .liveMetric(.memory)
    }
}
