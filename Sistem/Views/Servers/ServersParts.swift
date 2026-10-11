import SistemUI
import SwiftUI
import SystemKit

/// One server: name and state, then either its numbers or the reason there are none, then its tunnels.
struct ServerCard: View {
    let runtime: ServerRuntime
    let model: ServersModel
    var compact = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                header
                switch runtime.phase {
                case .online:
                    if let metrics = runtime.metrics { ServerMetricsView(metrics: metrics, kind: runtime.config.kind, compact: compact) }
                case .failed(let failure):
                    ServerFailureView(failure: failure, config: runtime.config, model: model)
                case .connecting:
                    Text("Bağlanıyor…").font(.sistemBody).foregroundStyle(Palette.inkSecondary)
                case .reachable:
                    Text("Sunucu yanıt veriyor. Ayrıntılar bu sayfa açıkken okunur.").font(.sistemCaption).foregroundStyle(Palette.inkSecondary)
                case .idle:
                    Text("Ayrıntılar bu sayfa ya da açılır pencere açıkken okunur.").font(.sistemCaption).foregroundStyle(Palette.inkSecondary)
                }
                if !compact, !runtime.config.tunnels.isEmpty {
                    Rectangle().fill(Palette.line).frame(height: 1)
                    TunnelList(runtime: runtime, model: model)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: ServersText.symbol(runtime.config.kind))
                .font(.system(size: 18, weight: .medium)).foregroundStyle(Palette.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: runtime.config.name).font(.sistemHeading).foregroundStyle(Palette.ink).lineLimit(1)
                Text(ServersText.kind(runtime.config.kind)).font(.sistemCaption).foregroundStyle(Palette.inkSecondary)
            }
            Spacer(minLength: 8)
            if runtime.isDown { Pill(Text("Kapalı bildirildi"), tone: .critical) }
            Pill(Text(ServersText.phase(runtime.phase)), tone: ServersText.tone(runtime.phase))
            if runtime.config.kind.usesSSH, !compact {
                Button { model.connect(host: runtime.config.host, user: runtime.config.user, port: runtime.config.port) } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(QuietButtonStyle())
                .help("Terminal'de bağlan")
            }
        }
    }
}

struct ServerMetricsView: View {
    let metrics: ServerMetrics
    let kind: ServerKind
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if kind == .docker || kind == .localDocker {
                ContainerList(containers: metrics.containers, compact: compact)
            } else {
                bar("CPU", metrics.cpu, detail: metrics.cores.map { String(localized: "\($0) çekirdek") })
                bar("Bellek", metrics.memoryFraction, detail: memoryDetail)
                if metrics.swapTotal ?? 0 > 0 {
                    bar("Takas", metrics.swapTotal.flatMap { $0 > 0 ? Double(metrics.swapUsed ?? 0) / Double($0) : nil }, detail: nil)
                }
                bar("Disk", metrics.diskFraction, detail: diskDetail)
                if !compact {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                        GridRow {
                            readout("Yük", ServersText.load(metrics.load))
                            readout("Çalışma süresi", ServersText.uptime(metrics.uptime))
                            readout("Ağ", "↓ \(Format.rate(metrics.receiveRate))  ↑ \(Format.rate(metrics.sendRate))")
                        }
                    }
                }
            }
        }
    }

    private var memoryDetail: String? {
        guard let used = metrics.memoryUsed, let total = metrics.memoryTotal else { return nil }
        return "\(Format.bytes(used)) / \(Format.bytes(total))"
    }

    private var diskDetail: String? {
        guard let used = metrics.diskUsed, let total = metrics.diskTotal else { return nil }
        return "\(Format.bytes(used)) / \(Format.bytes(total))"
    }

    private func bar(_ title: LocalizedStringKey, _ fraction: Double?, detail: String?) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.sistemBody).foregroundStyle(Palette.ink).frame(width: 64, alignment: .leading)
            MeterBar(fraction ?? 0).frame(height: 8).opacity(fraction == nil ? 0.35 : 1)
            Text(verbatim: ServersText.percent(fraction)).font(.sistemValue).foregroundStyle(Palette.inkSecondary).frame(width: 52, alignment: .trailing)
            if let detail, !compact { Text(verbatim: detail).font(.sistemCaption).foregroundStyle(Palette.inkTertiary).frame(width: 130, alignment: .trailing) }
        }
    }

    private func readout(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel(title)
            Text(verbatim: value).font(.sistemValue).foregroundStyle(Palette.ink).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ContainerList: View {
    let containers: [ContainerReading]
    var compact = false

    var body: some View {
        if containers.isEmpty {
            Text("Çalışan konteyner yok.").font(.sistemBody).foregroundStyle(Palette.inkSecondary)
        } else {
            VStack(spacing: 6) {
                ForEach(containers.prefix(compact ? 6 : 50)) { container in
                    HStack(spacing: 10) {
                        Text(verbatim: container.name).font(.sistemBody).foregroundStyle(Palette.ink).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(verbatim: container.cpuPercent.map { "\(Int($0.rounded())) %" } ?? "—").font(.sistemValue).foregroundStyle(Palette.inkSecondary)
                        Text(verbatim: Format.bytes(container.memoryUsed)).font(.sistemValue).foregroundStyle(Palette.inkSecondary).frame(width: 90, alignment: .trailing)
                    }
                }
            }
        }
    }
}

/// Why a server has no numbers, in words, and the one thing that can be done about it.
struct ServerFailureView: View {
    let failure: RemoteFailure
    let config: ServerConfig
    let model: ServersModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ServersText.failureDetail(failure)).font(.sistemBody).foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if ServersText.needsTerminal(failure), config.kind.usesSSH {
                Button("Terminal'de bağlan") { model.connect(host: config.host, user: config.user, port: config.port) }
                    .buttonStyle(AccentButtonStyle())
            }
        }
    }
}

struct TunnelList: View {
    let runtime: ServerRuntime
    let model: ServersModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Tüneller")
            ForEach(runtime.config.tunnels) { tunnel in
                let status = runtime.tunnels[tunnel.id] ?? TunnelStatus()
                HStack(spacing: 10) {
                    Text(ServersText.tunnelKind(tunnel.kind)).font(.sistemBody).foregroundStyle(Palette.ink).frame(width: 90, alignment: .leading)
                    Text(verbatim: ServersText.tunnelSummary(tunnel)).font(.sistemValue).foregroundStyle(Palette.inkSecondary).lineLimit(1)
                    Spacer(minLength: 8)
                    Pill(Text(ServersText.tunnelPhase(status)), tone: ServersText.tunnelTone(status))
                    let active = status.phase != .stopped
                    Button(active ? "Kapat" : "Aç") {
                        if active { model.stopTunnel(tunnel.id) } else { model.startTunnel(runtime.id, tunnel.id) }
                    }
                    .buttonStyle(QuietButtonStyle())
                }
            }
        }
    }
}
