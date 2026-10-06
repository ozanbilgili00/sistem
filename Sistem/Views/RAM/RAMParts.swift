import SistemUI
import SwiftUI
import SystemKit

/// RAM in shades of the one accent blue: app memory strongest, then wired, then
/// compressed. Cached and free are just track.
enum MemoryColors {
    static let app = Palette.accent
    static let wired = Palette.accent.opacity(0.62)
    static let compressed = Palette.accent.opacity(0.34)
    static let cached = UsageColors.idleSwatch
    static let free = UsageColors.track
}

struct RAMUsageSummary: View {
    let sample: MemorySample?
    var ringSize: CGFloat = 96
    var lineWidth: CGFloat = 10

    var body: some View {
        HStack(spacing: 18) {
            UsageRing([
                .init(Double(sample.map { $0.fraction($0.app) } ?? 0), MemoryColors.app),
                .init(Double(sample.map { $0.fraction($0.wired) } ?? 0), MemoryColors.wired),
                .init(Double(sample.map { $0.fraction($0.compressed) } ?? 0), MemoryColors.compressed),
            ], lineWidth: lineWidth) {
                Text(verbatim: Format.percent(sample?.usedFraction))
                    .font(ringSize > 80 ? .sistemBigValue : .sistemValue)
                    .foregroundStyle(Palette.ink)
            }
            .frame(width: ringSize, height: ringSize)

            VStack(spacing: 7) {
                LegendRow("Uygulama", color: MemoryColors.app, value: Format.bytes(sample?.app))
                LegendRow("Bağlı", color: MemoryColors.wired, value: Format.bytes(sample?.wired))
                LegendRow("Sıkıştırılmış", color: MemoryColors.compressed, value: Format.bytes(sample?.compressed))
                LegendRow("Önbellek", color: MemoryColors.cached, value: Format.bytes(sample?.cached))
            }
        }
    }
}

struct RAMHistory: View {
    let store: MetricStore
    var span = MetricStore.historyLength

    var body: some View {
        HistoryChart([
            .init(Array(store.memoryCompressed.values().suffix(span)), MemoryColors.compressed),
            .init(Array(store.memoryWired.values().suffix(span)), MemoryColors.wired),
            .init(Array(store.memoryApp.values().suffix(span)), MemoryColors.app),
        ], capacity: span)
    }
}

/// Pressure, swap and totals: the numbers that say whether memory is a problem.
struct RAMStatusRows: View {
    let sample: MemorySample?

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Bellek baskısı").font(.sistemBody).foregroundStyle(Palette.inkSecondary)
                Spacer()
                pressurePill
            }
            row("Kullanılan", "\(Format.bytes(sample?.used)) / \(Format.bytes(sample?.total))")
            row("Takas", Format.bytes(sample?.swapUsed))
            row("Boş", Format.bytes(sample?.free))
        }
    }

    @ViewBuilder private var pressurePill: some View {
        switch sample?.pressure {
        case .normal: Pill(Text("Normal"), tone: .good)
        case .warning: Pill(Text("Uyarı"), tone: .warning)
        case .critical: Pill(Text("Kritik"), tone: .critical)
        case nil: Pill(Text(verbatim: "—"), tone: .neutral)
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
