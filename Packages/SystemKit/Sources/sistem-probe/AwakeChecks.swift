import Darwin
import Foundation
import SystemKit

/// `sistem-probe --awake-check <name> [seconds ≤ 30]`: Phase 9 gate. Holds a real
/// `PreventUserIdleSystemSleep` assertion through ``KeepAwakeController`` under a unique name
/// (never a display assertion), prints the pid, and lists its own holders. A tester reads
/// `pmset -g assertions` (read-only) and then `kill -9 <pid>`; the assertion must vanish with
/// the process. Without a kill the controller's timer releases it after `seconds`.
@MainActor
func awakeCheck(name: String, seconds: Double) {
    let seconds = min(max(seconds, 3), 30)
    let sources = AwakeSources.live()
    let input = sources.guardInput()
    print("protection inputs: battery=\(input.batteryPercent.map(String.init) ?? "-")% onBattery=\(input.onBattery) thermal=\(input.thermal.rawValue) hottest=\(input.hottest.map { String(format: "%.1f", $0) } ?? "-")")
    let controller = KeepAwakeController(assertionName: name)
    controller.apply(KeepAwakeConfig(enabled: true))
    let started = controller.startManual(duration: seconds)
    print("pid \(getpid()) assertion \"\(name)\" held=\(controller.state.isHolding) started=\(started) for \(Int(seconds)) s")
    let own = AssertionReader.read().holders.first { $0.isSelf }
    print("own row in AssertionReader: \(own != nil) display=\(own?.preventsDisplaySleep ?? false)")
    fflush(stdout)
    RunLoop.main.run(until: Date().addingTimeInterval(seconds + 2))
    print("after expiry: held=\(controller.state.isHolding) manual=\(controller.state.manualActive)")
}
