import SistemUI
import SwiftUI
import SystemKit

/// Menu bar popover: one compact card per server.
struct ServersPopover: View {
    let openWindow: () -> Void
    @Environment(ServersModel.self) private var model

    var body: some View {
        let state = model.state
        // The list scrolls; the button row stays under it, always visible, whatever the number of servers.
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !state.enabled {
                        // Off is not the same as empty: nothing is read, and adding a server alone would not change that.
                        Text("Sunucular modülü kapalı. Modül sekmesinden açabilirsiniz.").font(.sistemBody).foregroundStyle(Palette.inkSecondary)
                    } else if state.servers.isEmpty {
                        Text("Henüz sunucu eklenmedi.").font(.sistemBody).foregroundStyle(Palette.inkSecondary)
                    }
                    ForEach(state.servers) { runtime in ServerCard(runtime: runtime, model: model, compact: true) }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)
            }
            HStack {
                Button("Ayrıntılar", action: openWindow).buttonStyle(AccentButtonStyle())
                Spacer()
                Button("Çık") { NSApp.terminate(nil) }.buttonStyle(QuietButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Palette.background)
        }
        .frame(width: 440)
        .frame(maxHeight: 640)
        .background(Palette.background)
        .onAppear { model.viewAppeared() }
        .onDisappear { model.viewDisappeared() }
    }
}
