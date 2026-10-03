import SistemUI
import SwiftUI
import SystemKit

struct PopoverView: View {
    let openWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(verbatim: "Sistem").font(.sistemHeading).foregroundStyle(Palette.ink)
                Spacer()
                Pill(Text("Faz \(0)"), tone: .neutral)
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Menü çubuğu")
                    Text("CPU, RAM ve GPU yüzde, sıcaklık derece olarak burada görünecek. Canlı veriler Faz 2'de geliyor.")
                        .font(.sistemCaption)
                        .foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button("Pencereyi Aç", action: openWindow).buttonStyle(AccentButtonStyle())
                Spacer()
                Button("Çık") { NSApp.terminate(nil) }.buttonStyle(QuietButtonStyle())
            }
        }
        .padding(16)
        .frame(width: 300)
        .background(Palette.background)
    }
}
