import SistemUI
import SwiftUI
import SystemKit

/// Sistem measuring itself. Samples once a second, and only while this page is on
/// screen — the `.task` is cancelled when the page goes away.
struct DiagnosticsView: View {
    @State private var rate: UsageRate?
    @State private var redrawsPerMinute: Double?
    @Environment(LiveFeed.self) private var feed

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(Text("Tanılama"), subtitle: Text("Sistem'in kendi kaynak tüketimi, bu sayfa açıkken canlı ölçülür."))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                tile("CPU", value: rate.map { String(format: "%.2f", $0.cpuPercent) }, unit: "%",
                     limit: EnergyBudget.windowCPUPercent, current: rate?.cpuPercent)
                tile("Bellek", value: rate.map { String(format: "%.1f", $0.footprintMB) }, unit: "MB",
                     limit: EnergyBudget.windowFootprintMB, current: rate?.footprintMB)
                tile("Uyanma", value: rate.map { String(format: "%.1f", $0.wakeupsPerSecond) }, unit: "/sn",
                     note: "Boşta hedef: saniyede 2'nin altı")
                tile("Güç", value: rate.map { String(format: "%.1f", $0.milliwatts) }, unit: "mW",
                     note: "Süreç enerji sayacından")
            }

            // Values, not the engine: re-read on every `rate` update above.
            SamplerCard(config: feed.engine?.config, power: feed.engine?.power.state, redrawsPerMinute: redrawsPerMinute)

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Not")
                    Text("Bu sayfa açıkken ölçüm saniyede bir yapılır ve değerler sayfanın kendi maliyetini de içerir. Gerçek boşta tüketim için `scripts/perf-check.sh` kullanılır.")
                        .font(.sistemCaption)
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
        }
        .task {
            guard var last = ProcessUsage.current() else { return }
            var redraws: [(Date, Int)] = [(.now, MenuBarStats.redraws)]
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1), tolerance: .milliseconds(250))
                guard let now = ProcessUsage.current() else { return }
                rate = now.rate(since: last)
                last = now
                // Sliding one-minute window over the redraw counter.
                redraws.append((.now, MenuBarStats.redraws))
                redraws.removeAll { $0.0 < .now - 60 }
                if let first = redraws.first, let latest = redraws.last, latest.0 > first.0 {
                    redrawsPerMinute = Double(latest.1 - first.1) / latest.0.timeIntervalSince(first.0) * 60
                }
            }
        }
    }

    private func tile(_ title: LocalizedStringKey, value: String?, unit: LocalizedStringKey,
                      limit: Double? = nil, current: Double? = nil, note: LocalizedStringKey? = nil) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(title)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value ?? "—").font(.sistemBigValue).foregroundStyle(Palette.ink).monospacedDigit()
                    Text(unit).font(.sistemValue).foregroundStyle(Palette.inkSecondary)
                }
                if let limit {
                    let within = (current ?? 0) < limit
                    Pill(Text("Bütçe < \(limit.formatted()) \(Text(unit))"), tone: current == nil ? .neutral : (within ? .good : .critical))
                } else if let note {
                    Text(note).font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
                }
            }
            // Equal heights whether a tile ends in a pill or a caption, so the grid's
            // rows line up.
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        }
    }
}

/// What the sampler is doing right now and why. nil in offscreen snapshots.
private struct SamplerCard: View {
    let config: SamplerConfig?
    let power: PowerPolicy.State?
    let redrawsPerMinute: Double?

    var body: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                SettingRow("Örnekleyici") {
                    Pill(Text(statusText), tone: config?.isIdle == false ? .good : .neutral)
                }
                RowDivider()
                SettingRow("Etkin aralık", detail: "Ayardaki aralık × güç politikası çarpanı.") {
                    Text(verbatim: config.map { "\(Format.decimal($0.interval, digits: 0)) sn" } ?? "—")
                        .font(.sistemValue).foregroundStyle(Palette.ink)
                }
                RowDivider()
                SettingRow("Okunan metrikler", detail: "Tüketicisi olmayan metrik okunmaz.") {
                    Text(verbatim: metricsText).font(.sistemValue).foregroundStyle(Palette.ink)
                }
                RowDivider()
                SettingRow("Menü çubuğu çizimi", detail: "Her çizim her ekranın menü çubuğu için ayrı yapılır; boştaki maliyetin çoğu buradan gelir.") {
                    Text(verbatim: redrawsPerMinute.map { "\(Format.decimal($0, digits: 1)) /dk" } ?? "—")
                        .font(.sistemValue).foregroundStyle(Palette.ink)
                }
                RowDivider()
                SettingRow("Güç durumu") {
                    Text(verbatim: powerText).font(.sistemValue).foregroundStyle(Palette.ink)
                }
            }
        }
    }

    private var statusText: LocalizedStringKey {
        guard let config else { return "Önizleme" }
        if config.paused { return "Duraklatıldı" }
        return config.metrics.isEmpty ? "Uyuyor" : "Çalışıyor"
    }

    private var metricsText: String {
        guard let config, !config.metrics.isEmpty else { return "—" }
        return config.metrics.map(\.rawValue).sorted().joined(separator: ", ")
    }

    private var powerText: String {
        guard let power else { return "—" }
        var parts = [power.onBattery ? String(localized: "Pil") : String(localized: "Adaptör")]
        if power.lowPowerMode { parts.append(String(localized: "Düşük Güç")) }
        if power.thermal != .nominal { parts.append(String(localized: "Isıl baskı")) }
        return parts.joined(separator: " · ")
    }
}
