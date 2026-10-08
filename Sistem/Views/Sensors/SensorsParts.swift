import SistemUI
import SwiftUI
import SystemKit

/// Colour for a hot reading: calm until 90 °C, then the semantic warning tones.
func temperatureColor(_ celsius: Float?) -> Color {
    guard let celsius else { return Palette.ink }
    return celsius >= 100 ? Palette.critical : celsius >= 90 ? Palette.warning : Palette.ink
}

/// Headline numbers: hottest CPU core sensor and hottest GPU sensor, with the CPU average.
struct TemperatureSummary: View {
    let temperature: TemperatureSample?
    let unit: SettingsStore.TemperatureUnit
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 18) {
                big("CPU en sıcak", temperature?.headline)
                big("GPU en sıcak", temperature?.gpuHottest)
            }
            if !compact || temperature?.cpuAverage != nil {
                HStack {
                    Text("CPU ortalaması").font(.sistemBody).foregroundStyle(Palette.inkSecondary)
                    Spacer()
                    Text(verbatim: Format.temperatureDetailed(temperature?.cpuAverage, unit: unit))
                        .font(.sistemValue).foregroundStyle(Palette.ink)
                }
            }
        }
    }

    private func big(_ title: LocalizedStringKey, _ celsius: Float?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.sistemCaption).foregroundStyle(Palette.inkSecondary)
            Text(verbatim: Format.temperatureDetailed(celsius, unit: unit))
                .font(compact ? .sistemHeading.monospacedDigit() : .sistemBigValue)
                .foregroundStyle(temperatureColor(celsius))
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// CPU and GPU temperature over time on the same fixed 30...100 °C scale as the menu bar ring.
struct TemperatureHistory: View {
    let store: MetricStore
    var span = MetricStore.historyLength

    var body: some View {
        let cpu = Array(store.cpuTemperature.values().suffix(span)).map(SensorScale.fraction)
        let gpu = Array(store.gpuTemperature.values().suffix(span)).map(SensorScale.fraction)
        ZStack {
            HistoryChart([.init(cpu, UsageColors.user)], capacity: span)
            HistoryChart([.init(gpu, Palette.warning.opacity(0.55))], capacity: span, gridLines: false)
        }
    }
}

/// One fan: speed against its maximum, with the range it can run in.
struct FanRows: View {
    let fans: [FanReading]

    var body: some View {
        VStack(spacing: 14) {
            ForEach(fans, id: \.info.index) { fan in
                VStack(spacing: 5) {
                    HStack {
                        Text(verbatim: SensorLabelBase.fan.title(index: fan.info.index + 1))
                            .font(.sistemBody).foregroundStyle(Palette.inkSecondary)
                        Spacer(minLength: 8)
                        Text(verbatim: Format.rpm(fan.rpm)).font(.sistemValue).foregroundStyle(Palette.ink)
                    }
                    MeterBar(Double((fan.rpm ?? 0) / fan.info.maxRPM))
                    HStack {
                        Text("Aralık \(Format.rpm(fan.info.minRPM)) – \(Format.rpm(fan.info.maxRPM))")
                            .font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
                        Spacer()
                    }
                }
            }
        }
    }
}

/// A group of temperature sensors: summary when folded, every sensor when open.
/// Small groups start open; the 40-sensor ones start folded.
struct SensorGroupCard: View {
    let group: SensorGroup
    let rows: [(info: SensorInfo, value: Float)]
    let unit: SettingsStore.TemperatureUnit
    @State private var expanded: Bool

    init(group: SensorGroup, rows: [(info: SensorInfo, value: Float)], unit: SettingsStore.TemperatureUnit, expanded: Bool? = nil) {
        self.group = group
        self.rows = rows
        self.unit = unit
        _expanded = State(initialValue: expanded ?? (rows.count <= 6))
    }

    var body: some View {
        let values = rows.map(\.value)
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 8) {
                        Text(group.title).font(.sistemLabel).tracking(1.1).textCase(.uppercase).foregroundStyle(Palette.inkTertiary)
                        Pill(Text(verbatim: "\(rows.count)"), tone: .neutral)
                        Spacer(minLength: 8)
                        if !expanded, let max = values.max() {
                            Text("ort. \(Format.temperatureDetailed(values.reduce(0, +) / Float(values.count), unit: unit)) · maks \(Format.temperatureDetailed(max, unit: unit))")
                                .font(.sistemCaption).foregroundStyle(Palette.inkSecondary)
                        }
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.inkTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(group.title))
                .accessibilityValue(expanded ? Text("Bölüm açık") : Text("Bölüm kapalı"))

                if expanded {
                    VStack(spacing: 7) {
                        ForEach(rows, id: \.info.key) { row in
                            HStack(spacing: 8) {
                                Text(verbatim: row.info.title).font(.sistemBody).foregroundStyle(Palette.inkSecondary)
                                Text(verbatim: row.info.key).font(.sistemCaption.monospaced()).foregroundStyle(Palette.inkTertiary)
                                Spacer(minLength: 8)
                                Text(verbatim: Format.temperatureDetailed(row.value, unit: unit))
                                    .font(.sistemValue).foregroundStyle(temperatureColor(row.value))
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Name and value rows of one kind (voltage, current, power).
struct SensorValueRows: View {
    let rows: [(info: SensorInfo, value: Float)]
    let format: (Float) -> String

    var body: some View {
        VStack(spacing: 8) {
            ForEach(rows, id: \.info.key) { row in
                HStack(spacing: 8) {
                    Text(verbatim: row.info.title).font(.sistemBody).foregroundStyle(Palette.inkSecondary)
                    Spacer(minLength: 8)
                    Text(verbatim: format(row.value)).font(.sistemValue).foregroundStyle(Palette.ink)
                }
            }
        }
    }
}
