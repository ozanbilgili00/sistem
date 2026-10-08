import SistemUI
import SwiftUI
import SystemKit

struct NetworkPopover: View {
    let settings: SettingsStore
    let openWindow: () -> Void
    @Environment(LiveFeed.self) private var feed

    var body: some View {
        let _ = feed.frame
        let store = feed.store
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Ağ").font(.sistemHeading).foregroundStyle(Palette.ink)
                Spacer()
                Text(verbatim: subtitle(store)).font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
            }

            NetworkThroughputSummary(sample: store.network, compact: true)

            Card(padding: 10) {
                NetworkHistory(store: store, span: 90).frame(height: 56)
            }

            InterfaceList(sample: store.network, addresses: store.networkInfo?.addresses ?? [], path: store.path, limit: 3)

            HStack {
                Button("Ayrıntılar", action: openWindow).buttonStyle(AccentButtonStyle())
                Spacer()
                Button("Çık") { NSApp.terminate(nil) }.buttonStyle(QuietButtonStyle())
            }
        }
        .padding(16)
        .frame(width: 300)
        .background(Palette.background)
        .liveMetric(.network)
        .liveMetric(.networkInfo)
    }

    private func subtitle(_ store: MetricStore) -> String {
        guard let path = store.path else { return "" }
        guard path.isConnected else { return String(localized: "Bağlı değil") }
        return path.primary.map { String(localized: $0.type.title) } ?? ""
    }
}
