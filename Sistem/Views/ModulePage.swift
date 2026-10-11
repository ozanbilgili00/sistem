import SistemUI
import SwiftUI
import SystemKit

/// Routes a module to its page.
struct ModulePage: View {
    let module: ModuleID
    @Bindable var settings: SettingsStore

    var body: some View {
        switch module {
        case .dashboard: DashboardPage(settings: settings)
        case .cpu: CPUPage(settings: settings)
        case .gpu: GPUPage(settings: settings)
        case .ram: RAMPage(settings: settings)
        case .disk: DiskPage(settings: settings)
        case .network: NetworkPage(settings: settings)
        case .sensors: SensorsPage(settings: settings)
        case .battery: BatteryPage(settings: settings)
        case .bluetooth: BluetoothPage(settings: settings)
        case .clock: ClockPage(settings: settings)
        case .keepAwake: KeepAwakePage(settings: settings)
        case .display: DisplayPage(settings: settings)
        }
    }
}
