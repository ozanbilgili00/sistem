import SistemUI
import SwiftUI
import SystemKit

struct KeepAwakePopover: View {
    let settings: SettingsStore
    let openWindow: () -> Void
    @Environment(LiveFeed.self) private var feed
    @Environment(KeepAwakeModel.self) private var model

    var body: some View {
        let _ = feed.frame
        let state = model.state
        VStack(alignment: .leading, spacing: 14) {
            KeepAwakeStatusSummary(state: state, enabled: settings.keepAwakeEnabled, remaining: model.remaining())
            KeepAwakeControls(state: state, enabled: settings.keepAwakeEnabled,
                              start: { model.start(duration: $0 > 0 ? $0 : nil) }, stop: model.stop)
            Rectangle().fill(Palette.line).frame(height: 1)
            SectionLabel("Neden uyanık?")
            AwakeHolderList(sample: feed.store.assertions, limit: 5)
            if !model.config.triggers.isEmpty {
                SectionLabel("Tetikleyiciler")
                AwakeTriggerSummary(state: state, config: model.config)
            }
            HStack {
                Button("Ayrıntılar", action: openWindow).buttonStyle(AccentButtonStyle())
                Spacer()
                Button("Çık") { NSApp.terminate(nil) }.buttonStyle(QuietButtonStyle())
            }
        }
        .padding(16)
        .frame(width: 440)
        .background(Palette.background)
        .liveMetric(.assertions)
    }
}
