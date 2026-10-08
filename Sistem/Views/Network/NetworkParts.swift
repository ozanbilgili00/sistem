import SistemUI
import SwiftUI
import SystemKit

/// Download and upload side by side, with the running totals underneath.
struct NetworkThroughputSummary: View {
    let sample: NetworkSample?
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            HStack(alignment: .top, spacing: 16) {
                RateReadout(title: "İndirme", bytesPerSecond: sample?.down, color: UsageColors.user)
                    .frame(maxWidth: .infinity, alignment: .leading)
                RateReadout(title: "Yükleme", bytesPerSecond: sample?.up, color: Palette.warning.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !compact, let sample {
                Text("Açılıştan beri \(Text(verbatim: Format.bytesDecimal(sample.totalDown))) indirildi · \(Text(verbatim: Format.bytesDecimal(sample.totalUp))) yüklendi")
                    .font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
            }
        }
    }
}

struct NetworkHistory: View {
    let store: MetricStore
    var span = MetricStore.historyLength

    var body: some View {
        RateChart(first: store.networkDown, second: store.networkUp, span: span)
    }
}

extension NetworkInterfaceType {
    var title: LocalizedStringResource {
        switch self {
        case .wifi: "Wi-Fi"
        case .wired: "Ethernet"
        case .cellular: "Hücresel"
        case .other: "Diğer"
        }
    }
}

/// Connected or not, over which kind of link, plus cost flags.
struct ConnectionSummary: View {
    let path: PathState?

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Durum").font(.sistemBody).foregroundStyle(Palette.inkSecondary)
                Spacer()
                if let path {
                    switch path.status {
                    case .satisfied: Pill(Text("Bağlı"), tone: .good)
                    case .requiresConnection: Pill(Text("Bağlantı bekleniyor"), tone: .warning)
                    case .unsatisfied: Pill(Text("Bağlı değil"), tone: .critical)
                    }
                } else {
                    Pill(Text("Okunuyor…"), tone: .neutral)
                }
            }
            if let primary = path?.primary {
                HStack {
                    Text("Bağlantı türü").font(.sistemBody).foregroundStyle(Palette.inkSecondary)
                    Spacer()
                    Text(primary.type.title).font(.sistemValue).foregroundStyle(Palette.ink)
                }
                ValueRow(title: "Arayüz", value: primary.name)
            }
            if let path, path.isConnected {
                ValueRow(title: "Protokoller", value: protocols(path))
                if path.isExpensive { ValueRow(title: "Tarife", value: String(localized: "Sınırlı veri")) }
                if path.isConstrained { ValueRow(title: "Düşük veri modu", value: String(localized: "Açık")) }
            }
        }
    }

    private func protocols(_ path: PathState) -> String {
        [path.supportsIPv4 ? "IPv4" : nil, path.supportsIPv6 ? "IPv6" : nil].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Every interface that is up with its speed and local addresses.
struct InterfaceList: View {
    let sample: NetworkSample?
    let addresses: [LocalAddress]
    let path: PathState?
    var limit: Int?

    var body: some View {
        let all = sample?.interfaces ?? []
        let shown = limit.map { Array(all.prefix($0)) } ?? all
        VStack(spacing: 14) {
            if shown.isEmpty {
                Text("Arayüzler okunuyor…").font(.sistemBody).foregroundStyle(Palette.inkTertiary)
            }
            ForEach(shown) { rate in
                let type = path?.interfaces.first { $0.name == rate.name }?.type
                VStack(spacing: 4) {
                    HStack(spacing: 8) {
                        Text(verbatim: rate.name).font(.sistemBody).foregroundStyle(Palette.ink)
                        if let type { Pill(Text(type.title), tone: .neutral) }
                        if rate.name == sample?.primary { Pill(Text("Varsayılan"), tone: .accent) }
                        Spacer(minLength: 8)
                        Text(verbatim: "↓ \(Format.rate(rate.down))  ↑ \(Format.rate(rate.up))")
                            .font(.sistemCaption).foregroundStyle(Palette.inkSecondary)
                    }
                    ForEach(addresses.filter { $0.interface == rate.name }) { address in
                        HStack {
                            Text(verbatim: address.address).font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
                                .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                            Spacer()
                        }
                    }
                }
            }
        }
    }
}

/// Link quality from CoreWLAN. The network name needs Location Services, which is
/// asked for only when the user presses the button.
struct WiFiCardContent: View {
    let wifi: WiFiSample?
    let location: LocationAccess.State
    let requestLocation: () -> Void

    var body: some View {
        if let wifi {
            VStack(spacing: 8) {
                if !wifi.isPoweredOn {
                    Pill(Text("Wi-Fi kapalı"), tone: .neutral)
                } else if !wifi.isAssociated {
                    Pill(Text("Ağa bağlı değil"), tone: .neutral)
                } else {
                    nameRow(wifi)
                    if let quality = wifi.quality {
                        HStack {
                            Text("Sinyal").font(.sistemBody).foregroundStyle(Palette.inkSecondary)
                            Spacer()
                            Pill(Text(quality.title), tone: quality.tone)
                        }
                    }
                    if let rssi = wifi.rssi { ValueRow(title: "Sinyal gücü (RSSI)", value: "\(rssi) dBm") }
                    if let noise = wifi.noise { ValueRow(title: "Gürültü", value: "\(noise) dBm") }
                    if let snr = wifi.signalToNoise { ValueRow(title: "Sinyal/gürültü", value: "\(snr) dB") }
                    if let channel = wifi.channel {
                        ValueRow(title: "Kanal", value: [String(channel), wifi.band?.title].compactMap { $0 }.joined(separator: " · "))
                    }
                    if let rate = wifi.transmitRate {
                        ValueRow(title: "Bağlantı hızı", value: "\(Format.decimal(rate, digits: 0)) Mbit/sn")
                    }
                }
            }
        } else {
            Text("Bu Mac'te Wi-Fi arayüzü yok.").font(.sistemBody).foregroundStyle(Palette.inkTertiary)
        }
    }

    @ViewBuilder private func nameRow(_ wifi: WiFiSample) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Ağ adı").font(.sistemBody).foregroundStyle(Palette.inkSecondary)
            Spacer(minLength: 8)
            if let ssid = wifi.ssid {
                Text(verbatim: ssid).font(.sistemValue).foregroundStyle(Palette.ink).lineLimit(1).textSelection(.enabled)
            } else {
                switch location {
                case .notDetermined:
                    Button("Ağ adını göster", action: requestLocation).buttonStyle(QuietButtonStyle())
                case .denied:
                    Text("Konum izni verilmedi").font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
                case .authorized:
                    Text("Okunuyor…").font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
                }
            }
        }
        if location == .notDetermined && wifi.ssid == nil {
            Text("macOS, ağ adını yalnızca Konum Servisleri izniyle paylaşıyor. Konum bu uygulamada başka hiçbir şey için kullanılmaz ve hiçbir yere gönderilmez.")
                .font(.sistemCaption).foregroundStyle(Palette.inkTertiary).fixedSize(horizontal: false, vertical: true)
        } else if location == .denied && wifi.ssid == nil {
            Text("İzni Sistem Ayarları > Gizlilik ve Güvenlik > Konum Servisleri bölümünden verebilirsin.")
                .font(.sistemCaption).foregroundStyle(Palette.inkTertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension WiFiSample.Quality {
    var title: LocalizedStringResource {
        switch self {
        case .poor: "Zayıf"
        case .fair: "Orta"
        case .good: "İyi"
        case .excellent: "Çok iyi"
        }
    }

    var tone: Pill.Tone {
        switch self {
        case .poor: .critical
        case .fair: .warning
        case .good, .excellent: .good
        }
    }
}

extension WiFiSample.Band {
    var title: String {
        switch self {
        case .ghz2_4: "2,4 GHz"
        case .ghz5: "5 GHz"
        case .ghz6: "6 GHz"
        }
    }
}

/// Connect / disconnect / interface-change events since the app started.
struct ConnectionHistoryList: View {
    let events: [ConnectionEvent]
    var limit = 8

    var body: some View {
        VStack(spacing: 8) {
            if events.isEmpty {
                Text("Açılıştan beri bağlantı değişikliği yok.").font(.sistemBody).foregroundStyle(Palette.inkTertiary)
            }
            ForEach(events.prefix(limit)) { event in
                HStack(spacing: 8) {
                    Text(event.date, format: .dateTime.hour().minute().second())
                        .font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
                    Text(event.kind.title).font(.sistemBody).foregroundStyle(Palette.ink)
                    Spacer(minLength: 8)
                    if let interface = event.interface {
                        Text("\(Text(interface.type.title)) · \(Text(verbatim: interface.name))")
                            .font(.sistemCaption).foregroundStyle(Palette.inkSecondary)
                    }
                }
            }
        }
    }
}

extension ConnectionEvent.Kind {
    var title: LocalizedStringResource {
        switch self {
        case .connected: "Bağlandı"
        case .disconnected: "Bağlantı koptu"
        case .interfaceChanged: "Arayüz değişti"
        }
    }
}

/// Public address and latency; each row exists only while its setting is on.
struct NetworkExtrasRows: View {
    let publicIP: PublicIPState
    let latency: LatencyState

    var body: some View {
        VStack(spacing: 8) {
            switch publicIP {
            case .off: EmptyView()
            case .fetching: ValueRow(title: "Genel IP", value: "…")
            case .address(let address, _): ValueRow(title: "Genel IP", value: address)
            case .failed: ValueRow(title: "Genel IP", value: String(localized: "Alınamadı"))
            }
            switch latency {
            case .off: EmptyView()
            case .measured(let milliseconds, _): ValueRow(title: "Gecikme", value: "\(Format.decimal(milliseconds, digits: 0)) ms")
            case .failed: ValueRow(title: "Gecikme", value: String(localized: "Ölçülemedi"))
            }
        }
    }

    var isEmpty: Bool { publicIP == .off && latency == .off }
}
