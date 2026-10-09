import SistemUI
import SwiftUI
import SystemKit

struct BluetoothPopover: View {
    let openWindow: () -> Void
    @Environment(LiveFeed.self) private var feed

    var body: some View {
        let _ = feed.frame
        let sample = feed.store.bluetooth
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "Bluetooth").font(.sistemHeading).foregroundStyle(Palette.ink)
                Spacer()
                if let count = sample?.connected.count {
                    Text("\(count) bağlı").font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
                }
            }
            BluetoothDeviceList(sample: sample, limit: 6, showsPaired: false)
            HStack {
                Button("Ayrıntılar", action: openWindow).buttonStyle(AccentButtonStyle())
                Spacer()
                Button("Çık") { NSApp.terminate(nil) }.buttonStyle(QuietButtonStyle())
            }
        }
        .padding(16)
        .frame(width: 300)
        .background(Palette.background)
        .liveMetric(.bluetooth)
    }
}
