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
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Menü çubuğu")
                    Text("Menü çubuğunda gösterilecek modül seçili değil. Ayarlar'dan CPU, RAM, GPU ya da sıcaklığı açabilirsin.")
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
