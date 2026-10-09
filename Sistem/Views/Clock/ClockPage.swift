import SistemUI
import SwiftUI
import SystemKit

struct ClockPage: View {
    @Bindable var settings: SettingsStore
    @State private var tab: ModuleTab

    init(settings: SettingsStore, tab: ModuleTab = .overview) {
        self.settings = settings
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ModulePageHeader(module: .clock, tab: $tab)
            switch tab {
            case .overview: ClockOverview(settings: settings)
            case .module: ClockModuleSettings(settings: settings)
            case .widgets: ClockWidgetSettings(settings: settings)
            }
        }
    }
}

private struct ClockOverview: View {
    let settings: SettingsStore

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionLabel("Yerel saat")
                        LocalTimeSummary(settings: settings)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionLabel("Saat dilimleri")
                        if settings.clockZones.isEmpty {
                            Text("Henüz saat dilimi eklenmedi. Modül sekmesinden ekleyebilirsiniz.")
                                .font(.sistemBody).foregroundStyle(Palette.inkSecondary)
                        } else {
                            ZoneRows(identifiers: settings.clockZones, showsSeconds: settings.clockDisplay.showsSeconds)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel("Takvim")
                    MonthCalendar()
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: 320)
        }
    }
}

private struct ClockModuleSettings: View {
    @Bindable var settings: SettingsStore
    @State private var adding = false
    @State private var query = ""
    @State private var check = ClockCheck.idle

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(padding: 0) { MenuBarToggleRow(module: .clock, settings: settings) }

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        SectionLabel("Saat dilimleri")
                        Spacer()
                        Button("Saat dilimi ekle") { adding = true }
                            .buttonStyle(QuietButtonStyle())
                            .disabled(settings.clockZones.count >= SettingsStore.clockZoneLimit)
                            .popover(isPresented: $adding, arrowEdge: .bottom) { ZonePicker(settings: settings, isPresented: $adding) }
                    }
                    if settings.clockZones.isEmpty {
                        Text("Eklediğiniz saat dilimleri sayfada ve açılır pencerede yerel saatin altında listelenir.")
                            .font(.sistemBody).foregroundStyle(Palette.inkSecondary)
                    } else {
                        ZoneRows(identifiers: settings.clockZones, showsSeconds: false) { identifier in
                            settings.clockZones.removeAll { $0 == identifier }
                        }
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        SectionLabel("Saat doğruluğu")
                        Spacer()
                        Button(check == .checking ? "Sorgulanıyor…" : "Sunucuyla karşılaştır") { runCheck() }
                            .buttonStyle(QuietButtonStyle())
                            .disabled(check == .checking)
                    }
                    Text(check.message)
                        .font(.sistemBody).foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Yalnızca bu düğmeye basınca time.apple.com sunucusuna tek bir UDP paketi gönderilir; en çok 5 saniye beklenir. Saatiniz değiştirilmez.")
                        .font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
                }
            }
        }
    }

    private func runCheck() {
        check = .checking
        Task { @MainActor in
            if let result = await SNTPClient().measure() {
                check = .done(result.offset, result.roundTrip)
            } else {
                check = .failed
            }
        }
    }
}

enum ClockCheck: Equatable {
    case idle, checking, failed
    case done(Double, Double)

    var message: LocalizedStringKey {
        switch self {
        case .idle: return "Mac'inizin saati ağ saat sunucusuyla karşılaştırılmadı."
        case .checking: return "Sunucuya soruluyor…"
        case .failed: return "Sunucudan yanıt alınamadı."
        case .done(let offset, _):
            let seconds = abs(offset).formatted(.number.precision(.fractionLength(2)))
            if abs(offset) < 0.05 { return "Saatiniz doğru (fark \(seconds) sn)." }
            if offset > 0 { return "Saatiniz \(seconds) sn geride." }
            return "Saatiniz \(seconds) sn ileride."
        }
    }
}

/// Searchable list of the system's time zones.
struct ZonePicker: View {
    let settings: SettingsStore
    @Binding var isPresented: Bool
    @State private var query = ""

    private var matches: [String] {
        let all = TimeZone.knownTimeZoneIdentifiers.filter { !settings.clockZones.contains($0) && $0.contains("/") }
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "_")
        guard !needle.isEmpty else { return Array(all.prefix(40)) }
        return Array(all.filter { $0.lowercased().contains(needle) }.prefix(40))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Şehir ara", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(matches, id: \.self) { identifier in
                        Button {
                            settings.addClockZone(identifier)
                            isPresented = false
                        } label: {
                            HStack {
                                Text(verbatim: identifier.replacingOccurrences(of: "_", with: " "))
                                    .font(.sistemBody).foregroundStyle(Palette.ink)
                                Spacer()
                            }
                            .padding(.vertical, 5).padding(.horizontal, 6)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 220)
        }
        .padding(12)
        .frame(width: 280)
    }
}

private struct ClockWidgetSettings: View {
    @Bindable var settings: SettingsStore
    @Environment(LiveFeed.self) private var feed

    var body: some View {
        let config = settings.widget(for: .clock)
        VStack(alignment: .leading, spacing: 14) {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel("Önizleme")
                    WidgetPreview(module: .clock, config: config, sensors: settings.sensorsDisplay, clock: settings.clockDisplay)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Palette.surface2, in: .rect(cornerRadius: Metrics.controlRadius))
                }
            }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    SettingRow(Text("Biçim"), detail: Text("Boş bırakılırsa sistemin saat biçimi kullanılır. Örnek: HH:mm, EEE HH:mm, d MMM HH:mm. Saniye ekleyen biçim menü çubuğunu her saniye çizdirir.")) {
                        TextField(ClockFormat.defaultPattern(), text: $settings.clockPattern)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                    }
                    RowDivider()
                    SettingRow("Hazır biçimler") {
                        HStack(spacing: 6) {
                            ForEach(ClockFormat.presets, id: \.self) { preset in
                                Button(preset) { settings.clockPattern = preset }.buttonStyle(QuietButtonStyle())
                            }
                        }
                    }
                    RowDivider()
                    SettingRow("Tarihi göster", detail: "Saatin üstünde küçük gün ve tarih.") {
                        Toggle("Tarihi göster", isOn: Binding(
                            get: { config.showLabel },
                            set: { var new = config; new.showLabel = $0; settings.setWidget(new, for: .clock) }
                        )).labelsHidden().toggleStyle(.switch)
                    }
                }
            }
            if settings.clockDisplay.showsSeconds {
                Text("Bu biçim saniye gösteriyor: menü çubuğu öğesi her saniye yeniden çizilir ve pil tüketimi artar.")
                    .font(.sistemCaption).foregroundStyle(Palette.warning)
            }
        }
    }
}
