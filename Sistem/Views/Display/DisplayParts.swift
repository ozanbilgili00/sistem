import SistemUI
import SwiftUI
import SystemKit

/// One display: identity, readouts, hardware sliders, software dimming and (full size) the mode picker.
struct DisplayCard: View {
    let entry: DisplayEntry
    let model: DisplayModel
    /// Popover: sliders only, no readouts and no mode picker.
    var compact = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                header
                if !compact {
                    DisplayReadouts(info: entry.info)
                    Rectangle().fill(Palette.line).frame(height: 1)
                }
                DisplayHardwareControls(entry: entry, model: model)
                Rectangle().fill(Palette.line).frame(height: 1)
                DisplaySoftwareControls(entry: entry, model: model)
                if !compact, entry.modes.count > 1 {
                    Rectangle().fill(Palette.line).frame(height: 1)
                    DisplayModePicker(entry: entry, model: model)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.info.isBuiltIn ? "laptopcomputer" : "display")
                .font(.system(size: 18, weight: .medium)).foregroundStyle(Palette.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: DisplayText.name(entry.info)).font(.sistemHeading).foregroundStyle(Palette.ink).lineLimit(1)
                Text(verbatim: "\(DisplayText.resolution(entry.info.mode)) · \(DisplayText.refresh(entry.info.mode))")
                    .font(.sistemCaption).foregroundStyle(Palette.inkSecondary)
            }
            Spacer(minLength: 8)
            if entry.info.isMain { Pill(Text("Ana ekran"), tone: .accent) }
            if entry.info.isMirrored { Pill(Text("Yansıtılmış"), tone: .neutral) }
            Pill(Text(entry.info.isBuiltIn ? "Dahili" : "Harici"), tone: .neutral)
        }
    }
}

/// Resolution, scale, refresh rate and HDR as label / value pairs.
struct DisplayReadouts: View {
    let info: DisplayInfo

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
            GridRow {
                readout("Çözünürlük", DisplayText.resolution(info.mode))
                readout("Piksel", DisplayText.pixels(info.mode))
            }
            GridRow {
                readout("Ölçek", DisplayText.scale(info.mode))
                readout("Yenileme hızı", DisplayText.refresh(info.mode))
            }
            GridRow {
                readout("HDR", DisplayText.hdr(info))
                readout("Yön", info.rotation == 0 ? "0°" : "\(info.rotation)°")
            }
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

/// A slider drawn from the palette: the system one is a pale grey on the light card and its knob nearly vanishes.
struct DisplaySlider: View {
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let label: LocalizedStringKey
    private let knob: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            let span = max(1, proxy.size.width - knob)
            let fraction = (value.wrappedValue - range.lowerBound) / (range.upperBound - range.lowerBound)
            let x = min(1, max(0, fraction)) * span
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.inkTertiary.opacity(0.28)).frame(height: 5)
                Capsule().fill(Palette.accent).frame(width: x + knob / 2, height: 5)
                Circle().fill(Palette.surface).overlay(Circle().strokeBorder(Palette.accent, lineWidth: 2))
                    .frame(width: knob, height: knob).offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let f = min(1, max(0, (drag.location.x - knob / 2) / span))
                value.wrappedValue = range.lowerBound + f * (range.upperBound - range.lowerBound)
            })
        }
        .frame(height: 20)
        .accessibilityElement()
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(verbatim: DisplayText.percent(value.wrappedValue)))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 20
            let next = value.wrappedValue + (direction == .increment ? step : -step)
            value.wrappedValue = min(range.upperBound, max(range.lowerBound, next))
        }
    }
}

/// A labelled slider with its value.
struct DisplaySliderRow: View {
    let title: LocalizedStringKey
    let symbol: String
    let value: Binding<Double>
    var range: ClosedRange<Double> = 0...1

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Palette.inkTertiary).frame(width: 18)
            Text(title).font(.sistemBody).foregroundStyle(Palette.ink).frame(width: 96, alignment: .leading)
            DisplaySlider(value: value, range: range, label: title)
            Text(verbatim: DisplayText.percent(value.wrappedValue))
                .font(.sistemValue).foregroundStyle(Palette.inkSecondary).frame(width: 52, alignment: .trailing)
        }
    }
}

/// DDC sliders and the input picker, or the reason there are none.
struct DisplayHardwareControls: View {
    let entry: DisplayEntry
    let model: DisplayModel
    /// An input the user picked but has not confirmed: nothing is written until "Geç".
    @State private var pendingInput: UInt16?

    init(entry: DisplayEntry, model: DisplayModel, pendingInput: UInt16? = nil) {
        self.entry = entry
        self.model = model
        _pendingInput = State(initialValue: pendingInput)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Donanım")
            switch entry.ddc {
            case .unknown:
                Text("Okunuyor…").font(.sistemBody).foregroundStyle(Palette.inkSecondary)
            case .unsupported(let reason):
                if reason == .builtIn, let level = entry.info.brightness {
                    HStack(spacing: 10) {
                        Image(systemName: "sun.max").font(.system(size: 12)).foregroundStyle(Palette.inkTertiary).frame(width: 18)
                        Text("Parlaklık").font(.sistemBody).foregroundStyle(Palette.ink).frame(width: 96, alignment: .leading)
                        MeterBar(Double(level))
                        Text(verbatim: DisplayText.percent(Double(level)))
                            .font(.sistemValue).foregroundStyle(Palette.inkSecondary).frame(width: 52, alignment: .trailing)
                    }
                }
                Text(DisplayText.unsupported(reason)).font(.sistemCaption).foregroundStyle(Palette.inkSecondary)
            case .supported:
                ForEach([VCPControl.brightness, .contrast, .volume], id: \.self) { control in
                    if let value = entry.controls[control] {
                        DisplaySliderRow(title: DisplayText.control(control), symbol: DisplayText.controlSymbol(control), value: Binding(
                            get: { value.fraction },
                            set: { model.setControl(control, to: UInt16((($0) * Double(value.maximum)).rounded()), on: entry.id) }
                        ))
                    }
                }
                if let input = entry.controls[.inputSource] {
                    inputPicker(current: input.current)
                    if let value = pendingInput { inputConfirmation(value) }
                }
                if entry.ddcWriteFailed {
                    Text("Monitör son değişikliği kabul etmedi.").font(.sistemCaption).foregroundStyle(Palette.warning)
                }
            }
        }
    }

    private func inputPicker(current: UInt16) -> some View {
        let choices = DDCInput.known.contains(current) ? DDCInput.known : DDCInput.known + [current]
        return HStack(spacing: 10) {
            Image(systemName: DisplayText.controlSymbol(.inputSource)).font(.system(size: 12)).foregroundStyle(Palette.inkTertiary).frame(width: 18)
            Text(DisplayText.control(.inputSource)).font(.sistemBody).foregroundStyle(Palette.ink).frame(width: 96, alignment: .leading)
            Picker("Giriş", selection: Binding(get: { current }, set: { if $0 != current { pendingInput = $0 } })) {
                ForEach(choices, id: \.self) { Text(verbatim: DDCInput.name($0)).tag($0) }
            }
            .labelsHidden().fixedSize()
            Spacer(minLength: 0)
        }
    }

    /// Switching to an input without a signal blacks the monitor out, and the Mac can not bring it back.
    private func inputConfirmation(_ value: UInt16) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(DDCInput.name(value)) girişine geçilsin mi?").font(.sistemBody).foregroundStyle(Palette.ink)
            Text("Bu girişte sinyal yoksa görüntü kaybolur; geri dönmek için monitörün kendi düğmelerini kullanın.")
                .font(.sistemCaption).foregroundStyle(Palette.warning)
            HStack(spacing: 8) {
                Button("Vazgeç") { pendingInput = nil }.buttonStyle(QuietButtonStyle())
                Button("Geç") {
                    model.setControl(.inputSource, to: value, on: entry.id)
                    pendingInput = nil
                }.buttonStyle(AccentButtonStyle())
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface2, in: .rect(cornerRadius: Metrics.controlRadius))
    }
}

/// Software dimming and night tone: work on any display, through its transfer table.
struct DisplaySoftwareControls: View {
    let entry: DisplayEntry
    let model: DisplayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel("Yazılımsal")
                Spacer()
                if entry.colorIsAdjusted {
                    Button("Sıfırla") { model.resetColor(on: entry.id) }.buttonStyle(QuietButtonStyle())
                }
            }
            DisplaySliderRow(title: "Karartma", symbol: "moon", value: Binding(
                get: { Double(entry.dim) },
                set: { model.setDim(Float($0), on: entry.id) }
            ), range: Double(GammaCurve.minimumDim)...1)
            DisplaySliderRow(title: "Gece tonu", symbol: "sun.haze", value: Binding(
                get: { Double(entry.warmth) },
                set: { model.setWarmth(Float($0), on: entry.id) }
            ))
        }
    }
}

/// Resolution and refresh rate choice. Applying is a trial that must be confirmed.
struct DisplayModePicker: View {
    let entry: DisplayEntry
    let model: DisplayModel
    @State private var chosenSize: DisplayModeCatalog.Size?
    @State private var chosenModeID: Int32?

    private var currentSize: DisplayModeCatalog.Size? {
        entry.info.mode.map { DisplayModeCatalog.Size(width: $0.width, height: $0.height, isHiDPI: $0.isHiDPI) }
    }

    var body: some View {
        let sizes = DisplayModeCatalog.sizes(of: entry.modes)
        let size = chosenSize ?? currentSize ?? sizes.first
        let rates = size.map { DisplayModeCatalog.rates(for: $0, in: entry.modes) } ?? []
        let target = rates.first { $0.id == chosenModeID } ?? rates.first { $0.id == entry.info.mode?.id } ?? rates.first
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Çözünürlük ve yenileme hızı")
            HStack(spacing: 10) {
                Picker("Çözünürlük", selection: Binding(get: { size ?? sizes[0] }, set: { chosenSize = $0; chosenModeID = nil })) {
                    ForEach(sizes) { Text(verbatim: DisplayText.size($0)).tag($0) }
                }
                .labelsHidden().fixedSize()
                Picker("Yenileme hızı", selection: Binding(get: { target?.id ?? 0 }, set: { chosenModeID = $0 })) {
                    ForEach(rates) { Text(verbatim: DisplayText.refresh($0)).tag($0.id) }
                }
                .labelsHidden().fixedSize()
                Spacer(minLength: 0)
                Button("Uygula") {
                    if let target { model.requestMode(target, on: entry.id) }
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(target == nil || target?.id == entry.info.mode?.id || model.state.pending != nil)
            }
            Text("Yeni mod önce deneme olarak uygulanır; 15 saniye içinde onaylamazsanız eski moda dönülür.")
                .font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
            if model.state.modeChangeFailed {
                Text("Sistem bu modu kabul etmedi.").font(.sistemCaption).foregroundStyle(Palette.warning)
            }
        }
    }
}

/// The open trial: what was applied and the seconds left before it is undone.
struct ModeTrialBanner: View {
    let pending: PendingModeChange
    let model: DisplayModel

    var body: some View {
        Card {
            HStack(spacing: 14) {
                Image(systemName: "timer").font(.system(size: 20, weight: .medium)).foregroundStyle(Palette.warning).frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Bu modu koruyalım mı?").font(.sistemHeading).foregroundStyle(Palette.ink)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = max(0, Int(pending.deadline.timeIntervalSince(context.date).rounded(.up)))
                        Text("\(DisplayController.describe(pending.to)) uygulandı. \(seconds) saniye içinde onaylanmazsa eski moda dönülür.")
                            .font(.sistemCaption).foregroundStyle(Palette.inkSecondary)
                    }
                }
                Spacer(minLength: 0)
                Button("Geri al") { model.revertModeChange() }.buttonStyle(QuietButtonStyle())
                Button("Koru") { model.confirmModeChange() }.buttonStyle(AccentButtonStyle())
            }
        }
    }
}

/// Connection log, newest first.
struct DisplayEventList: View {
    let events: [DisplayEvent]
    var limit = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if events.isEmpty {
                Text("Henüz bir değişiklik olmadı. Ekran takıldığında ya da çıkarıldığında burada görünür.")
                    .font(.sistemBody).foregroundStyle(Palette.inkSecondary)
            }
            ForEach(events.prefix(limit)) { event in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: DisplayText.eventSymbol(event.kind)).font(.system(size: 12)).foregroundStyle(Palette.inkTertiary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(DisplayText.eventTitle(event.kind)).font(.sistemBody).foregroundStyle(Palette.ink)
                            if !event.name.isEmpty {
                                Text(verbatim: event.name).font(.sistemBody).foregroundStyle(Palette.inkSecondary).lineLimit(1)
                            }
                        }
                        if !event.detail.isEmpty {
                            Text(verbatim: event.detail).font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(event.date, style: .time).font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
                }
            }
        }
    }
}
