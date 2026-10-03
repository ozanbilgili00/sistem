import SistemUI
import SwiftUI

struct MainView: View {
    @Bindable var settings: SettingsStore
    /// Fixes the page instead of restoring the last one (snapshots, previews).
    var pinnedPage: Page?
    @AppStorage("selectedPage") private var pageID = Page.module(.dashboard).rawValue

    private var page: Binding<Page> {
        Binding(get: { pinnedPage ?? Page(rawValue: pageID) }, set: { pageID = $0.rawValue })
    }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(page: page)
            Rectangle().fill(Palette.line).frame(width: 1)
            ScrollView {
                detail
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.top, 44)
                    .padding(.bottom, Metrics.pagePadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.background)
        .ignoresSafeArea()
    }

    @ViewBuilder private var detail: some View {
        switch page.wrappedValue {
        case .module(let id): ModulePage(module: id, settings: settings)
        case .settings: SettingsView(settings: settings)
        case .diagnostics: DiagnosticsView()
        }
    }
}
