import Foundation
import SystemKit

/// `sistem-probe --display-check`: Phase 10 read-only look at the displays. Lists each display
/// with its mode, EDR headroom and (built-in) brightness, and asks every external monitor that
/// has a DDC channel for its brightness, contrast, volume and input values. It changes nothing:
/// no mode switch, no gamma table, no DDC write. Names and numbers are printed only for the
/// person running it; nothing is stored.
@MainActor
func displayCheck() {
    let backend = CGDisplayBackend()
    let provider = AVDDCProvider()
    let infos = backend.displays()
    print("\(infos.count) display(s)")
    for info in infos {
        let mode = DisplayController.describe(info.mode)
        let brightness = info.brightness.map { String(format: "%.3f", $0) } ?? "-"
        print("- id \(info.id) \(info.isBuiltIn ? "built-in" : "external")\(info.isMain ? " main" : "")\(info.isMirrored ? " mirrored" : "") mode \(mode) scale \(info.mode.map { String(format: "%.0f", $0.scale) } ?? "-")x rot \(info.rotation) edr \(String(format: "%.2f", info.edrCurrent))/\(String(format: "%.1f", info.edrPotential)) brightness \(brightness)")
        let modes = backend.modes(for: info.id)
        let sizes = DisplayModeCatalog.sizes(of: modes)
        let rates = Set(modes.map { Int($0.refreshRate.rounded()) }).sorted()
        print("  \(modes.count) usable modes, \(sizes.count) sizes, rates \(rates.map(String.init).joined(separator: "/")) Hz")
        guard !info.isBuiltIn else { continue }
        guard let transport = provider.transport(for: info, among: infos) else {
            print("  DDC: no channel (unsupported, clean fallback)")
            continue
        }
        for control in VCPControl.allCases {
            let started = Date()
            let value = transport.read(control.code)
            let ms = Date().timeIntervalSince(started) * 1000
            print("  DDC 0x\(String(control.code, radix: 16)): \(value.map { "\($0.current)/\($0.maximum)" } ?? "no answer") (\(String(format: "%.0f", ms)) ms)")
        }
    }
}
