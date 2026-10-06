import SistemUI
import SwiftUI
import SystemKit

/// Ring + user/system/idle legend, shared by the popover and the page.
struct CPUUsageSummary: View {
    let sample: CPUSample?
    var ringSize: CGFloat = 96
    var lineWidth: CGFloat = 10

    var body: some View {
        HStack(spacing: 18) {
            UsageRing([
                .init(Double(sample?.user ?? 0), UsageColors.user),
                .init(Double(sample?.system ?? 0), UsageColors.system),
            ], lineWidth: lineWidth) {
                Text(verbatim: Format.percent(sample?.total))
                    .font(ringSize > 80 ? .sistemBigValue : .sistemValue)
                    .foregroundStyle(Palette.ink)
            }
            .frame(width: ringSize, height: ringSize)

            VStack(spacing: 7) {
                LegendRow("Kullanıcı", color: UsageColors.user, value: Format.percent(sample?.user))
                LegendRow("Sistem", color: UsageColors.system, value: Format.percent(sample?.system))
                LegendRow("Boşta", color: UsageColors.idleSwatch, value: Format.percent(sample?.idle))
            }
        }
    }
}

/// Stacked system + user history from the store.
struct CPUHistory: View {
    let store: MetricStore
    /// How many of the newest samples to show across the width.
    var span = MetricStore.historyLength

    var body: some View {
        HistoryChart([
            .init(Array(store.cpuSystem.values().suffix(span)), UsageColors.system),
            .init(Array(store.cpuUser.values().suffix(span)), UsageColors.user),
        ], capacity: span)
    }
}

/// Per-core bars, one group per core class, fastest class first.
struct CPUCoreGroups: View {
    let sample: CPUSample?
    let clusters: [HardwareInfo.CoreCluster]
    var barHeight: CGFloat = 64

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(clusters, id: \.name) { cluster in
                let cores = values(for: cluster)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(verbatim: cluster.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                        Text("\(cluster.count) çekirdek").font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
                        Spacer()
                        Text(verbatim: Format.percent(cores.isEmpty ? nil : cores.reduce(0, +) / Float(cores.count)))
                            .font(.sistemValue).foregroundStyle(Palette.inkSecondary)
                    }
                    BarStrip(cores.isEmpty ? Array(repeating: 0, count: cluster.logicalCPUs.count) : cores)
                        .frame(height: barHeight)
                }
            }
        }
    }

    private func values(for cluster: HardwareInfo.CoreCluster) -> [Float] {
        guard let cores = sample?.cores, cluster.logicalCPUs.upperBound <= cores.count else { return [] }
        return Array(cores[cluster.logicalCPUs])
    }
}

struct LoadAverageRow: View {
    let load: LoadAverage?

    var body: some View {
        HStack(spacing: 0) {
            item("1 dk", load?.one)
            item("5 dk", load?.five)
            item("15 dk", load?.fifteen)
        }
    }

    private func item(_ title: LocalizedStringKey, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
            Text(verbatim: value.map { Format.decimal($0) } ?? "—").font(.sistemValue).foregroundStyle(Palette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
