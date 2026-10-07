import SistemUI
import SwiftUI
import SystemKit

/// Ring for the headline Device Utilization, with the render and tiler shares beside
/// it. Shared by the popover and the page.
struct GPUUsageSummary: View {
    let sample: GPUSample?
    var ringSize: CGFloat = 96
    var lineWidth: CGFloat = 10

    var body: some View {
        HStack(spacing: 18) {
            UsageRing([.init(Double(sample?.device ?? 0), Palette.accent)], lineWidth: lineWidth) {
                Text(verbatim: Format.percent(sample?.device))
                    .font(ringSize > 80 ? .sistemBigValue : .sistemValue)
                    .foregroundStyle(Palette.ink)
            }
            .frame(width: ringSize, height: ringSize)

            VStack(spacing: 10) {
                MeterRow("Render", fraction: sample?.renderer)
                MeterRow("Tiler", fraction: sample?.tiler)
            }
        }
    }
}

/// Label, percentage and a gauge underneath.
struct MeterRow: View {
    private let title: LocalizedStringKey
    private let fraction: Float?

    init(_ title: LocalizedStringKey, fraction: Float?) {
        self.title = title
        self.fraction = fraction
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(title).font(.sistemBody).foregroundStyle(Palette.inkSecondary)
                Spacer(minLength: 8)
                Text(verbatim: Format.percent(fraction)).font(.sistemValue).foregroundStyle(Palette.ink)
            }
            MeterBar(Double(fraction ?? 0))
        }
    }
}

/// Device utilisation history from the store.
struct GPUHistory: View {
    let store: MetricStore
    var span = MetricStore.historyLength

    var body: some View {
        HistoryChart([.init(Array(store.gpuDevice.values().suffix(span)), UsageColors.user)], capacity: span)
    }
}

/// The GPU shares system memory with the CPU, so its footprint is a slice of RAM.
struct GPUMemoryRows: View {
    let sample: GPUSample?
    let total: UInt64

    var body: some View {
        VStack(spacing: 8) {
            row("Kullanılan", Format.bytes(sample?.memoryInUse))
            row("Ayrılan", Format.bytes(sample?.memoryAllocated))
            row("Sistem belleğindeki payı", Format.percent(sample.map {
                total == 0 ? 0 : Float(Double($0.memoryInUse) / Double(total))
            }))
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

/// Watts per source. Rows a Mac can't supply are left out rather than shown as zero:
/// the GPU and Neural Engine come from IOReport, the system total from the SMC.
struct PowerRows: View {
    enum Row { case gpu, ane, cpu, system }

    let power: PowerSample?
    let rows: [Row]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(rows.filter(isAvailable), id: \.self) { row in
                HStack {
                    Text(title(row)).font(.sistemBody).foregroundStyle(Palette.inkSecondary)
                    Spacer()
                    Text(verbatim: Format.watts(value(row))).font(.sistemValue).foregroundStyle(Palette.ink)
                }
            }
        }
    }

    private func title(_ row: Row) -> LocalizedStringKey {
        switch row {
        case .gpu: "GPU"
        case .ane: "Neural Engine"
        case .cpu: "CPU"
        case .system: "Sistem toplamı"
        }
    }

    private func value(_ row: Row) -> Float? {
        switch row {
        case .gpu: power?.gpu
        case .ane: power?.ane
        case .cpu: power?.cpu
        case .system: power?.system
        }
    }

    /// Before the first sample every row shows "—"; once one exists, a row whose
    /// source is missing (no IOReport, no SMC) disappears.
    private func isAvailable(_ row: Row) -> Bool {
        switch row {
        case .gpu, .ane: IOReport.library != nil
        case .cpu, .system: power == nil || value(row) != nil
        }
    }
}

extension PowerRows.Row: Hashable {}
