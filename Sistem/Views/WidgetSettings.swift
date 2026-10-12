import SistemUI
import SwiftUI
import SystemKit

/// The "Widget'lar" tab of a module: which widgets it draws in the menu bar, with
/// a live preview drawn by the same AppKit view the menu bar uses.
struct WidgetSettings: View {
    let module: ModuleID
    @Bindable var settings: SettingsStore

    /// Exactly what the module supports (``WidgetKind/supported(by:)``): an unsupported combination cannot be chosen.
    private var kinds: [WidgetKind] { WidgetKind.supported(by: module) }

    var body: some View {
        let config = settings.widget(for: module)
        VStack(alignment: .leading, spacing: 14) {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel("Önizleme")
                    WidgetPreview(module: module, config: config, sensors: settings.sensorsDisplay)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Palette.surface2, in: .rect(cornerRadius: Metrics.controlRadius))
                }
            }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(kinds) { kind in
                        if kind != kinds.first { RowDivider() }
                        SettingRow(Text(kind.title(for: module)), detail: Text(kind.detail(for: module))) {
                            Toggle(String(localized: kind.title(for: module)), isOn: binding(kind, config))
                                .labelsHidden().toggleStyle(.switch)
                                // Keep at least one widget, or the item would be empty.
                                .disabled(config.kinds == [kind])
                        }
                    }
                    if kinds.contains(.text) {
                        RowDivider()
                        SettingRow("Etiketi göster", detail: "Değerin üstünde küçük modül adı.") {
                            Toggle("Etiketi göster", isOn: Binding(
                                get: { config.showLabel },
                                set: { var new = config; new.showLabel = $0; settings.setWidget(new, for: module) }
                            )).labelsHidden().toggleStyle(.switch)
                        }
                    }
                }
            }
        }
    }

    private func binding(_ kind: WidgetKind, _ config: WidgetConfig) -> Binding<Bool> {
        Binding(
            get: { config.kinds.contains(kind) },
            set: { on in
                var new = config
                if on { new.kinds.insert(kind) } else { new.kinds.remove(kind) }
                settings.setWidget(new, for: module)
            }
        )
    }
}

/// Hosts a real ``WidgetView`` at menu bar height.
struct WidgetPreview: View {
    let module: ModuleID
    let config: WidgetConfig
    let sensors: SensorsDisplay
    var clock: ClockDisplay?
    @Environment(LiveFeed.self) private var feed

    var body: some View {
        let _ = feed.frame
        let model = WidgetModel.make(module, store: feed.store, sensors: sensors, clock: clock)
        WidgetRepresentable(module: module, model: model, config: config, sensors: sensors, clock: clock)
            .frame(width: WidgetRepresentable.width(module: module, model: model, config: config, sensors: sensors, clock: clock), height: NSStatusBar.system.thickness)
            .liveMetric(module == .sensors && sensors.stacked ? .temperatureStack : module.metric ?? .cpu)
    }
}

private struct WidgetRepresentable: NSViewRepresentable {
    let module: ModuleID
    let model: WidgetModel
    let config: WidgetConfig
    let sensors: SensorsDisplay
    var clock: ClockDisplay?

    static func width(module: ModuleID, model: WidgetModel, config: WidgetConfig, sensors: SensorsDisplay, clock: ClockDisplay?) -> CGFloat {
        let view = WidgetView(frame: NSRect(x: 0, y: 0, width: 0, height: NSStatusBar.system.thickness))
        configure(view, module: module, sensors: sensors, clock: clock)
        view.update(model, config: config)
        return view.intrinsicWidth
    }

    private static func configure(_ view: WidgetView, module: ModuleID, sensors: SensorsDisplay, clock: ClockDisplay?) {
        view.widestTexts = WidgetModel.widestTexts(for: module, sensors: sensors, clock: clock)
        view.reservesGlyph = module == .battery
        view.barCount = WidgetModel.barCount(for: module)
        if module == .clock { view.widestLabel = clock?.widestLabel }
    }

    func makeNSView(context: Context) -> WidgetView { WidgetView() }

    func updateNSView(_ view: WidgetView, context: Context) {
        Self.configure(view, module: module, sensors: sensors, clock: clock)
        view.update(model, config: config)
    }
}
