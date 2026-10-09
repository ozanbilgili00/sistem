import Darwin
import Foundation
import notify
import SystemKit

/// `sistem-probe --battery-check [samples] [seconds]`: Phase 7 gate. Compares our battery
/// reading with `pmset -g batt` (read-only, fixed argument array) several times, shows the
/// health and charger fields, checks that a power-source notification reaches the reader and
/// prices a sample.

private struct PMSetReading {
    var percent: Int
    var state: String      // "discharging" / "charging" / "charged" / "AC attached; not charging"
    var time: String?      // "H:MM", nil for none or "(no estimate)"
    var raw: String
}

private func readPMSet() -> PMSetReading? {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/pmset")
    process.arguments = ["-g", "batt"]
    process.environment = ["LC_ALL": "C"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard data.count < 4096, let text = String(data: data, encoding: .utf8) else { return nil }
    return parsePMSet(text)
}

/// "  -InternalBattery-0 (id=1)\t80%; discharging; 3:35 remaining present: true".
private func parsePMSet(_ text: String) -> PMSetReading? {
    guard let line = text.split(separator: "\n").first(where: { $0.contains("InternalBattery") }),
          let percentRange = line.range(of: #"\d+%"#, options: .regularExpression),
          let percent = Int(line[percentRange].dropLast()) else { return nil }
    let rest = line[percentRange.upperBound...]
    var segments = rest.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
    guard !segments.isEmpty else { return nil }
    // "not charging present: true" → drop the trailing "present: …".
    segments = segments.map { segment in
        if let r = segment.range(of: " present:") { return String(segment[..<r.lowerBound]) }
        return segment
    }
    var time: String?
    var words = segments
    if let last = words.last, let r = last.range(of: #"\d+:\d\d"#, options: .regularExpression), last.contains("remaining") {
        time = String(last[r])
        words.removeLast()
    } else if let last = words.last, last.contains("no estimate") {
        words.removeLast()
    }
    var state = words.joined(separator: "; ")
    if state == "finishing charge" { state = "charging" }
    return PMSetReading(percent: percent, state: state, time: time, raw: String(line))
}

private func ourState(_ sample: BatterySample) -> String {
    switch sample.state {
    case .discharging: "discharging"
    case .charging: "charging"
    case .charged: "charged"
    case .pluggedNotCharging: "AC attached; not charging"
    }
}

func batteryCheck(samples: Int, gap: Double) {
    print("Batarya denetimi (sistem-probe --battery-check)")
    let events = EventCounter()
    let reader = BatteryReader { events.bump() }
    var matches = 0, total = 0
    for round in 1...samples {
        reader.markChanged()
        let before = reader.sample()
        guard let pm = readPMSet() else { print("pmset okunamadı"); break }
        reader.markChanged()
        let after = reader.sample()
        guard case .present(let a) = after else {
            print("  [\(round)] Bu Mac'te batarya yok (BatteryStatus.notPresent); pmset: \(pm.raw)")
            return
        }
        let earlier = before.sample
        // pmset runs between our two reads; a value that moved in between may match either.
        func agrees(_ ours: BatterySample?) -> Bool {
            guard let ours else { return false }
            return ours.percent == pm.percent && ourState(ours) == pm.state && (ours.remainingText == pm.time || (pm.time == "0:00" && ours.minutesRemaining == nil))
        }
        let ok = agrees(a) || agrees(earlier)
        total += 1
        if ok { matches += 1 }
        let ours = "\(a.percent)% · \(ourState(a)) · \(a.remainingText ?? (a.isEstimating ? "(no estimate)" : "-"))"
        let theirs = "\(pm.percent)% · \(pm.state) · \(pm.time ?? "-")"
        print("  [\(round)] bizim: \(ours)   pmset: \(theirs)   \(ok ? "✓" : "✗ FARKLI")")
        if round == 1 {
            if let h = a.health {
                print("      sağlık: azami kapasite %\(h.maximumCapacityPercent.map(String.init) ?? "?") (\(h.nominalCapacity ?? 0)/\(h.designCapacity ?? 0) mAh), döngü \(h.cycleCount ?? -1)/\(h.designCycleCount ?? -1)")
                print(String(format: "      elektrik: %.3f V, %.3f A, pil gücü %.2f W, sistem yükü %@ W, sıcaklık %@ °C",
                             h.volts ?? .nan, h.amps ?? .nan, h.batteryWatts ?? .nan,
                             h.systemWatts.map { String(format: "%.2f", $0) } ?? "?", h.temperatureCelsius.map { String(format: "%.1f", $0) } ?? "?"))
            }
            if let adapter = a.adapter { print("      adaptör: \(adapter.watts.map { "\($0) W" } ?? "?") · \(adapter.name ?? "?")") }
            else { print("      adaptör: yok (pilde)") }
        }
        if round < samples { RunLoop.main.run(until: .now + gap) }  // lets power-source events in
    }
    print("Eşleşme: \(matches)/\(total)")

    // Cost: the event path rereads the power source and the registry; a tick reads the registry only.
    let n = 2_000
    let t0 = cpuSeconds()
    for _ in 0..<n { _ = reader.sample() }
    let tick = (cpuSeconds() - t0) / Double(n) * 1e6
    let t1 = cpuSeconds()
    for _ in 0..<n { reader.markChanged(); _ = reader.sample() }
    let event = (cpuSeconds() - t1) / Double(n) * 1e6
    print(String(format: "Maliyet: tik okuması %.0f µs CPU, olay okuması %.0f µs CPU (power source okuması: %d)", tick, event, reader.powerSourceReads))

    // Does the run-loop source deliver? Post the notification the power-source API listens to.
    let before = events.value
    let status = notify_post("com.apple.system.powersources.timeremaining")
    RunLoop.main.run(until: .now + 1.5)
    print("Bildirim: notify_post durumu \(status), IOPS geri çağırması \(events.value - before) kez (toplam \(events.value))")
    if events.value - before == 0 {
        print("  (sistem bildirimleri üçüncü taraf süreçten gönderilemiyor olabilir; gerçek prize takma/çıkarma olayı bu araçla tetiklenmez)")
    }
}

private func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return s(usage.ru_utime) + s(usage.ru_stime)
}

private final class EventCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// `sistem-probe --battery-watch [seconds]`: prints a line for every power-source event the reader
/// receives, with what a reread then shows. Unplug or plug the charger while it runs. System
/// notifications cannot be posted from a normal process, so this is the only way to see the
/// event path work.
func batteryWatch(seconds: Double) {
    let events = EventCounter()
    let reader = BatteryReader { events.bump() }
    print("İzleniyor (\(Int(seconds)) sn). Şarj cihazını takıp çıkarın; her olay bir satır yazar.")
    var last = events.value
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(until: .now + 0.5)
        if events.value != last {
            last = events.value
            reader.markChanged()
            if case .present(let s) = reader.sample() {
                print("  olay #\(last): \(s.percent)% · \(ourState(s)) · \(s.remainingText ?? (s.isEstimating ? "(no estimate)" : "-"))")
            }
        }
    }
    print("Toplam olay: \(events.value)")
}
