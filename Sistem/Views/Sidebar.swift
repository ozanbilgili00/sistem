import SistemUI
import SwiftUI
import SystemKit

struct Sidebar: View {
    @Binding var page: Page

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(ModuleID.allCases) { module in
                SidebarRow(title: Text(module.title), symbol: module.symbol, isSelected: page == .module(module)) {
                    page = .module(module)
                }
                if module == .dashboard {
                    Spacer().frame(height: 10)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 2) {
                FooterButton(symbol: "gearshape", help: "Ayarlar", isSelected: page == .settings) { page = .settings }
                FooterButton(symbol: "waveform.path.ecg", help: "Tanılama", isSelected: page == .diagnostics) { page = .diagnostics }
                Spacer()
                FooterButton(symbol: "power", help: "Çık", isSelected: false) { NSApp.terminate(nil) }
            }
        }
        .padding(.top, 52)
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .frame(width: Metrics.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.surface)
    }
}

private struct SidebarRow: View {
    let title: Text
    let symbol: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                title.font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Palette.accent : Palette.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(background, in: .rect(cornerRadius: Metrics.controlRadius))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var background: Color {
        if isSelected { return Palette.accentSoft }
        return isHovered ? Palette.surface2 : .clear
    }
}

private struct FooterButton: View {
    let symbol: String
    let help: LocalizedStringKey
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? Palette.accent : Palette.inkSecondary)
                .frame(width: 30, height: 28)
                .background(isSelected ? Palette.accentSoft : (isHovered ? Palette.surface2 : .clear), in: .rect(cornerRadius: Metrics.controlRadius))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovered = $0 }
    }
}
