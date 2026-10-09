import AppKit
import Observation
import SystemKit
import UserNotifications

/// Delivers alerts through `UNUserNotificationCenter` and tracks the permission.
///
/// Authorization is requested only when the user turns on their first rule — never at launch —
/// and the answer is shown in Settings, with a way to System Settings when it is denied.
/// A click on a notification opens the page of the module it is about.
@Observable
final class AlertNotifier: NSObject, UNUserNotificationCenterDelegate {
    enum Permission: Equatable {
        /// Not asked yet (or not read yet).
        case unknown
        case notDetermined
        case allowed
        case denied
    }

    private(set) var permission: Permission = .unknown

    @ObservationIgnored var open: (ModuleID) -> Void = { _ in }
    /// Snapshots show a fixed permission instead of asking the system.
    @ObservationIgnored private var isFrozen = false

    override init() { super.init() }

    #if DEBUG
    init(previewing permission: Permission) {
        self.permission = permission
        isFrozen = true
        super.init()
    }
    #endif
    @ObservationIgnored private var center: UNUserNotificationCenter { .current() }

    /// Hooks the click handler. Does not ask for anything and does not touch the permission.
    func activate() {
        center.delegate = self
    }

    /// Reads the current permission (no prompt).
    func refresh() {
        guard !isFrozen else { return }
        Task { await readPermission() }
    }

    /// Asks the system for permission, once, if it has not been decided. Called when the first rule is enabled.
    func requestIfNeeded() {
        Task {
            await readPermission()
            guard permission == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert])
            await readPermission()
        }
    }

    private func readPermission() async {
        let settings = await center.notificationSettings()
        permission = switch settings.authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .allowed
        }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Posts a triggered alert. A recovery is not announced. Nothing is logged.
    func post(_ event: AlertEvent, unit: SettingsStore.TemperatureUnit) {
        guard event.transition == .triggered, permission != .denied else { return }
        let message = AlertMessage.make(event, unit: unit)
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        content.threadIdentifier = "sistem.alerts"
        content.userInfo = ["module": event.kind.module.rawValue]
        // One slot per rule: a newer alert replaces the older one instead of stacking.
        let request = UNNotificationRequest(identifier: "alert.\(event.kind.rawValue)", content: content, trigger: nil)
        Task { try? await center.add(request) }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["module"] as? String,
              let module = ModuleID(rawValue: raw) else { return }
        await MainActor.run { open(module) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

/// Wording of the notifications.
enum AlertMessage {
    static func make(_ event: AlertEvent, unit: SettingsStore.TemperatureUnit) -> (title: String, body: String) {
        let value = Int(event.value.rounded())
        let threshold = Int(event.threshold.rounded())
        switch event.kind {
        case .cpuLoad:
            return (String(localized: "CPU yükü yüksek"),
                    String(localized: "Kullanım yüzde \(threshold) eşiğinin üstünde, şu an yüzde \(value)."))
        case .memoryPressure:
            return (String(localized: "Bellek baskısı yükseldi"),
                    event.threshold >= 4 ? String(localized: "macOS bellek baskısını kritik olarak bildiriyor.")
                                         : String(localized: "macOS bellek baskısını uyarı düzeyinde bildiriyor."))
        case .cpuTemperature:
            let hot = Int(unit.convert(Float(event.value)).rounded())
            let limit = Int(unit.convert(Float(event.threshold)).rounded())
            return (String(localized: "CPU sıcaklığı yüksek"),
                    String(localized: "En sıcak çekirdek \(hot)\(unit.symbol), eşik \(limit)\(unit.symbol)."))
        case .diskFree:
            let free = Int64(event.value * 1_000_000_000).formatted(.byteCount(style: .file))
            return (String(localized: "Disk dolmak üzere"),
                    String(localized: "Başlangıç diskinde yalnızca \(free) boş alan kaldı."))
        case .batteryLow:
            return (String(localized: "Pil azaldı"),
                    String(localized: "Şarj yüzde \(value); pil boşalıyor."))
        case .networkDown:
            return (String(localized: "Ağ bağlantısı kesildi"),
                    String(localized: "Mac şu an internete ulaşamıyor."))
        }
    }
}
