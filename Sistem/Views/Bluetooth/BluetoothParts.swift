import SistemUI
import SwiftUI
import SystemKit

extension BluetoothDevice.Kind {
    var symbol: String {
        switch self {
        case .headphones: "headphones"
        case .speaker: "hifispeaker"
        case .keyboard: "keyboard"
        case .mouse: "computermouse"
        case .trackpad: "rectangle.and.hand.point.up.left"
        case .gamepad: "gamecontroller"
        case .phone: "iphone"
        case .other: "dot.radiowaves.left.and.right"
        }
    }
}

extension BluetoothDevice.Battery.Part {
    /// "S" / "R" and so on: short enough for a row that also holds the name.
    var title: LocalizedStringKey {
        switch self {
        case .main: "Pil"
        case .left: "Sol"
        case .right: "Sağ"
        case .case: "Kılıf"
        }
    }
}

/// One device: icon, name, and its battery levels where it reports them.
struct BluetoothDeviceRow: View {
    let device: BluetoothDevice
    var dimmed = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.kind.symbol)
                .font(.system(size: 14))
                .foregroundStyle(dimmed ? Palette.inkTertiary : Palette.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: device.name)
                    .font(.sistemBody)
                    .foregroundStyle(dimmed ? Palette.inkSecondary : Palette.ink)
                    .lineLimit(1)
                if device.batteries.count > 1 {
                    HStack(spacing: 10) {
                        ForEach(device.batteries, id: \.part) { battery in
                            HStack(spacing: 3) {
                                Text(battery.part.title).font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
                                Text(verbatim: Format.percent(Float(battery.percent) / 100)).font(.sistemCaption).foregroundStyle(Palette.inkSecondary)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            if device.batteries.count == 1, let battery = device.batteries.first {
                BatteryGauge(percent: battery.percent)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A small bar and the percentage.
struct BatteryGauge: View {
    let percent: Int

    var body: some View {
        HStack(spacing: 8) {
            MeterBar(Double(percent) / 100, color: percent <= 20 ? Palette.warning : Palette.accent)
                .frame(width: 44)
            Text(verbatim: Format.percent(Float(percent) / 100))
                .font(.sistemValue).foregroundStyle(Palette.ink)
                .frame(minWidth: 44, alignment: .trailing)
        }
    }
}

/// Connected devices first, then the other paired ones.
struct BluetoothDeviceList: View {
    let sample: BluetoothSample?
    var limit: Int?
    var showsPaired = true

    var body: some View {
        if let sample {
            let connected = sample.connected
            let others = sample.devices.filter { !$0.isConnected }
            VStack(alignment: .leading, spacing: 8) {
                if connected.isEmpty {
                    Text(sample.isPoweredOn == false ? "Bluetooth kapalı." : "Bağlı cihaz yok.")
                        .font(.sistemBody).foregroundStyle(Palette.inkSecondary)
                }
                ForEach(Array(connected.prefix(limit ?? .max))) { BluetoothDeviceRow(device: $0) }
                if showsPaired && !others.isEmpty {
                    SectionLabel("Eşleşmiş").padding(.top, connected.isEmpty ? 0 : 6)
                    ForEach(Array(others.prefix(limit.map { max(0, $0 - connected.count) } ?? .max))) { BluetoothDeviceRow(device: $0, dimmed: true) }
                }
            }
        } else {
            Text("Aygıtlar okunuyor…").font(.sistemBody).foregroundStyle(Palette.inkSecondary)
        }
    }
}
