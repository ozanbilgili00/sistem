import Observation
import SwiftUI
import SystemKit

/// The app's view of the displays: wraps the controller and mirrors its state for SwiftUI.
/// With the module off nothing is registered; with it on, the only work is the system's
/// reconfiguration callback. Pages and popovers tell it when they are visible.
@Observable
final class DisplayModel {
    private(set) var state = DisplayState()
    private(set) var isRunning = false

    @ObservationIgnored private let controller: DisplayController?
    @ObservationIgnored private var visibleCount = 0

    /// `controller` nil = a frozen preview (snapshots): nothing is created, nothing touched.
    @MainActor
    init(controller: DisplayController? = DisplayController(
        backend: CGDisplayBackend(), gamma: CGGammaBackend(), ddc: AVDDCProvider(), worker: QueueWorker(), clock: SystemDisplayClock())) {
        self.controller = controller
        controller?.onChange = { [weak self] in self?.sync() }
    }

    #if DEBUG
    init(previewing state: DisplayState) {
        controller = nil
        self.state = state
        isRunning = true
    }
    #endif

    @MainActor
    func apply(enabled: Bool) {
        guard let controller, enabled != isRunning else { return }
        isRunning = enabled
        if enabled {
            controller.start()
            if visibleCount > 0 { controller.setVisible(true) }
        } else {
            controller.stop()
        }
        sync()
    }

    /// A page or popover appeared / disappeared. Counted: the page and a popover can be open together.
    @MainActor
    func viewAppeared() {
        visibleCount += 1
        if visibleCount == 1 { controller?.setVisible(true) }
    }

    @MainActor
    func viewDisappeared() {
        visibleCount = max(0, visibleCount - 1)
        if visibleCount == 0 { controller?.setVisible(false) }
    }

    /// Quitting: a trial mode goes back, dimming and night tone are released.
    @MainActor
    func shutdown() { controller?.stop() }

    @MainActor func setControl(_ control: VCPControl, to value: UInt16, on id: DisplayID) { controller?.setControl(control, to: value, on: id) }
    @MainActor func setDim(_ value: Float, on id: DisplayID) { controller?.setDim(value, on: id) }
    @MainActor func setWarmth(_ value: Float, on id: DisplayID) { controller?.setWarmth(value, on: id) }
    @MainActor func resetColor(on id: DisplayID) { controller?.resetColor(on: id) }
    @MainActor @discardableResult func requestMode(_ mode: DisplayMode, on id: DisplayID) -> Bool { controller?.requestMode(mode, on: id) ?? false }
    @MainActor func confirmModeChange() { controller?.confirmModeChange() }
    @MainActor func revertModeChange() { controller?.revertModeChange() }

    @MainActor
    private func sync() {
        guard let controller else { return }
        if controller.state != state { state = controller.state }
    }
}
