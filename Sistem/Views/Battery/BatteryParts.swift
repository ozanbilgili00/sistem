import SistemUI
import SwiftUI
import SystemKit

/// Ring with the charge, and beside it what the battery is doing and how long it will take.
/// Shared by the page and the popover.
struct BatteryChargeSummary: View {
    let status: BatteryStatus?
    var ringSize: CGFloat = 96
    var lineWidth: CGFloat = 10

    var body: some View {
        let sample = status?.sample
        HStack(spacing: 18) {
            UsageRing([.init(Double(sample.map { Float($0.percent) / 100 } ?? 0), ringColor(sample))], lineWidth: lineWidth) {
                Text(verbatim: sample.map { Format.percent(Float($0.percent) / 100) } ?? "—")
                    .font(ringSize > 80 ? .sistemBigValue : .sistemValue)
                    .foregroundStyle(Palette.ink)
            }
            .frame(width: ringSize, height: ringSize)

            VStack(alignment: .leading, spacing: 8) {
                if let sample {
                    Pill(Text(BatteryText.stateName(sample.state)), tone: tone(sample))
                    Text(BatteryText.timeLine(sample))
                        .font(.sistemBody).foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if status == nil {
                        Text("Okunuyor…").font(.sistemBody).foregroundStyle(Palette.inkSecondary)
                    } else {
                        Text("Bu Mac'te batarya yok.").font(.sistemBody).foregroundStyle(Palette.inkSecondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func ringColor(_ sample: BatterySample?) -> Color {
        guard let sample, sample.state == .discharging else { return Palette.accent }
        return sample.percent <= 10 ? Palette.critical : sample.percent <= 20 ? Palette.warning : Palette.accent
    }

    private func tone(_ sample: BatterySample) -> Pill.Tone {
        switch sample.state {
        case .charging: .good
        case .charged, .pluggedNotCharging: .neutral
        case .discharging: sample.percent <= 20 ? .warning : .accent
        }
    }
}

enum BatteryText {
    static func stateName(_ state: BatterySample.State) -> LocalizedStringKey {
        switch state {
        case .discharging: "Pille çalışıyor"
        case .charging: "Şarj oluyor"
        case .charged: "Şarjlı"
        case .pluggedNotCharging: "Prizde, şarj olmuyor"
        }
    }

    /// "3:35 kaldı" / "Şarjın dolmasına 1:05" / "Süre hesaplanıyor…", or the reason there is no figure.
    static func timeLine(_ sample: BatterySample) -> LocalizedStringKey {
        if let text = sample.remainingText {
            return sample.state == .charging ? "Şarjın dolmasına \(text)" : "\(text) kaldı"
        }
        switch sample.state {
        case .discharging, .charging: return sample.isEstimating ? "Süre hesaplanıyor…" : "Süre tahmini yok"
        case .charged: return "Pil dolu."
        case .pluggedNotCharging: return "Şarj sınırında ya da ısı nedeniyle bekliyor."
        }
    }
}

/// Voltage, current and power rows. Values the Mac doesn't publish are left out.
struct BatteryElectricRows: View {
    let health: BatteryHealth?
    var unit: SettingsStore.TemperatureUnit = .celsius
    var compact = false

    var body: some View {
        VStack(spacing: 8) {
            if let watts = health?.batteryWatts {
                row("Pil gücü", signedWatts(watts))
            }
            if let watts = health?.systemWatts { row("Sistem gücü", Format.watts(Float(watts))) }
            if !compact {
                if let volts = health?.volts { row("Voltaj", Format.volts(Float(volts))) }
                if let amps = health?.amps { row("Akım", Format.amps(Float(amps))) }
            }
            if let celsius = health?.temperatureCelsius { row("Sıcaklık", temperature(celsius)) }
        }
    }

    private func signedWatts(_ watts: Double) -> String {
        let magnitude = Double(abs(watts)).formatted(.number.precision(.fractionLength(1)))
        return abs(watts) < 0.05 ? "0 W" : "\(watts < 0 ? "−" : "+")\(magnitude) W"
    }

    private func temperature(_ celsius: Double) -> String {
        Format.temperatureDetailed(Float(celsius), unit: unit)
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title).font(.sistemBody).foregroundStyle(Palette.inkSecondary)
            Spacer()
            Text(verbatim: value).font(.sistemValue).foregroundStyle(Palette.ink)
        }
    }
}

/// Health figures: capacity against new, cycles, and the capacity in mAh.
struct BatteryHealthRows: View {
    let health: BatteryHealth?

    var body: some View {
        VStack(spacing: 8) {
            if let percent = health?.maximumCapacityPercent {
                VStack(spacing: 5) {
                    row("Azami kapasite", Format.percent(Float(percent) / 100))
                    MeterBar(Double(percent) / 100, color: percent >= 80 ? Palette.good : Palette.warning)
                }
            }
            if let cycles = health?.cycleCount {
                if let design = health?.designCycleCount {
                    row("Döngü sayısı", "\(cycles.formatted()) / \(design.formatted())")
                } else {
                    row("Döngü sayısı", cycles.formatted())
                }
            }
            if let nominal = health?.nominalCapacity, let design = health?.designCapacity {
                row("Kapasite", "\(nominal.formatted()) / \(design.formatted()) mAh")
            }
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title).font(.sistemBody).foregroundStyle(Palette.inkSecondary)
            Spacer()
            Text(verbatim: value).font(.sistemValue).foregroundStyle(Palette.ink)
        }
    }
}

struct BatteryAdapterRows: View {
    let adapter: AdapterInfo

    var body: some View {
        VStack(spacing: 8) {
            if let watts = adapter.watts { row("Güç", "\(watts) W") }
            if let name = adapter.name { row("Ad", name) }
            if adapter.isWireless { row("Bağlantı", String(localized: "Kablosuz")) }
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.sistemBody).foregroundStyle(Palette.inkSecondary)
            Spacer(minLength: 12)
            Text(verbatim: value).font(.sistemValue).foregroundStyle(Palette.ink).multilineTextAlignment(.trailing)
        }
    }
}
