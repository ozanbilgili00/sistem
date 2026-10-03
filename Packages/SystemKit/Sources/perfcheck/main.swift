// perfcheck <pid> [--warmup S] [--seconds S] [--cpu PCT] [--mem MB] [--wakeups N]
//
// Measures another process (same user) over a window and fails if any budget is
// exceeded. scripts/perf-check.sh drives it; every phase gate runs it.

import Foundation
import SystemKit

func option(_ name: String, default value: Double) -> Double {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count, let v = Double(args[i + 1]) else { return value }
    return v
}

guard CommandLine.arguments.count > 1, let pid = Int32(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("kullanım: perfcheck <pid> [--warmup S] [--seconds S] [--cpu PCT] [--mem MB] [--wakeups N]\n".utf8))
    exit(2)
}

let warmup = option("--warmup", default: 10)
let window = option("--seconds", default: 60)
let budgetCPU = option("--cpu", default: EnergyBudget.idleCPUPercent)
let budgetMem = option("--mem", default: EnergyBudget.idleFootprintMB)
let budgetWakeups = option("--wakeups", default: EnergyBudget.idleWakeupsPerSecond)

print("ısınma \(Int(warmup)) sn, ölçüm \(Int(window)) sn (pid \(pid))…")
Thread.sleep(forTimeInterval: warmup)
guard let start = ProcessUsage.read(pid: pid) else { print("süreç okunamadı"); exit(2) }
Thread.sleep(forTimeInterval: window)
guard let end = ProcessUsage.read(pid: pid) else { print("süreç ölçüm sırasında kapandı"); exit(2) }

let rate = end.rate(since: start)

/// Prints one line; returns false when the value is over budget.
func row(_ label: String, _ value: Double, _ unit: String, budget: Double?) -> Bool {
    let v = String(format: "%8.3f", value)
    guard let budget else { print("  \(label.padding(toLength: 14, withPad: " ", startingAt: 0))\(v) \(unit)"); return true }
    let ok = value < budget
    let b = String(format: "%.2f", budget)
    print("  \(label.padding(toLength: 14, withPad: " ", startingAt: 0))\(v) \(unit.padding(toLength: 6, withPad: " ", startingAt: 0)) < \(b)  \(ok ? "✓" : "✗ AŞILDI")")
    return ok
}

let results = [
    row("CPU", rate.cpuPercent, "%", budget: budgetCPU),
    row("Bellek", rate.footprintMB, "MB", budget: budgetMem),
    row("Uyanma", rate.wakeupsPerSecond, "/sn", budget: budgetWakeups),
    row("Güç", rate.milliwatts, "mW", budget: nil),
]
let failed = results.contains(false)

print(failed ? "SONUÇ: bütçe aşıldı" : "SONUÇ: bütçe içinde")
exit(failed ? 1 : 0)
