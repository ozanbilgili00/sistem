import SistemUI
import SwiftUI
import SystemKit

struct ServersPage: View {
    @Bindable var settings: SettingsStore
    @State private var tab: ModuleTab

    init(settings: SettingsStore, tab: ModuleTab = .overview) {
        self.settings = settings
        _tab = State(initialValue: tab == .widgets ? .overview : tab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ModulePageHeader(module: .servers, tab: $tab, showsWidgets: false)
            switch tab {
            case .overview, .widgets: ServersOverview(settings: settings)
            case .module: ServersModuleSettings(settings: settings)
            }
        }
    }
}

private struct ServersOverview: View {
    let settings: SettingsStore
    @Environment(ServersModel.self) private var model

    var body: some View {
        let state = model.state
        VStack(alignment: .leading, spacing: 14) {
            if !settings.serversEnabled {
                Card { Text("Sunucular modülü kapalı. Modül sekmesinden açabilirsiniz.").font(.sistemBody).foregroundStyle(Palette.inkSecondary) }
            } else {
                if state.servers.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Henüz sunucu eklenmedi.").font(.sistemHeading).foregroundStyle(Palette.ink)
                            Text("Modül sekmesinden bir sunucu ekleyin. Giriş yalnızca anahtar ya da ssh-agent ile yapılır; parola sorulmaz ve saklanmaz.")
                                .font(.sistemBody).foregroundStyle(Palette.inkSecondary)
                        }
                    }
                }
                ForEach(state.servers) { runtime in ServerCard(runtime: runtime, model: model) }
                QuickConnectCard(model: model)
                Text("Sunucular yalnızca bu sayfa ya da açılır pencere görünürken, her 4 saniyede bir tek ssh bağlantısı üzerinden okunur. Arka plan kontrolü kapalıysa sayfa kapanınca hiçbir bağlantı kurulmaz.")
                    .font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
            }
        }
        .onAppear { model.viewAppeared() }
        .onDisappear { model.viewDisappeared() }
    }
}

/// Aliases from `~/.ssh/config`: a click opens Terminal with `ssh <alias>`.
struct QuickConnectCard: View {
    let model: ServersModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel("Hızlı bağlan")
                    Spacer()
                    Button("Listeyi yenile") { model.loadAliases() }.buttonStyle(QuietButtonStyle())
                }
                if model.aliases.isEmpty {
                    Text("~/.ssh/config içindeki Host takma adları burada listelenir. Dosya yalnızca okunur; yalnızca takma adlar alınır.")
                        .font(.sistemCaption).foregroundStyle(Palette.inkSecondary)
                } else {
                    Text("\(model.aliases.count) takma ad").font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                        ForEach(model.aliases, id: \.self) { alias in
                            Button { model.connect(host: alias) } label: {
                                Label { Text(verbatim: alias).lineLimit(1) } icon: { Image(systemName: "terminal") }
                            }
                            .buttonStyle(QuietButtonStyle())
                        }
                    }
                }
                if model.quickConnectFailed {
                    Text("Terminal açılamadı.").font(.sistemCaption).foregroundStyle(Palette.warning)
                }
            }
        }
        .onAppear { if model.aliases.isEmpty { model.loadAliases() } }
    }
}

private struct ServersModuleSettings: View {
    @Bindable var settings: SettingsStore
    @State private var name = ""
    @State private var kind = ServerKind.linux
    @State private var host = ""
    @State private var user = ""
    @State private var port = ""
    @State private var issue: ServerFormIssue?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Card(padding: 0) {
                VStack(spacing: 0) {
                    SettingRow("Sunucular modülünü etkinleştir", detail: "Kapalıyken hiçbir bağlantı kurulmaz ve tüneller kapanır.") {
                        Toggle("Sunucular modülünü etkinleştir", isOn: $settings.serversEnabled).labelsHidden().toggleStyle(.switch)
                    }
                    RowDivider()
                    SettingRow("Arka planda erişilebilirlik kontrolü", detail: "Her 60 saniyede bir sunucunun yanıt verip vermediğine bakar ve iki dakika kapalı kalırsa bildirim gönderir. Kapalıyken sayfa kapanınca hiçbir şey çalışmaz.") {
                        Toggle("Arka planda erişilebilirlik kontrolü", isOn: $settings.serversReachability).labelsHidden().toggleStyle(.switch)
                            .disabled(!settings.serversEnabled)
                    }
                    RowDivider()
                    SettingRow("Menü çubuğunda göster", detail: "Sunucu simgesi ekler; tıklayınca sunucuların özeti açılır.") {
                        Toggle("Menü çubuğunda göster", isOn: $settings.serversMenuBar).labelsHidden().toggleStyle(.switch)
                            .disabled(!settings.serversEnabled)
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Güvenlik")
                    Text("Giriş yalnızca anahtar ya da ssh-agent iledir; parola istenmez, saklanmaz. Özel anahtar dosyalarına dokunulmaz. Ana makine anahtarı doğrulaması her zaman açıktır: bilinmeyen bir sunucuya önce Terminal'den bir kez bağlanmalısınız. Yerel ağdaki sunucular için macOS ilk bağlantıda Yerel Ağ izni sorabilir.")
                        .font(.sistemBody).foregroundStyle(Palette.inkSecondary)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel("Sunucular")
                    let servers = settings.servers
                    if servers.isEmpty { Text("Henüz sunucu yok.").font(.sistemBody).foregroundStyle(Palette.inkSecondary) }
                    ForEach(servers) { server in ServerEditorRow(server: server, settings: settings) }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Sunucu ekle")
                    HStack(spacing: 10) {
                        TextField("Ad", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                        Picker("Tür", selection: $kind) {
                            ForEach(ServerKind.allCases) { Text(ServersText.kind($0)).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    if kind.usesSSH {
                        HStack(spacing: 10) {
                            TextField("Ana makine ya da takma ad", text: $host).textFieldStyle(.roundedBorder)
                            TextField("Kullanıcı (isteğe bağlı)", text: $user).textFieldStyle(.roundedBorder).frame(maxWidth: 170)
                            TextField("Port", text: $port).textFieldStyle(.roundedBorder).frame(width: 70)
                        }
                    }
                    HStack {
                        Button("Ekle", action: add).buttonStyle(AccentButtonStyle())
                        if let issue { Text(ServersText.addError(issue)).font(.sistemCaption).foregroundStyle(Palette.warning) }
                    }
                }
            }
        }
    }

    private func add() {
        switch ServerForm.make(name: name, kind: kind, host: host, user: user, port: port, existing: settings.servers.count) {
        case .failure(let found):
            issue = found
        case .success(let server):
            settings.servers = settings.servers + [server]
            issue = nil
            name = ""; host = ""; user = ""; port = ""
        }
    }
}

private struct ServerEditorRow: View {
    let server: ServerConfig
    @Bindable var settings: SettingsStore
    @State private var showTunnelForm = false
    @State private var tunnelKind = TunnelSpec.Kind.local
    @State private var listen = ""
    @State private var targetHost = "127.0.0.1"
    @State private var targetPort = ""
    @State private var issue: TunnelFormIssue?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: ServersText.symbol(server.kind)).foregroundStyle(Palette.accent).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: server.name).font(.sistemBody).foregroundStyle(Palette.ink)
                    Text(verbatim: summary).font(.sistemCaption).foregroundStyle(Palette.inkTertiary).lineLimit(1)
                }
                Spacer()
                if server.kind.usesSSH { Button("Tünel ekle") { showTunnelForm.toggle() }.buttonStyle(QuietButtonStyle()) }
                Button("Sil") { settings.servers = settings.servers.filter { $0.id != server.id } }.buttonStyle(QuietButtonStyle())
            }
            ForEach(server.tunnels) { tunnel in
                HStack {
                    Text(ServersText.tunnelKind(tunnel.kind)).font(.sistemCaption).foregroundStyle(Palette.inkSecondary).frame(width: 90, alignment: .leading)
                    Text(verbatim: ServersText.tunnelSummary(tunnel)).font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
                    Spacer()
                    Button("Kaldır") { update { $0.tunnels.removeAll { $0.id == tunnel.id } } }.buttonStyle(QuietButtonStyle())
                }
                .padding(.leading, 32)
            }
            if showTunnelForm {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Picker("Tür", selection: $tunnelKind) {
                            ForEach(TunnelSpec.Kind.allCases) { Text(ServersText.tunnelKind($0)).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        TextField(tunnelKind == .remote ? "Sunucudaki port" : "Yerel port", text: $listen).textFieldStyle(.roundedBorder).frame(width: 110)
                        if tunnelKind != .dynamic {
                            TextField("Hedef ana makine", text: $targetHost).textFieldStyle(.roundedBorder)
                            TextField("Hedef port", text: $targetPort).textFieldStyle(.roundedBorder).frame(width: 90)
                        }
                    }
                    HStack {
                        Button("Tüneli kaydet", action: addTunnel).buttonStyle(AccentButtonStyle())
                        if let issue { Text(ServersText.tunnelError(issue)).font(.sistemCaption).foregroundStyle(Palette.warning) }
                    }
                    Text("Yerel dinleme yalnızca 127.0.0.1 üzerindedir. Tüneller elle açılır; uygulama açılışında kendiliğinden başlamaz.")
                        .font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
                }
                .padding(.leading, 32)
            }
        }
    }

    private var summary: String {
        guard server.kind.usesSSH else { return String(localized: "Bu Mac") }
        let account = server.user.map { "\($0)@" } ?? ""
        return "\(account)\(server.host)" + (server.port.map { ":\($0)" } ?? "")
    }

    private func update(_ change: (inout ServerConfig) -> Void) {
        settings.servers = settings.servers.map { entry in
            guard entry.id == server.id else { return entry }
            var copy = entry
            change(&copy)
            return copy
        }
    }

    private func addTunnel() {
        switch ServerForm.makeTunnel(kind: tunnelKind, listen: listen, host: targetHost, port: targetPort, existing: server.tunnels.count) {
        case .failure(let found): issue = found
        case .success(let tunnel):
            update { $0.tunnels.append(tunnel) }
            issue = nil
            listen = ""; targetPort = ""
            showTunnelForm = false
        }
    }
}
