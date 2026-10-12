import SistemUI
import SwiftUI
import SystemKit

/// The first page: this Mac's hardware and one compact card per module. Every card
/// declares the metric it shows with `.liveMetric`, so nothing is read while the page is
/// not on screen (PLAN.md §3-A); the hardware facts are read once.
struct DashboardPage: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(Text(ModuleID.dashboard.title), subtitle: Text(ModuleID.dashboard.summary))
            HardwareSummary()
            SectionLabel("Modüller")
            ModuleCards(settings: settings)
        }
    }
}

// MARK: Hardware

private struct HardwareSummary: View {
    @Environment(LiveFeed.self) private var feed
    // Read once per view lifetime: a handful of sysctl calls, no polling.
    @State private var info = HardwareInfo.current()
    @State private var form = HardwareInfo.current().formFactor
    @State private var bootDate = HardwareInfo.bootDate()
    @State private var system = HardwareInfo.systemDescription()

    var body: some View {
        let _ = feed.frame  // uptime moves with the tick
        Card {
            HStack(alignment: .center, spacing: 20) {
                DeviceImage(form: form)
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: info.chip).font(.sistemHeading).foregroundStyle(Palette.ink)
                        Text(verbatim: info.modelIdentifier).font(.sistemCaption).foregroundStyle(Palette.inkSecondary)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 6) {
                        GridRow {
                            fact("Çekirdekler", info.clusters.map { "\($0.count) \($0.displayName)" }.joined(separator: " · "))
                            fact("Bellek", info.memoryBytes.formatted(.byteCount(style: .memory)))
                        }
                        GridRow {
                            fact("Sistem", system)
                            fact("Çalışma süresi", uptime)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var uptime: String {
        guard let bootDate else { return "—" }
        let seconds = max(0, Date.now.timeIntervalSince(bootDate))
        return Duration.seconds(seconds).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
    }

    private func fact(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
            Text(verbatim: value).font(.sistemValue).foregroundStyle(Palette.ink).lineLimit(1)
        }
        .gridColumnAlignment(.leading)
    }
}

/// The Mac as an SF Symbol on a quiet tile.
private struct DeviceImage: View {
    let form: MacFormFactor

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 46, weight: .light))
            .foregroundStyle(Palette.accent)
            .frame(width: 104, height: 92)
            .background(Palette.surface2, in: .rect(cornerRadius: Metrics.cardRadius))
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch form {
        case .laptop: "laptopcomputer"
        case .mini: "macmini"
        case .allInOne: "desktopcomputer"
        case .tower: "macpro.gen3"
        case .desktop: "macstudio"
        }
    }
}

// MARK: Module cards

private struct ModuleCards: View {
    @Bindable var settings: SettingsStore
    @Environment(LiveFeed.self) private var feed

    private let columns = [GridItem(.adaptive(minimum: 214), spacing: 14, alignment: .top)]

    var body: some View {
        let _ = feed.frame
        let store = feed.store
        LazyVGrid(columns: columns, spacing: 14) {
            cpu(store)
            gpu(store)
            ram(store)
            disk(store)
            sensors(store)
            network(store)
            battery(store)
            bluetooth(store)
            clock()
        }
        .liveMetric(.cpu)
        .liveMetric(.gpu)
        .liveMetric(.memory)
        .liveMetric(.disk)
        .liveMetric(.temperature)
        .liveMetric(.network)
        .liveMetric(.battery)
        .liveMetric(.bluetooth)
    }

    private func cpu(_ store: MetricStore) -> some View {
        SummaryCard(.cpu, value: Format.percent(store.cpu?.total), detail: Text(verbatim: cpuDetail(store.cpu))) {
            HistoryChart([.init(store.cpuUser.values(), UsageColors.user), .init(store.cpuSystem.values(), UsageColors.system)],
                         capacity: MetricStore.historyLength, gridLines: false)
        }
    }

    private func cpuDetail(_ sample: CPUSample?) -> String {
        guard let sample else { return "—" }
        return "\(String(localized: "Kullanıcı")) \(Format.percent(sample.user)) · \(String(localized: "Sistem")) \(Format.percent(sample.system))"
    }

    private func gpu(_ store: MetricStore) -> some View {
        SummaryCard(.gpu, value: Format.percent(store.gpu?.device),
                    detail: Text(verbatim: store.gpu.map { Format.bytes($0.memoryInUse) } ?? "—")) {
            HistoryChart([.init(store.gpuDevice.values(), UsageColors.user)], capacity: MetricStore.historyLength, gridLines: false)
        }
    }

    private func ram(_ store: MetricStore) -> some View {
        let sample = store.memory
        return SummaryCard(.ram, value: Format.percent(sample?.usedFraction),
                           detail: Text(verbatim: sample.map { "\(Format.bytes($0.used)) / \(Format.bytes($0.total))" } ?? "—"),
                           badge: sample.map { pressurePill($0.pressure) }) {
            HistoryChart([.init(store.memoryApp.values(), UsageColors.user),
                          .init(store.memoryWired.values(), UsageColors.system),
                          .init(store.memoryCompressed.values(), Palette.warning.opacity(0.55))],
                         capacity: MetricStore.historyLength, gridLines: false)
        }
    }

    private func pressurePill(_ pressure: MemorySample.Pressure) -> Pill {
        switch pressure {
        case .normal: Pill(Text("Normal"), tone: .good)
        case .warning: Pill(Text("Uyarı"), tone: .warning)
        case .critical: Pill(Text("Kritik"), tone: .critical)
        }
    }

    private func disk(_ store: MetricStore) -> some View {
        let volume = store.bootVolume ?? store.diskVolumes.first
        let usedFraction = volume.map { 1 - Double($0.available) / Double(max($0.total, 1)) }
        return SummaryCard(.disk, value: volume.map { "\(Format.bytesDecimal($0.available)) \(String(localized: "boş"))" } ?? "—",
                           detail: Text(verbatim: store.disk.map { "↓ \(Format.rate($0.readRate))  ↑ \(Format.rate($0.writeRate))" } ?? "—")) {
            MeterBar(usedFraction ?? 0).frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    private func sensors(_ store: MetricStore) -> some View {
        let unit = settings.temperatureUnit
        let celsius = store.temperature?.headline
        return SummaryCard(.sensors, value: Format.temperature(celsius, unit: unit),
                           detail: Text(verbatim: store.temperature?.gpuHottest.map { "GPU \(Format.temperature($0, unit: unit))" } ?? "—")) {
            HistoryChart([.init(store.cpuTemperature.values().map { $0 / 110 }, UsageColors.user)],
                         capacity: MetricStore.historyLength, gridLines: false)
        }
    }

    private func network(_ store: MetricStore) -> some View {
        let down = store.networkDown.values()
        let peak = max(down.max() ?? 0, 1)
        return SummaryCard(.network, value: "↓ \(Format.rate(store.network?.down))",
                           detail: Text(verbatim: "↑ \(Format.rate(store.network?.up))"),
                           badge: store.path.map { $0.isConnected ? Pill(Text("Bağlı"), tone: .good) : Pill(Text("Bağlı değil"), tone: .critical) }) {
            HistoryChart([.init(down.map { $0 / peak }, UsageColors.user)], capacity: MetricStore.historyLength, gridLines: false)
        }
    }

    private func battery(_ store: MetricStore) -> some View {
        let sample = store.battery?.sample
        let fraction = sample.map { Double($0.percent) / 100 } ?? 0
        return SummaryCard(.battery, value: sample.map { Format.percent(Float($0.percent) / 100) } ?? "—",
                           detail: sample.map { Text(BatteryText.timeLine($0)) }
                               ?? Text(store.battery == nil ? "Okunuyor…" : "Bu Mac'te batarya yok.")) {
            if sample != nil { MeterBar(fraction).frame(maxHeight: .infinity, alignment: .bottom) }
        }
    }

    private func bluetooth(_ store: MetricStore) -> some View {
        let sample = store.bluetooth
        let connected = sample?.connected ?? []
        let lowest = connected.compactMap(\.lowestBattery).min()
        return SummaryCard(.bluetooth, value: sample == nil ? "—" : "\(connected.count)",
                           detail: sample == nil ? Text("Okunuyor…")
                               : lowest.map { Text("En düşük pil \(Format.percent(Float($0) / 100))") } ?? Text("Bağlı cihaz")) {
            EmptyView()
        }
    }

    private func clock() -> some View {
        SummaryCard(.clock, value: Date.now.formatted(date: .omitted, time: .shortened),
                    detail: Text(verbatim: Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))) {
            EmptyView()
        }
    }
}

/// One module: icon and name, the figure that matters, a line under it, and a small chart.
/// Tapping opens the module's page.
private struct SummaryCard<Chart: View>: View {
    @Environment(\.openPage) private var openPage
    let module: ModuleID
    let value: String
    let detail: Text
    let badge: Pill?
    let chart: Chart

    init(_ module: ModuleID, value: String, detail: Text, badge: Pill? = nil, @ViewBuilder chart: () -> Chart) {
        self.module = module
        self.value = value
        self.detail = detail
        self.badge = badge
        self.chart = chart()
    }

    var body: some View {
        Button { openPage.go(.module(module)) } label: {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: module.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.inkTertiary)
                        Text(module.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
                        Spacer(minLength: 0)
                        if let badge { badge }
                    }
                    .frame(minHeight: 20)
                    Text(verbatim: value)
                        .font(.sistemBigValue).foregroundStyle(Palette.ink)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    detail.font(.sistemCaption).foregroundStyle(Palette.inkSecondary).lineLimit(1)
                    chart
                        .frame(height: 34)
                        .background(Palette.surface2.opacity(0.5), in: .rect(cornerRadius: 5))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}
