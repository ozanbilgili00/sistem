import SistemUI
import SwiftUI
import SystemKit

/// Menu bar popover: per display, the hardware sliders and software dimming.
struct DisplayPopover: View {
    let openWindow: () -> Void
    @Environment(DisplayModel.self) private var model

    var body: some View {
        let state = model.state
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let pending = state.pending { ModeTrialBanner(pending: pending, model: model) }
                if state.entries.isEmpty {
                    Text("Bağlı ekran bulunamadı.").font(.sistemBody).foregroundStyle(Palette.inkSecondary)
                }
                ForEach(state.entries) { entry in DisplayCard(entry: entry, model: model, compact: true) }
                HStack {
                    Button("Ayrıntılar", action: openWindow).buttonStyle(AccentButtonStyle())
                    Spacer()
                    Button("Çık") { NSApp.terminate(nil) }.buttonStyle(QuietButtonStyle())
                }
            }
            .padding(16)
        }
        .frame(width: 440)
        .frame(maxHeight: 640)
        .background(Palette.background)
        .onAppear { model.viewAppeared() }
        .onDisappear { model.viewDisappeared() }
    }
}
