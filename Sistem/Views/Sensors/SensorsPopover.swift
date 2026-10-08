import SistemUI
import SwiftUI
import SystemKit

struct SensorsPopover: View {
    let settings: SettingsStore
    let openWindow: () -> Void
    @Environment(LiveFeed.self) private var feed

    var body: some View {
        let _ = feed.frame
        let store = feed.store
        let unit = settings.temperatureUnit
        let sample = store.sensors
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sıcaklık").font(.sistemHeading).foregroundStyle(Palette.ink)
                Spacer()
                if let count = sample?.catalog.sensors.count {
                    Text("\(count) sensör").font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
                }
            }

            TemperatureSummary(temperature: store.temperature, unit: unit, compact: true)

            Card(padding: 10) {
                TemperatureHistory(store: store, span: 90).frame(height: 56)
            }

            if let fans = sample?.fans, !fans.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Fanlar")
                    ForEach(fans, id: \.info.index) { fan in
                        HStack {
                            Text(verbatim: SensorLabelBase.fan.title(index: fan.info.index + 1))
                                .font(.sistemBody).foregroundStyle(Palette.inkSecondary)
                            Spacer()
                            Text(verbatim: Format.rpm(fan.rpm)).font(.sistemValue).foregroundStyle(Palette.ink)
                        }
                    }
                }
            }

            if let sample {
                let power = sample.readings(of: .power).filter { $0.info.label == .named(.system) || $0.info.label == .named(.cpu) }
                if !power.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel("Güç")
                        SensorValueRows(rows: power, format: { Format.watts($0) })
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
        .liveMetric(.sensors)
    }
}
