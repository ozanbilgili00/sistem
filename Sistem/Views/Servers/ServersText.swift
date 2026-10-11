import SistemUI
import SwiftUI
import SystemKit

/// Wording shared by the page, the popover and the notification.
enum ServersText {
    static func kind(_ kind: ServerKind) -> LocalizedStringKey {
        switch kind {
        case .linux: "Linux"
        case .macOS: "macOS"
        case .docker: "Docker (uzak)"
        case .localDocker: "Docker (bu Mac)"
        }
    }

    static func symbol(_ kind: ServerKind) -> String {
        switch kind {
        case .linux: "terminal"
        case .macOS: "desktopcomputer"
        case .docker, .localDocker: "shippingbox"
        }
    }

    static func phase(_ phase: ServerPhase) -> LocalizedStringKey {
        switch phase {
        case .idle: "Bekliyor"
        case .connecting: "Bağlanıyor…"
        case .reachable: "Erişilebilir"
        case .online: "Çevrimiçi"
        case .failed(let failure): failureTitle(failure)
        }
    }

    static func tone(_ phase: ServerPhase) -> Pill.Tone {
        switch phase {
        case .online, .reachable: .good
        case .connecting, .idle: .neutral
        case .failed(let failure): failure.isConnectivity ? .critical : .warning
        }
    }

    static func failureTitle(_ failure: RemoteFailure) -> LocalizedStringKey {
        switch failure {
        case .unreachable: "Erişilemiyor"
        case .refused: "Bağlantı reddedildi"
        case .unresolved: "Ad çözülemedi"
        case .timedOut: "Zaman aşımı"
        case .authRejected: "Anahtar reddedildi"
        case .hostKeyUnknown: "Ana makine anahtarı bilinmiyor"
        case .hostKeyChanged: "Ana makine anahtarı değişmiş"
        case .badOutput: "Bozuk çıktı"
        case .commandFailed: "Uzak komut başarısız"
        case .toolMissing: "Docker bulunamadı"
        case .launchFailed: "ssh başlatılamadı"
        case .forwardFailed: "Port yönlendirilemedi"
        }
    }

    static func failureDetail(_ failure: RemoteFailure) -> LocalizedStringKey {
        switch failure {
        case .unreachable: "Sunucuya ulaşılamadı. Ağ bağlantısını kontrol edin; yerel ağdaki bir sunucu için Sistem Ayarları'nda Yerel Ağ izni verilmiş olmalı."
        case .refused: "Sunucu bağlantıyı reddetti. SSH hizmeti çalışmıyor ya da port yanlış olabilir."
        case .unresolved: "Sunucu adı çözülemedi. Adı ya da ~/.ssh/config takma adını kontrol edin."
        case .timedOut: "Sunucu 10 saniye içinde yanıt vermedi."
        case .authRejected: "Sunucu anahtarınızı kabul etmedi. Yalnızca anahtar ve ssh-agent ile giriş yapılır; parola sorulmaz."
        case .hostKeyUnknown: "Bu sunucu daha önce hiç doğrulanmamış. Önce Terminal'de bir kez bağlanıp anahtarı onaylayın."
        case .hostKeyChanged: "Sunucunun anahtarı kayıtlı olandan farklı. Sunucuyu değiştirmediyseniz bağlanmayın; ~/.ssh/known_hosts kaydını kendiniz inceleyin."
        case .badOutput: "Sunucudan beklenen biçimde yanıt gelmedi; veri gösterilmiyor."
        case .commandFailed: "Uzak komut hata ile bitti."
        case .toolMissing: "Docker bu makinede bulunamadı."
        case .launchFailed: "ssh programı başlatılamadı."
        case .forwardFailed: "Yerel port kullanımda ya da sunucu yönlendirmeyi kabul etmedi."
        }
    }

    /// Failures that Terminal can fix: connect once by hand.
    static func needsTerminal(_ failure: RemoteFailure) -> Bool { failure == .hostKeyUnknown || failure == .hostKeyChanged || failure == .authRejected }

    static func tunnelKind(_ kind: TunnelSpec.Kind) -> LocalizedStringKey {
        switch kind {
        case .local: "Yerel (-L)"
        case .remote: "Uzak (-R)"
        case .dynamic: "SOCKS (-D)"
        }
    }

    /// "8080 → db.internal:5432".
    static func tunnelSummary(_ tunnel: TunnelSpec) -> String {
        switch tunnel.kind {
        case .local: "127.0.0.1:\(tunnel.listenPort) → \(tunnel.targetHost):\(tunnel.targetPort)"
        case .remote: "sunucu:\(tunnel.listenPort) → \(tunnel.targetHost):\(tunnel.targetPort)"
        case .dynamic: "SOCKS 127.0.0.1:\(tunnel.listenPort)"
        }
    }

    static func tunnelPhase(_ status: TunnelStatus) -> LocalizedStringKey {
        switch status.phase {
        case .stopped: "Kapalı"
        case .starting: "Açılıyor…"
        case .running: "Açık"
        case .waiting: "Yeniden bağlanılıyor…"
        case .failed(let failure): failureTitle(failure)
        }
    }

    static func tunnelTone(_ status: TunnelStatus) -> Pill.Tone {
        switch status.phase {
        case .running: .good
        case .waiting, .starting: .warning
        case .failed: .critical
        case .stopped: .neutral
        }
    }

    static func uptime(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "—" }
        let days = Int(seconds) / 86_400, hours = Int(seconds) % 86_400 / 3_600, minutes = Int(seconds) % 3_600 / 60
        if days > 0 { return String(localized: "\(days) g \(hours) sa") }
        if hours > 0 { return String(localized: "\(hours) sa \(minutes) dk") }
        return String(localized: "\(minutes) dk")
    }

    static func percent(_ fraction: Double?) -> String { fraction.map { "\(Int(($0 * 100).rounded())) %" } ?? "—" }

    static func load(_ values: [Double]?) -> String {
        guard let values, values.count == 3 else { return "—" }
        return values.map { Format.decimal($0) }.joined(separator: " · ")
    }

    static func addError(_ issue: ServerFormIssue) -> LocalizedStringKey {
        switch issue {
        case .name: "Ad boş olmamalı (en çok 40 karakter)."
        case .host: "Ana makine adı, IP adresi ya da ~/.ssh/config takma adı olmalı; harf, rakam, nokta, tire ve alt çizgi kullanın, tire ile başlamayın."
        case .user: "Kullanıcı adı geçersiz (harf, rakam, nokta, tire, alt çizgi; en çok 32)."
        case .port: "Port 1 ile 65535 arasında olmalı."
        case .limit: "En çok 20 sunucu eklenebilir."
        }
    }

    static func tunnelError(_ issue: TunnelFormIssue) -> LocalizedStringKey {
        switch issue {
        case .listenPort: "Yerel port 1024-65535 arasında olmalı."
        case .targetHost: "Hedef ana makine geçersiz."
        case .targetPort: "Hedef port 1-65535 arasında olmalı."
        case .limit: "Bir sunucuya en çok 10 tünel eklenebilir."
        }
    }
}

enum ServerFormIssue: Error { case name, host, user, port, limit }
enum TunnelFormIssue: Error { case listenPort, targetHost, targetPort, limit }

/// Turns what was typed into a validated server, or says which field is wrong. Nothing is repaired.
enum ServerForm {
    static func make(name: String, kind: ServerKind, host: String, user: String, port: String, existing: Int) -> Result<ServerConfig, ServerFormIssue> {
        guard existing < ServerConfig.maxServers else { return .failure(.limit) }
        guard let name = ServerInput.displayName(name) else { return .failure(.name) }
        guard kind.usesSSH else { return .success(ServerConfig(name: name, kind: kind)) }
        guard let host = ServerInput.host(host) else { return .failure(.host) }
        var userValue: String?
        if !user.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let valid = ServerInput.user(user) else { return .failure(.user) }
            userValue = valid
        }
        var portValue: Int?
        if !port.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let valid = ServerInput.port(port) else { return .failure(.port) }
            portValue = valid
        }
        return .success(ServerConfig(name: name, kind: kind, host: host, user: userValue, port: portValue))
    }

    static func makeTunnel(kind: TunnelSpec.Kind, listen: String, host: String, port: String, existing: Int) -> Result<TunnelSpec, TunnelFormIssue> {
        guard existing < ServerConfig.maxTunnels else { return .failure(.limit) }
        guard let listenPort = ServerInput.port(listen), kind == .remote || listenPort >= 1_024 else { return .failure(.listenPort) }
        if kind == .dynamic { return .success(TunnelSpec(kind: .dynamic, listenPort: listenPort)) }
        guard let targetHost = ServerInput.host(host) else { return .failure(.targetHost) }
        guard let targetPort = ServerInput.port(port) else { return .failure(.targetPort) }
        return .success(TunnelSpec(kind: kind, listenPort: listenPort, targetHost: targetHost, targetPort: targetPort))
    }
}
