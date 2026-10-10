import Darwin
import Foundation
import IOKit.ps

/// Everything the controller reads from the outside, replaceable in tests.
@MainActor
public struct AwakeSources {
    public var now: () -> Date
    /// Which of `wanted` are running right now. Called only while a process trigger is on.
    public var runningProcesses: (Set<String>) -> Set<String>
    public var guardInput: () -> GuardInput
    /// Bytes per second, down + up, since the previous call. nil = no baseline yet.
    public var networkRate: () -> Double?
    public var resetNetwork: () -> Void
    public var isOnPower: () -> Bool?

    public init(now: @escaping () -> Date, runningProcesses: @escaping (Set<String>) -> Set<String>,
                guardInput: @escaping () -> GuardInput, networkRate: @escaping () -> Double?,
                resetNetwork: @escaping () -> Void, isOnPower: @escaping () -> Bool?) {
        self.now = now
        self.runningProcesses = runningProcesses
        self.guardInput = guardInput
        self.networkRate = networkRate
        self.resetNetwork = resetNetwork
        self.isOnPower = isOnPower
    }

    /// The real thing. The SMC connection and the network baseline are created on first use,
    /// so a controller with everything off holds none of them.
    public static func live() -> AwakeSources {
        let box = LiveBox()
        return AwakeSources(
            now: Date.init,
            runningProcesses: { ProcessScan.running(among: $0) },
            guardInput: { box.guardInput() },
            networkRate: { box.networkRate() },
            resetNetwork: { box.network = nil },
            isOnPower: { PowerSourceProbe.read().map { !$0.onBattery } })
    }
}

@MainActor
private final class LiveBox {
    var sensors: SensorReader?
    var triedSensors = false
    var network: NetworkReader?

    func guardInput() -> GuardInput {
        let power = PowerSourceProbe.read()
        if sensors == nil, !triedSensors {
            triedSensors = true
            sensors = SensorReader()
        }
        let temperature = sensors?.sampleTemperature(includeGPU: true)
        let hottest = [temperature?.cpuHottest, temperature?.gpuHottest, temperature?.hottest].compactMap { $0 }.max()
        return GuardInput(batteryPercent: power?.percent, onBattery: power?.onBattery ?? false,
                          thermal: ProcessInfo.processInfo.thermalState, hottest: hottest)
    }

    func networkRate() -> Double? {
        let reader = network ?? NetworkReader()
        let fresh = network == nil
        network = reader
        guard let sample = reader.sample(), !fresh else { return nil }
        return sample.down + sample.up
    }
}

/// Battery charge and power source from the power-source API (one call, ~0.1 ms).
enum PowerSourceProbe {
    static func read() -> (percent: Int, onBattery: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() else { return nil }
        let onBattery = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) == kIOPMBatteryPowerKey
        for index in 0..<CFArrayGetCount(list) {
            let source = unsafeBitCast(CFArrayGetValueAtIndex(list, index), to: CFTypeRef.self)
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return (min(100, current * 100 / maximum), onBattery)
        }
        return nil
    }
}

/// Finds running processes by name with `proc_listallpids` + `proc_name`: no `ps`, no fork.
/// Some tools run from a versioned file (Claude Code's `claude` shows up as "2.1.296"), so a
/// name that looks like a version also has its path checked for `<tool>/versions/`.
public enum ProcessScan {
    public static func running(among wanted: Set<String>) -> Set<String> {
        guard !wanted.isEmpty else { return [] }
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return [] }
        var found: Set<String> = []
        var name = [CChar](repeating: 0, count: 64)
        for pid in pids.prefix(count) where pid > 0 {
            let length = Int(proc_name(pid, &name, 64))
            guard length > 0 else { continue }
            let text = string(name, length: length)
            if wanted.contains(text) {
                found.insert(text)
            } else if looksLikeVersion(text), let tool = versionedTool(pid: pid, among: wanted) {
                found.insert(tool)
            }
            if found.count == wanted.count { break }
        }
        return found
    }

    static func looksLikeVersion(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first, ("0"..."9").contains(first) else { return false }
        return text.contains(".")
    }

    /// `/…/<tool>/versions/<version>` → `<tool>`.
    static func toolName(inPath path: String, among wanted: Set<String>) -> String? {
        let parts = path.split(separator: "/")
        guard let i = parts.firstIndex(of: "versions"), i > 0 else { return nil }
        let tool = String(parts[i - 1])
        return wanted.contains(tool) ? tool : nil
    }

    private static func versionedTool(pid: pid_t, among wanted: Set<String>) -> String? {
        var path = [CChar](repeating: 0, count: 1024)
        let length = Int(proc_pidpath(pid, &path, 1024))
        guard length > 0 else { return nil }
        return toolName(inPath: string(path, length: length), among: wanted)
    }

    private static func string(_ buffer: [CChar], length: Int) -> String {
        String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
