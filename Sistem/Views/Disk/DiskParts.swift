import SistemUI
import SwiftUI
import SystemKit

/// Read and write speed side by side, with operations per second underneath.
struct DiskThroughputSummary: View {
    let sample: DiskSample?
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            HStack(alignment: .top, spacing: 16) {
                RateReadout(title: "Okuma", bytesPerSecond: sample?.readRate, color: UsageColors.user)
                    .frame(maxWidth: .infinity, alignment: .leading)
                RateReadout(title: "Yazma", bytesPerSecond: sample?.writeRate, color: Palette.warning.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !compact, let sample {
                Text("\(Text(verbatim: Format.integer(UInt64(sample.readOps)))) okuma/sn · \(Text(verbatim: Format.integer(UInt64(sample.writeOps)))) yazma/sn")
                    .font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
            }
        }
    }
}

struct DiskHistory: View {
    let store: MetricStore
    var span = MetricStore.historyLength

    var body: some View {
        RateChart(first: store.diskRead, second: store.diskWrite, span: span)
    }
}

/// One mounted volume: name, kind, a capacity gauge and the free/total numbers.
struct DiskVolumeRow: View {
    let volume: DiskVolume

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(verbatim: volume.name).font(.sistemBody).foregroundStyle(Palette.ink).lineLimit(1)
                Pill(Text(volume.kind.title), tone: .neutral)
                Spacer(minLength: 8)
                Text(verbatim: Format.percent(volume.usedFraction)).font(.sistemValue).foregroundStyle(Palette.ink)
            }
            MeterBar(Double(volume.usedFraction), color: volume.usedFraction > 0.9 ? Palette.warning : Palette.accent)
            HStack {
                Text("\(Text(verbatim: Format.bytesDecimal(volume.available))) boş")
                Spacer()
                Text(verbatim: [volume.format, Format.bytesDecimal(volume.total)].compactMap { $0 }.joined(separator: " · "))
            }
            .font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
        }
    }
}

struct DiskVolumeList: View {
    let volumes: [DiskVolume]
    var limit: Int?

    var body: some View {
        let shown = limit.map { Array(volumes.prefix($0)) } ?? volumes
        VStack(spacing: 14) {
            if shown.isEmpty {
                Text("Birimler okunuyor…").font(.sistemBody).foregroundStyle(Palette.inkTertiary)
            }
            ForEach(shown) { DiskVolumeRow(volume: $0) }
        }
    }
}

extension DiskVolume.Kind {
    var title: LocalizedStringResource {
        switch self {
        case .internalDisk: "Dahili"
        case .external: "Harici"
        case .removable: "Çıkarılabilir"
        case .network: "Ağ"
        }
    }
}

/// SMART summary of the internal SSD. The drive's own wear and spare-block figures,
/// the totals it has written and read, and the usual error counters.
struct DiskHealthRows: View {
    let health: DiskHealth?

    var body: some View {
        if let health {
            VStack(spacing: 8) {
                HStack {
                    Text("Durum").font(.sistemBody).foregroundStyle(Palette.inkSecondary)
                    Spacer()
                    if health.isHealthy {
                        Pill(Text("Sağlıklı"), tone: .good)
                    } else {
                        Pill(Text("Dikkat"), tone: .warning)
                    }
                }
                ValueRow(title: "Harcanan ömür", value: Format.percent(Float(health.percentageUsed) / 100))
                ValueRow(title: "Yedek alan", value: Format.percent(Float(health.availableSpare) / 100))
                if let temperature = health.temperatureCelsius {
                    ValueRow(title: "Sıcaklık", value: "\(Format.decimal(temperature, digits: 0)) °C")
                }
                ValueRow(title: "Toplam yazılan", value: Format.bytesDecimal(health.bytesWritten))
                ValueRow(title: "Toplam okunan", value: Format.bytesDecimal(health.bytesRead))
                ValueRow(title: "Açık kalma süresi", value: "\(Format.integer(health.powerOnHours)) \(String(localized: "sa"))")
                ValueRow(title: "Güç döngüsü", value: Format.integer(health.powerCycles))
                ValueRow(title: "Güvenli olmayan kapanış", value: Format.integer(health.unsafeShutdowns))
                ValueRow(title: "Ortam hatası", value: Format.integer(health.mediaErrors))
            }
        } else {
            Text("Sağlık verisi yok: bu disk SMART bilgisi vermiyor ya da henüz okunmadı.")
                .font(.sistemBody).foregroundStyle(Palette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
