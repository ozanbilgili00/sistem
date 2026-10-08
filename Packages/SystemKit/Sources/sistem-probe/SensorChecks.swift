import Darwin
import Foundation
import SystemKit

private func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

private func wallSeconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

/// (wall µs, CPU µs) per call of `body`.
private func cost(_ iterations: Int, _ body: () -> Void) -> (wall: Double, cpu: Double) {
    let w0 = wallSeconds(), c0 = cpuSeconds()
    for _ in 0..<iterations { body() }
    return ((wallSeconds() - w0) / Double(iterations) * 1e6, (cpuSeconds() - c0) / Double(iterations) * 1e6)
}

private func label(_ info: SensorInfo) -> String {
    switch info.label {
    case .raw(let key): key
    case .indexed(let base, let n): "\(base.rawValue) \(n)"
    case .named(let base): base.rawValue
    }
}

private func unit(_ kind: SensorKind) -> String {
    switch kind {
    case .temperature: "°C"
    case .voltage: "V"
    case .current: "A"
    case .power: "W"
    case .fan: "rpm"
    }
}

private func spin(seconds: Double, threads: Int) {
    let deadline = Date().addingTimeInterval(seconds)
    for _ in 0..<threads {
        Thread {
            var x = 1.0
            while Date() < deadline {
                for _ in 0..<200_000 { x = x * 1.0000001 + 0.0000001 }
            }
            if x < 0 { print(x) }
        }.start()
    }
}

/// `sistem-probe --sensors-check [loadSeconds]`: catalog build cost, per-read cost, every
/// sensor with its value, what validation dropped, then a CPU load phase.
func sensorsCheck(loadSeconds: Double) {
    guard let smc = SMC() else { print("SMC: yok"); return }
    let model = HardwareInfo.current().modelIdentifier
    print("Model: \(model)  SMC anahtar sayısı: \(smc.keyCount)")

    // Catalog build: wall and CPU.
    var reader: SensorReader?
    let w0 = wallSeconds(), c0 = cpuSeconds()
    reader = SensorReader(smc: smc, model: model)
    let catalog = reader!.catalog
    let buildWall = (wallSeconds() - w0) * 1000, buildCPU = (cpuSeconds() - c0) * 1000
    print(String(format: "Katalog: %d sensör, %d fan; kurulum %.1f ms duvar / %.1f ms CPU (bir kez)",
                 catalog.sensors.count, catalog.fans.count, buildWall, buildCPU))
    guard let reader else { return }

    // Prefix search vs full walk.
    let walk0 = wallSeconds()
    let all = smc.allKeys()
    let walkMs = (wallSeconds() - walk0) * 1000
    let viaSearch = smc.keys(withPrefix: "T")
    let viaWalk = all.filter { $0.hasPrefix("T") }
    print(String(format: "Tam tarama (%d anahtar): %.0f ms · önek araması 'T': %d anahtar, tam taramayla %@",
                 all.count, walkMs, viaSearch.count, viaSearch == viaWalk ? "AYNI" : "FARKLI"))

    // Read costs.
    let full = cost(200) { _ = reader.sample() }
    let head = cost(200) { _ = reader.sampleTemperature() }
    print(String(format: "Tam okuma (%d anahtar): %.0f µs duvar / %.0f µs CPU → anahtar başına %.1f µs CPU",
                 reader.fullReadCount, full.wall, full.cpu, full.cpu / Double(reader.fullReadCount)))
    print(String(format: "Hafif okuma (%d anahtar, CPU çekirdekleri): %.0f µs duvar / %.0f µs CPU", reader.headlineReadCount, head.wall, head.cpu))
    if let tpdx = smc.key("TPDX") {
        let one = cost(2000) { _ = smc.readNumber(tpdx) }
        print(String(format: "Tek anahtar (TPDX): %.1f µs duvar / %.1f µs CPU", one.wall, one.cpu))
    }

    // Values.
    let sample = reader.sample()
    print("\n== Geçerli sensörler ==")
    for kind in SensorKind.allCases where kind != .fan {
        for group in SensorGroup.allCases {
            let rows = sample.readings(of: kind, group: kind == .temperature ? group : nil)
            guard !rows.isEmpty, kind == .temperature || group == .cpuSuper else { continue }
            let title = kind == .temperature ? "\(kind.rawValue)/\(group.rawValue)" : kind.rawValue
            let values = rows.map(\.value)
            print(String(format: "-- %@ (%d)  min %.2f · maks %.2f", title, rows.count, values.min() ?? 0, values.max() ?? 0))
            let shown = kind == .temperature && rows.count > 12 ? Array(rows.prefix(4)) + Array(rows.suffix(2)) : rows
            for row in shown {
                print(String(format: "   %@  %-28@ %10.3f %@", row.info.key, label(row.info) as NSString, row.value, unit(kind)))
            }
            if shown.count < rows.count { print("   … \(rows.count - shown.count) sensör daha") }
        }
    }
    for fan in sample.fans {
        print(String(format: "-- fan %d: %.0f rpm (min %.0f, maks %.0f)", fan.info.index, fan.rpm ?? -1, fan.info.minRPM, fan.info.maxRPM))
    }
    let t = sample.temperature
    func f(_ v: Float?) -> String { v.map { String(format: "%.1f", $0) } ?? "—" }
    print("Türetilmiş: CPU en sıcak \(f(t.cpuHottest)) · CPU ort. \(f(t.cpuAverage)) · GPU en sıcak \(f(t.gpuHottest)) · tümü en sıcak \(f(t.hottest))")

    // What validation dropped.
    print("\n== Elenenler (T anahtarları) ==")
    let listed = Set(catalog.sensors.map(\.key))
    var droppedZero = 0, droppedRange: [String] = [], nonFloat: [String] = []
    for name in viaWalk where !listed.contains(name) {
        guard let key = smc.key(name) else { continue }
        if key.type != "flt " { nonFloat.append("\(name)(\(key.type.trimmingCharacters(in: .whitespaces)))"); continue }
        if let v = smc.readNumber(key) {
            if v == 0 { droppedZero += 1 } else { droppedRange.append("\(name)=\(v)") }
        }
    }
    print("float olmayan: \(nonFloat.count) \(nonFloat.joined(separator: " "))")
    print("tam sıfır: \(droppedZero)")
    print("aralık dışı/sonlu değil: \(droppedRange.count) \(droppedRange.joined(separator: " "))")
    let bad = sample.catalog.sensors.indices.filter { i in
        guard let v = sample.values[i] else { return true }
        return !SensorValidity.isValid(Double(v), kind: sample.catalog.sensors[i].kind)
    }
    print("Listedeki çöp değer sayısı: \(bad.count)  (listedeki min sıcaklık: \(f(sample.readings(of: .temperature).map(\.value).min())) °C, maks: \(f(sample.readings(of: .temperature).map(\.value).max())) °C)")

    // Constant sensors over 6 s.
    print("\n== Değişkenlik (6 sn, 1 sn aralık) ==")
    var seen: [[Float?]] = []
    for _ in 0..<6 { seen.append(reader.sample().values); Thread.sleep(forTimeInterval: 1) }
    var constant: [String] = []
    for (i, info) in catalog.sensors.enumerated() where info.kind == .temperature {
        let column = seen.compactMap { $0[i] }
        if column.count > 1, Set(column).count == 1 { constant.append("\(info.key)=\(column[0])") }
    }
    print("sabit kalan sıcaklık sensörü: \(constant.count) \(constant.joined(separator: " "))")

    // TPDX vs core max.
    let tpdx = smc.key("TPDX")
    func compare(_ phase: String) {
        let s = reader.sample()
        let px = tpdx.flatMap { smc.readNumber($0) }.map { String(format: "%.1f", $0) } ?? "—"
        let p = s.readings(of: .power).first { $0.info.key == "PPMC" }?.value
        let sys = s.readings(of: .power).first { $0.info.key == "PSTR" }?.value
        let rpm = s.fans.map { String(format: "%.0f", $0.rpm ?? -1) }.joined(separator: "/")
        print(String(format: "%-6@ CPU en sıcak %@  ort %@  GPU %@  TPDX %@  PPMC %@ W  PSTR %@ W  fan %@",
                     phase as NSString, f(s.temperature.cpuHottest) as NSString, f(s.temperature.cpuAverage) as NSString,
                     f(s.temperature.gpuHottest) as NSString, px as NSString, f(p) as NSString, f(sys) as NSString, rpm as NSString))
    }
    print("\n== CPU yükü (\(Int(loadSeconds)) sn, tüm çekirdekler) ==")
    for _ in 0..<3 { compare("boşta"); Thread.sleep(forTimeInterval: 2) }
    spin(seconds: loadSeconds, threads: ProcessInfo.processInfo.activeProcessorCount)
    var elapsed = 0.0
    while elapsed < loadSeconds { Thread.sleep(forTimeInterval: 2); elapsed += 2; compare("yük") }
    Thread.sleep(forTimeInterval: 1.5)
    for _ in 0..<3 { compare("sonra"); Thread.sleep(forTimeInterval: 2) }
}
