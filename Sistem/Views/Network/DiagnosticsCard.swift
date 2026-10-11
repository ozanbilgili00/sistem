import Observation
import SistemUI
import SwiftUI
import SystemKit

/// Runs one network tool at a time, only when the user presses the button. Nothing is kept after the page closes.
@MainActor @Observable
final class DiagnosticsModel {
    enum Phase: Equatable { case idle, running, done(DiagnosticOutcome) }

    private(set) var phase: Phase = .idle
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let tools: NetworkDiagnostics

    init(tools: NetworkDiagnostics = NetworkDiagnostics()) { self.tools = tools }

    #if DEBUG
    init(previewing phase: Phase) {
        tools = NetworkDiagnostics()
        self.phase = phase
    }
    #endif

    func start(_ tool: DiagnosticTool, host: String, port: String) {
        guard phase != .running else { return }
        phase = .running
        let tools = tools
        task = Task { [weak self] in
            let outcome = await tools.run(tool, host: host, port: port)
            guard !Task.isCancelled else { return }
            self?.phase = .done(outcome)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    func clear() { if phase != .running { phase = .idle } }
}

struct DiagnosticsCard: View {
    @State private var model: DiagnosticsModel
    @State private var tool = DiagnosticTool.ping
    @State private var host = ""
    @State private var port = "443"

    init(model: DiagnosticsModel = DiagnosticsModel()) {
        _model = State(initialValue: model)
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Tanılama")
                HStack(spacing: 10) {
                    Picker("Araç", selection: $tool) {
                        Text("Ping").tag(DiagnosticTool.ping)
                        Text("DNS sorgusu").tag(DiagnosticTool.dns)
                        Text("Port kontrolü").tag(DiagnosticTool.port)
                        Text("Traceroute").tag(DiagnosticTool.traceroute)
                    }
                    .labelsHidden().fixedSize()
                    TextField("Ana makine ya da IP", text: $host).textFieldStyle(.roundedBorder).onSubmit(run)
                    if tool == .port { TextField("Port", text: $port).textFieldStyle(.roundedBorder).frame(width: 70) }
                    if model.phase == .running {
                        Button("İptal", action: model.cancel).buttonStyle(QuietButtonStyle())
                    } else {
                        Button("Başlat", action: run).buttonStyle(AccentButtonStyle()).disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                switch model.phase {
                case .idle:
                    Text("Araçlar yalnızca Başlat'a bastığınızda çalışır; arka planda hiçbir sınama yapılmaz.")
                        .font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
                case .running:
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Çalışıyor…").font(.sistemBody).foregroundStyle(Palette.inkSecondary) }
                case .done(let outcome):
                    DiagnosticResultView(outcome: outcome)
                }
            }
        }
    }

    private func run() { model.start(tool, host: host, port: port) }
}

struct DiagnosticResultView: View {
    let outcome: DiagnosticOutcome

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch outcome {
            case .ping(let result):
                line("Gönderilen / alınan", "\(result.sent) / \(result.received)")
                line("Kayıp", "\(Int(result.lossPercent.rounded())) %")
                if let average = result.average {
                    line("En az / ortalama / en çok", [result.minimum, average, result.maximum].compactMap { $0 }.map { Format.decimal($0, digits: 1) }.joined(separator: " / ") + " ms")
                }
                if result.received == 0 { Text("Yanıt gelmedi.").font(.sistemBody).foregroundStyle(Palette.warning) }
            case .dns(let result):
                ForEach(result.addresses, id: \.self) { Text(verbatim: $0).font(.sistemValue).foregroundStyle(Palette.ink) }
            case .port(let result):
                switch result.state {
                case .open:
                    Pill(Text("Açık"), tone: .good)
                    if let ms = result.milliseconds { line("Bağlantı süresi", "\(Format.decimal(ms, digits: 1)) ms") }
                case .refused: Pill(Text("Kapalı ya da reddedildi"), tone: .critical)
                case .timedOut: Pill(Text("Zaman aşımı"), tone: .warning)
                }
            case .traceroute(let result):
                ForEach(result.hops) { hop in
                    HStack {
                        Text(verbatim: "\(hop.index)").font(.sistemValue).foregroundStyle(Palette.inkTertiary).frame(width: 26, alignment: .trailing)
                        Text(verbatim: hop.address ?? "*").font(.sistemValue).foregroundStyle(Palette.ink)
                        Spacer()
                        if let ms = hop.milliseconds { Text(verbatim: "\(Format.decimal(ms, digits: 1)) ms").font(.sistemValue).foregroundStyle(Palette.inkSecondary) }
                    }
                }
            case .failed(let failure):
                Text(message(failure)).font(.sistemBody).foregroundStyle(Palette.warning)
            }
        }
    }

    private func line(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title).font(.sistemBody).foregroundStyle(Palette.inkSecondary)
            Spacer()
            Text(verbatim: value).font(.sistemValue).foregroundStyle(Palette.ink)
        }
    }

    private func message(_ failure: DiagnosticFailure) -> LocalizedStringKey {
        switch failure {
        case .invalidInput: "Girdi geçersiz. Ana makine adı ya da IP adresi (ve port için 1-65535) yazın."
        case .timedOut: "İşlem zaman aşımına uğradı."
        case .toolMissing: "Sistem aracı başlatılamadı."
        case .noAnswer: "Yanıt alınamadı ya da ad çözülemedi."
        case .cancelled: "İptal edildi."
        case .badOutput: "Araç beklenen çıktıyı vermedi."
        }
    }
}
