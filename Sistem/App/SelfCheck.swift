#if DEBUG
import AppKit
import SystemKit

/// `Sistem --selfcheck` checks what the package tests cannot reach, because it lives in the app target: that a menu bar
/// section keeps its width at the ends of its value range, and that the real ``SettingsStore`` keeps the strip order and
/// the widget choices across a restart, an export and an import. Prints one line per check and exits 1 on any failure.
/// Touches no window, no sampler and no user defaults (its own throwaway suites).
@MainActor
enum SelfCheck {
    private static var failures = 0
    private static var checks = 0

    private static func check(_ ok: Bool, _ name: @autoclosure () -> String) {
        checks += 1
        if !ok {
            failures += 1
            print("FAIL \(name())")
        }
    }

    static func run() -> Int32 {
        NSApplication.shared.setActivationPolicy(.prohibited)
        widths()
        settings()
        print(failures == 0 ? "OK \(checks) denetim" : "HATA \(failures)/\(checks)")
        return failures == 0 ? 0 : 1
    }

    // MARK: Fixed width

    private static func models(for module: ModuleID, sensors: SensorsDisplay) -> [WidgetModel] {
        let unit = sensors.unit
        func percent(_ fraction: Float?) -> WidgetModel {
            var model = WidgetModel(label: module == .ram ? "RAM" : "CPU", value: fraction, text: Format.percent(fraction), history: [])
            model.barLevels = Array(repeating: UInt8(fraction.map { $0 * 8 } ?? 0), count: WidgetModel.barCount(for: module))
            return model
        }
        switch module {
        case .network, .disk:
            let rates: [Double] = [0, 5, 999, 1_000, 9_950, 99_999, 999_499, 999_999, 1_500_000, 999_000_000, 999_700_000, 5_000_000_000, 999_000_000_000]
            return rates.flatMap { first in
                [0, first, 999_000_000].map { second in
                    var model = WidgetModel(label: Format.rate(first), value: nil, text: Format.rate(second), history: [], topRate: first, bottomRate: second)
                    model.rateSymbols = ["arrow.up", "arrow.down"]
                    return model
                }
            }
        case .sensors:
            let temperatures: [Float?] = [nil, -9, 0, 5, 62, 99, 100, 150, 199]
            return temperatures.map { celsius in
                var model = WidgetModel(label: "CPU", value: celsius.map(SensorScale.fraction), text: Format.temperature(celsius, unit: unit), history: [])
                if sensors.stacked {
                    model.stacked = true
                    model.label = "CPU \(model.text)"
                    model.text = "GPU \(Format.temperature(celsius, unit: unit))"
                }
                return model
            }
        case .battery:
            let fractions: [Float?] = [nil, 0, 0.01, 0.2, 0.5, 1]
            let glyphs: [String?] = [nil, "bolt.fill", "powerplug.fill"]
            return fractions.flatMap { fraction -> [WidgetModel] in
                glyphs.map { glyph in
                    var model = WidgetModel(label: "Batarya", value: fraction, text: Format.percent(fraction), history: [])
                    model.glyph = glyph
                    return model
                }
            }
        default:
            return [nil, 0, 0.004, 0.05, 0.5, 0.999, 1].map { percent($0) }
        }
    }

    private static func widths() {
        let height = NSStatusBar.system.thickness
        var cases = 0
        for module in ModuleID.menuBarCandidates where module != .bluetooth && module != .clock {
            let supported = WidgetKind.supported(by: module)
            for sensors in module == .sensors ? [SensorsDisplay(unit: .celsius, stacked: false), SensorsDisplay(unit: .fahrenheit, stacked: true)] : [SensorsDisplay()] {
                // Every non-empty combination of the module's kinds, with and without the label.
                for mask in 1..<(1 << supported.count) {
                    let kinds = Set(supported.enumerated().compactMap { mask & (1 << $0.offset) != 0 ? $0.element : nil })
                    for showLabel in [true, false] {
                        let config = WidgetConfig(kinds: kinds, showLabel: showLabel)
                        let view = WidgetView(frame: NSRect(x: 0, y: 0, width: 0, height: height))
                        view.widestTexts = WidgetModel.widestTexts(for: module, sensors: sensors)
                        view.reservesGlyph = module == .battery
                        view.barCount = WidgetModel.barCount(for: module)
                        var reference: CGFloat?
                        for model in models(for: module, sensors: sensors) {
                            view.update(model, config: config)
                            let width = view.intrinsicWidth
                            reference = reference ?? width
                            cases += 1
                            check(width == reference, "genişlik oynadı: \(module) \(kinds.map(\.rawValue).sorted()) etiket=\(showLabel) \(model.label)|\(model.text): \(width) != \(reference ?? 0)")
                            check(view.fits(model, config: config), "metin ayrılan yere sığmadı: \(module) \(kinds.map(\.rawValue).sorted()) \(model.label)|\(model.text)")
                        }
                    }
                }
            }
        }
        print("genişlik: \(cases) durum (modül × tür birleşimi × etiket × uç değer)")
    }

    // MARK: Settings

    private static func suite(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "SistemSelfCheck-\(name)")!
        defaults.removePersistentDomain(forName: "SistemSelfCheck-\(name)")
        return defaults
    }

    private static func settings() {
        // Save → a new SettingsStore on the same defaults → same order, same widgets.
        let defaults = suite("a")
        let first = SettingsStore(defaults: defaults)
        check(first.menuBarOrder == MenuBarOrder.allSections, "ilk açılışta varsayılan sıra")
        first.menuBarModules = [.cpu, .ram, .network, .battery]
        first.menuBarOrder = MenuBarOrder.sanitized(["battery", "network", "cpu"])
        first.setWidget(WidgetConfig(kinds: [.bars, .text, .sparkline], showLabel: false), for: .cpu)
        first.setWidget(WidgetConfig(kinds: [.text, .chart], showLabel: true), for: .network)  // text is not a network kind
        check(first.widget(for: .network).kinds == [.arrows, .chart], "ağ için .text .arrows'a çevrilmeli: \(first.widget(for: .network).kinds)")
        let before = first.shownSections
        check(before == [.battery, .network, .cpu, .ram], "gösterilen sıra: \(before)")
        let second = SettingsStore(defaults: defaults)
        check(second.menuBarOrder == first.menuBarOrder, "yeniden başlatmada sıra korunmalı")
        check(second.shownSections == before, "yeniden başlatmada gösterilen sıra korunmalı")
        check(second.widget(for: .cpu) == first.widget(for: .cpu), "yeniden başlatmada widget türleri korunmalı")
        check(second.widget(for: .network).kinds == [.arrows, .chart], "yeniden başlatmada ağ türleri")
        let kinds = StatusBarController.wantedKinds(modules: second.menuBarModules, order: second.menuBarOrder, keepAwake: false, display: false, servers: false)
        check(kinds == [.module(.battery), .module(.network), .module(.cpu), .module(.ram)], "şerit bölümleri sırayı izlemeli: \(kinds)")

        // Moving one place.
        second.moveSection(.cpu, up: true)
        check(second.shownSections == [.battery, .cpu, .network, .ram], "yukarı taşı: \(second.shownSections)")
        check(SettingsStore(defaults: defaults).shownSections == second.shownSections, "taşıma kalıcı olmalı")

        // Export → import into a fresh store.
        if let data = try? second.exportData() {
            let target = SettingsStore(defaults: suite("b"))
            let result = try? target.importData(data)
            check(result?.ignored == 0, "dışa aktarılan dosyada atlanan değer olmamalı: \(String(describing: result))")
            check(target.menuBarOrder == second.menuBarOrder, "içe aktarmada sıra")
            check(target.widget(for: .cpu) == second.widget(for: .cpu), "içe aktarmada widget türleri")
            check(SettingsStore(defaults: target.defaultsForCheck).menuBarOrder == second.menuBarOrder, "içe aktarılan sıra yeniden başlatmada")
        } else {
            check(false, "dışa aktarma başarısız")
        }

        // An imported file with unknown and repeated names, and with an unsupported kind.
        let dirty: [String: Any] = [
            "menuBarOrder": ["servers", "nonsense", "servers", "cpu", "dashboard", ""],
            "menuBarWidgets": ["cpu": ["kinds": ["battery", "bars", "hologram"], "showLabel": true], "dashboard": ["kinds": ["text"], "showLabel": true]],
        ]
        if let file = try? SettingsArchive.encode(dirty) {
            let target = SettingsStore(defaults: suite("c"))
            _ = try? target.importData(file)
            check(target.menuBarOrder.prefix(2) == [.servers, .cpu], "kirli sıra ayıklanmalı: \(target.menuBarOrder)")
            check(Set(target.menuBarOrder) == Set(MenuBarOrder.allSections) && target.menuBarOrder.count == MenuBarOrder.allSections.count, "yinelenen/eksik kimlik")
            check(target.widget(for: .cpu).kinds == [.bars], "desteklenmeyen türler atılmalı: \(target.widget(for: .cpu).kinds)")
            check(target.widgets[.dashboard] == nil, "widget'ı olmayan modül atılmalı")
        }

        // Widgets given as a command line argument arrive as text.
        let argument = suite("d")
        argument.set(#"{"cpu":{"kinds":["bars","text"],"showLabel":true},"network":{"kinds":["arrows","sparkline"],"showLabel":false}}"#, forKey: "menuBarWidgets")
        argument.set(["cpu", "network"], forKey: "menuBarModules")
        let fromArguments = SettingsStore(defaults: argument)
        check(fromArguments.widget(for: .cpu).kinds == [.bars, .text] && fromArguments.widget(for: .network).kinds == [.arrows, .sparkline], "argüman metninden widget okuma")

        // Reset.
        second.resetToDefaults()
        check(second.menuBarOrder == MenuBarOrder.allSections, "sıfırlayınca varsayılan sıra")
        check(SettingsStore(defaults: defaults).menuBarOrder == MenuBarOrder.allSections, "sıfırlama kalıcı olmalı")
        for name in ["a", "b", "c", "d"] { UserDefaults(suiteName: "SistemSelfCheck-\(name)")?.removePersistentDomain(forName: "SistemSelfCheck-\(name)") }
    }
}
#endif
