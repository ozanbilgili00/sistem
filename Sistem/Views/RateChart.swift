import SistemUI
import SwiftUI
import SystemKit

/// Two speeds over time (download/upload, read/write) on one shared scale. The scale
/// follows the busiest second in view, but never drops below 100 KB/s so background
/// chatter doesn't look like a flood.
struct RateChart: View {
    let first: RingBuffer
    let second: RingBuffer
    var span = MetricStore.historyLength
    var showsPeak = true

    static let minimumPeak: Float = 100_000

    var body: some View {
        let a = Array(first.values().suffix(span))
        let b = Array(second.values().suffix(span))
        let peak = max(a.max() ?? 0, b.max() ?? 0, Self.minimumPeak)
        VStack(alignment: .trailing, spacing: 4) {
            ZStack {
                HistoryChart([.init(a.map { $0 / peak }, UsageColors.user)], capacity: span)
                HistoryChart([.init(b.map { $0 / peak }, Palette.warning.opacity(0.55))], capacity: span, gridLines: false)
            }
            if showsPeak {
                Text("Tepe \(Text(verbatim: Format.rate(Double(peak))))")
                    .font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
            }
        }
    }
}

/// A big readout with a small caption underneath: "12 MB/s" over "Okuma".
struct RateReadout: View {
    let title: LocalizedStringKey
    let bytesPerSecond: Double?
    var color: Color = Palette.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
                Text(title).font(.sistemBody).foregroundStyle(Palette.inkSecondary)
            }
            Text(verbatim: Format.rate(bytesPerSecond)).font(.sistemBigValue).foregroundStyle(Palette.ink)
                .minimumScaleFactor(0.7).lineLimit(1)
        }
    }
}

/// Label on the left, value on the right: the plain row every detail card uses.
struct ValueRow: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        HStack {
            Text(title).font(.sistemBody).foregroundStyle(Palette.inkSecondary)
            Spacer(minLength: 8)
            Text(verbatim: value).font(.sistemValue).foregroundStyle(Palette.ink)
                .multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}
