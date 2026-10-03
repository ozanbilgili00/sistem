import SistemUI
import SwiftUI
import SystemKit

/// Sistem measuring itself. Samples once a second, and only while this page is on
/// screen — the `.task` is cancelled when the page goes away.
struct DiagnosticsView: View {
    @State private var rate: UsageRate?

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
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1), tolerance: .milliseconds(250))
                guard let now = ProcessUsage.current() else { return }
                rate = now.rate(since: last)
                last = now
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
