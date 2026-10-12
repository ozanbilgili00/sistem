import AppKit
import SistemUI
import SwiftUI
import SystemKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var settings: SettingsStore
    @State private var transferMessage: TransferMessage?
    @State private var confirmingReset = false

    private struct TransferMessage {
        let text: Text
        let isError: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(Text("Ayarlar"), subtitle: Text("Görünüm, güncelleme sıklığı ve menü çubuğu."))

            SectionLabel("Görünüm")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    SettingRow("Tema") {
                        Picker("Tema", selection: $settings.appearance) {
                            Text("Sistem").tag(SettingsStore.Appearance.system)
                            Text("Koyu").tag(SettingsStore.Appearance.dark)
                            Text("Açık").tag(SettingsStore.Appearance.light)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    RowDivider()
                    SettingRow("Sıcaklık birimi") {
                        Picker("Sıcaklık birimi", selection: $settings.temperatureUnit) {
                            ForEach(SettingsStore.TemperatureUnit.allCases) { Text($0.symbol).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }

            SectionLabel("Genel")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    LoginItemRow(loginItem: settings.loginItem)
                    RowDivider()
                    SettingRow("Dock'ta göster", detail: "Kapalıyken uygulama yalnızca menü çubuğunda yaşar.") {
                        Toggle("Dock'ta göster", isOn: $settings.showInDock).labelsHidden().toggleStyle(.switch)
                    }
                }
            }

            SectionLabel("Enerji")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    SettingRow(Text("Güç profili"), detail: Text(settings.powerProfile.detail)) {
                        Picker("Güç profili", selection: $settings.powerProfile) {
                            ForEach(PowerProfile.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    RowDivider()
                    SettingRow("Güncelleme aralığı", detail: "Daha uzun aralık, daha az pil tüketimi.") {
                        Picker("Güncelleme aralığı", selection: $settings.updateInterval) {
                            ForEach(SettingsStore.intervalChoices, id: \.self) { seconds in
                                Text("\(Int(seconds)) sn").tag(seconds)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    RowDivider()
                    SettingRow("Pilde yavaşla", detail: settings.powerProfile == .automatic
                               ? "Pildeyken ve Düşük Güç Modu'nda aralık iki katına çıkar."
                               : "Yalnızca Otomatik profilde geçerli.") {
                        Toggle("Pilde yavaşla", isOn: $settings.slowDownOnBattery).labelsHidden().toggleStyle(.switch)
                            .disabled(settings.powerProfile != .automatic)
                    }
                }
            }

            SectionLabel("Bildirimler")
            AlertRulesCard(settings: settings)

            SectionLabel("Menü çubuğu")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(ModuleID.menuBarCandidates.enumerated()), id: \.element) { index, module in
                        if index > 0 { RowDivider() }
                        SettingRow(Text(module.menuBarTitle), detail: module.menuBarUnit.map { Text($0) }) {
                            HStack(spacing: 10) {
                                if !module.isLive {
                                    Pill(Text("Faz \(module.phase)"), tone: .neutral)
                                }
                                Toggle(String(localized: module.menuBarTitle), isOn: Binding(
                                    get: { settings.isInMenuBar(module) },
                                    set: { settings.setInMenuBar(module, $0) }
                                )).labelsHidden().toggleStyle(.switch)
                            }
                        }
                    }
                }
            }
            Text("Henüz gelmemiş modüller seçili kalır ve kendi fazlarında görünür. Widget türleri her modülün kendi sayfasındaki Widget'lar sekmesinden seçilir.")
                .font(.sistemCaption)
                .foregroundStyle(Palette.inkTertiary)

            StripOrderCard(settings: settings)

            SectionLabel("Ayarları yönet")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    SettingRow("Dışa aktar", detail: "Tüm ayarlar ve bildirim kuralları tek bir JSON dosyasına yazılır.") {
                        Button("Dışa aktar…") { exportSettings() }.buttonStyle(QuietButtonStyle())
                    }
                    RowDivider()
                    SettingRow("İçe aktar", detail: "Dosya doğrulanır; tanınmayan ya da geçersiz değerler atlanır.") {
                        Button("İçe aktar…") { importSettings() }.buttonStyle(QuietButtonStyle())
                    }
                    RowDivider()
                    SettingRow("Varsayılana sıfırla", detail: "Bildirim kuralları da kapanır. Oturum açınca başlatma sistemde kalır.") {
                        Button("Sıfırla…") { confirmingReset = true }.buttonStyle(QuietButtonStyle())
                    }
                }
            }
            if let transferMessage {
                transferMessage.text
                    .font(.sistemCaption)
                    .foregroundStyle(transferMessage.isError ? Palette.critical : Palette.inkSecondary)
            }
        }
        .alert("Ayarlar sıfırlansın mı?", isPresented: $confirmingReset) {
            Button("Sıfırla", role: .destructive) {
                settings.resetToDefaults()
                transferMessage = TransferMessage(text: Text("Ayarlar varsayılana döndü."), isError: false)
            }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Tüm ayarlar ve bildirim kuralları fabrika değerlerine döner.")
        }
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Sistem Ayarları.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try settings.exportData().write(to: url, options: .atomic)
            transferMessage = TransferMessage(text: Text("Ayarlar dışa aktarıldı."), isError: false)
        } catch {
            transferMessage = TransferMessage(text: Text("Dosya yazılamadı."), isError: true)
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let result = try settings.importData(data)
            transferMessage = TransferMessage(
                text: result.ignored == 0 ? Text("\(result.applied) ayar içe aktarıldı.")
                                          : Text("\(result.applied) ayar içe aktarıldı, \(result.ignored) geçersiz değer atlandı."),
                isError: false)
        } catch SettingsArchive.Failure.newerVersion {
            transferMessage = TransferMessage(text: Text("Bu dosya Sistem'in daha yeni bir sürümünden; içe aktarılamadı."), isError: true)
        } catch {
            transferMessage = TransferMessage(text: Text("Bu bir Sistem ayar dosyası değil."), isError: true)
        }
    }
}

/// Launch at login, with the system's answer shown rather than assumed.
private struct LoginItemRow: View {
    let loginItem: LoginItem

    var body: some View {
        VStack(spacing: 0) {
            SettingRow(Text("Oturum açınca başlat"), detail: Text(detail)) {
                HStack(spacing: 10) {
                    if loginItem.state == .needsApproval {
                        Pill(Text("Onay bekliyor"), tone: .warning)
                    }
                    Toggle("Oturum açınca başlat", isOn: Binding(get: { loginItem.isOn }, set: { loginItem.set($0) }))
                        .labelsHidden().toggleStyle(.switch)
                }
            }
            if loginItem.state == .needsApproval {
                HStack {
                    Spacer()
                    Button("Oturum Açma Öğeleri'ni aç") { loginItem.openSystemSettings() }.buttonStyle(QuietButtonStyle())
                }
                .padding(.horizontal, 16).padding(.bottom, 11)
            }
            if let failure = loginItem.failure {
                Text(verbatim: failure)
                    .font(.sistemCaption).foregroundStyle(Palette.critical)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 11)
            }
        }
        .onAppear { loginItem.refresh() }
    }

    private var detail: LocalizedStringKey {
        switch loginItem.state {
        case .needsApproval: "macOS izin vermeni bekliyor: Sistem Ayarları'nda Oturum Açma Öğeleri."
        case .unavailable: "Bu kopya kaydedilemiyor. Uygulamayı Uygulamalar klasörüne taşıyıp yeniden dene."
        default: "Mac açıldığında Sistem menü çubuğunda kendiliğinden başlar."
        }
    }
}

/// The notification rules and the permission they depend on.
private struct AlertRulesCard: View {
    @Bindable var settings: SettingsStore
    @Environment(AlertNotifier.self) private var notifier

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Card(padding: 0) {
                VStack(spacing: 0) {
                    permissionRow
                    ForEach(AlertKind.allCases) { kind in
                        RowDivider()
                        RuleRow(rule: binding(for: kind), unit: settings.temperatureUnit)
                    }
                }
            }
            Text("Kurallar varsayılan olarak kapalıdır. Açık bir kural yalnızca kendi ölçümünü en çok 10 saniyede bir okur; kapalıysa hiçbir şey okunmaz. Bir kural sınırda gidip gelse de tek bildirim gönderir.")
                .font(.sistemCaption)
                .foregroundStyle(Palette.inkTertiary)
        }
        .onAppear { notifier.refresh() }
    }

    private func binding(for kind: AlertKind) -> Binding<AlertRule> {
        Binding(
            get: { settings.alertRules.first { $0.kind == kind } ?? AlertRule(kind: kind) },
            set: { new in
                if let index = settings.alertRules.firstIndex(where: { $0.kind == kind }) {
                    settings.alertRules[index] = new.sanitized()
                }
            })
    }

    @ViewBuilder private var permissionRow: some View {
        let anyEnabled = settings.alertRules.contains(where: \.enabled)
        switch notifier.permission {
        case .denied:
            VStack(alignment: .leading, spacing: 8) {
                SettingRow("Bildirim izni", detail: "Sistem Ayarları'nda Sistem için bildirimler kapalı; kurallar çalışır ama bildirim görünmez.") {
                    Pill(Text("İzin kapalı"), tone: .critical)
                }
                HStack {
                    Spacer()
                    Button("Bildirim ayarlarını aç") { notifier.openSystemSettings() }.buttonStyle(AccentButtonStyle())
                }
                .padding(.horizontal, 16).padding(.bottom, 11)
            }
        case .allowed:
            SettingRow("Bildirim izni", detail: "Bildirimler Bildirim Merkezi'ne düşer; tıklayınca ilgili modül açılır.") {
                Pill(Text("İzin verildi"), tone: .good)
            }
        case .notDetermined where anyEnabled:
            SettingRow("Bildirim izni", detail: "macOS'un izin sorusu bekleniyor.") {
                Pill(Text("Bekleniyor"), tone: .warning)
            }
        default:
            SettingRow("Bildirim izni", detail: "İlk kuralı açtığında macOS izin ister; o ana kadar hiçbir şey sorulmaz.") {
                Pill(Text("Henüz istenmedi"), tone: .neutral)
            }
        }
    }
}

private struct RuleRow: View {
    @Binding var rule: AlertRule
    let unit: SettingsStore.TemperatureUnit

    var body: some View {
        VStack(spacing: 0) {
            SettingRow(Text(rule.kind.title), detail: Text(rule.kind.summary)) {
                Toggle(String(localized: rule.kind.title), isOn: $rule.enabled).labelsHidden().toggleStyle(.switch)
            }
            if rule.enabled, hasOptions {
                HStack(spacing: 18) {
                    Spacer()
                    if rule.kind.thresholdChoices.count > 1 {
                        option(Text(rule.kind.thresholdTitle)) {
                            Picker(String(localized: rule.kind.thresholdTitle), selection: $rule.threshold) {
                                ForEach(rule.kind.thresholdChoices, id: \.self) { value in
                                    rule.kind.label(forThreshold: value, unit: unit).tag(value)
                                }
                            }
                        }
                    }
                    if !rule.kind.durationChoices.isEmpty {
                        option(Text("Süre")) {
                            Picker("Süre", selection: $rule.duration) {
                                ForEach(rule.kind.durationChoices, id: \.self) { AlertKind.label(forDuration: $0).tag($0) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 11)
            }
        }
    }

    private var hasOptions: Bool { rule.kind.thresholdChoices.count > 1 || !rule.kind.durationChoices.isEmpty }

    private func option<P: View>(_ title: Text, @ViewBuilder picker: () -> P) -> some View {
        HStack(spacing: 8) {
            title.font(.sistemCaption).foregroundStyle(Palette.inkSecondary)
            picker().labelsHidden().fixedSize()
        }
    }
}

/// The sections that are on in the menu bar, left to right, with buttons to move each one. The order is kept across
/// restarts and goes into the exported file.
struct StripOrderCard: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        let shown = settings.shownSections
        if shown.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Şerit sırası")
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element) { index, section in
                            if index > 0 { RowDivider() }
                            SettingRow(Text(section.menuBarTitle)) {
                                HStack(spacing: 6) {
                                    Button { settings.moveSection(section, up: true) } label: { Image(systemName: "chevron.up") }
                                        .disabled(index == 0)
                                        .accessibilityLabel(Text("\(String(localized: section.menuBarTitle)): \(String(localized: "Sola taşı"))"))
                                    Button { settings.moveSection(section, up: false) } label: { Image(systemName: "chevron.down") }
                                        .disabled(index == shown.count - 1)
                                        .accessibilityLabel(Text("\(String(localized: section.menuBarTitle)): \(String(localized: "Sağa taşı"))"))
                                }
                                .buttonStyle(QuietButtonStyle())
                            }
                        }
                    }
                }
                Text("Yukarıdaki sıra menü çubuğunda soldan sağa dizilir.")
                    .font(.sistemCaption)
                    .foregroundStyle(Palette.inkTertiary)
            }
        }
    }
}
