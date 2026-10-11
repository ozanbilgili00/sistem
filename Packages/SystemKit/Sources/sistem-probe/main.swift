// sistem-probe — dumps everything this Mac exposes for monitoring, so sensor names,
// SMC keys and IOReport channels are catalogued from real output, not guessed.
//
//   sistem-probe <out.json> [--load]
//
// --load runs ~80 s of CPU and GPU load to see which temperature sensors follow
// which cores. The Mac gets warm and the fans may spin up briefly.

import Foundation
import Metal
import Vision
import SystemKit

// MARK: Report model

struct Report: Codable {
    var generatedAt: String
    var macOS: String
    var hardware: Hardware
    var timings: [String: Double] = [:]
    var hid: [HIDEntry] = []
    var smc = SMCSection()
    var ioreport = IOReportSection()
    var registryHits: [String] = []
    var load: LoadSection?
    var findings = Findings()
}

struct Hardware: Codable {
    var model: String, chip: String, memoryGB: Double
    var clusters: [String: Int]
}

struct HIDEntry: Codable {
    var kind: String, index: Int, name: String, value: Double?, plausible: Bool
}

struct SMCSection: Codable {
    var available = false
    var keyCount = 0
    var keys: [SMCEntry] = []
}

struct SMCEntry: Codable {
    var key: String, type: String, size: Int, writable: Bool, hex: String, value: Double?
}

struct IOReportSection: Codable {
    var available = false
    var channelCount = 0
    var groups: [GroupEntry] = []
    var energySample: [EnergyEntry] = []
}

struct GroupEntry: Codable {
    var group: String, subgroup: String, channels: Int, formats: [String], units: [String], names: [String]
}

struct EnergyEntry: Codable {
    var channel: String, unit: String, perSecond: Double
}

struct LoadSection: Codable {
    var phases: [String]
    /// Sensor name → temperature at the end of each phase (baseline first).
    var temperatures: [String: [Double]]
    /// Phase → CPU Stats channels that were busy, sorted by activity.
    var busyCores: [String: [String]]
    /// Phase → Energy Model channels with the highest power, in watts.
    var power: [String: [String: Double]]
}

struct Findings: Codable {
    var aneGroups: [String] = []
    var aneEnergyChannels: [String] = []
    var fanKeys: [String] = []
    var fanWritableKeys: [String] = []
    var fpsCandidates: [String] = []
    var cpuEnergyChannels: [String] = []
    var gpuEnergyChannels: [String] = []
}

// MARK: Helpers

func time<T>(_ label: String, into report: inout Report, _ body: () -> T) -> T {
    let start = ContinuousClock.now
    let result = body()
    let elapsed = start.duration(to: .now)
    report.timings[label] = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    return result
}

func log(_ message: String) { FileHandle.standardError.write(Data("\(message)\n".utf8)) }

// MARK: Load helpers

nonisolated(unsafe) var sink = 0.0

@Sendable func cpuLoad(threads: Int, seconds: Double) {
    let deadline = Date().addingTimeInterval(seconds)
    let group = DispatchGroup()
    for _ in 0..<threads {
        group.enter()
        let thread = Thread {
            var x = 1.0
            while Date() < deadline {
                for _ in 0..<200_000 { x = x * 1.000_000_1 + 0.000_000_1 }
            }
            sink += x
            group.leave()
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }
    group.wait()
}

@Sendable func gpuLoad(seconds: Double) {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
    let source = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void burn(device float *data [[buffer(0)]], uint id [[thread_position_in_grid]]) {
        float x = data[id];
        for (int i = 0; i < 2048; i++) { x = fma(x, 1.000001f, 0.000001f); x = sin(x) * 0.5f + x * 0.5f; }
        data[id] = x;
    }
    """
    guard let library = try? device.makeLibrary(source: source, options: nil),
          let function = library.makeFunction(name: "burn"),
          let pipeline = try? device.makeComputePipelineState(function: function) else { return }
    let count = 1 << 22
    guard let buffer = device.makeBuffer(length: count * 4, options: .storageModePrivate) else { return }
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: pipeline.maxTotalThreadsPerThreadgroup, height: 1, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
    }
}

// MARK: Run

let args = CommandLine.arguments

// `sistem-probe --cpu <seconds> <count>`: CPULoadReader totals, one line per window,
// for side-by-side comparison with `top -l <count+1> -s <seconds> -n 0`.
if args.count == 4, args[1] == "--cpu", let seconds = UInt32(args[2]), let count = Int(args[3]) {
    var reader = CPULoadReader()
    _ = reader.sample()
    for _ in 0..<count {
        sleep(seconds)
        if let sample = reader.sample() {
            print(String(format: "%.1f %.1f %.1f", sample.user * 100, sample.system * 100, sample.total * 100))
        }
    }
    exit(0)
}

// `sistem-probe --processes`: cost of one ProcessLister / MemoryReader read.
// `sistem-probe --top <seconds>`: one ProcessLister window, top 8 by CPU, for
// comparison with `top -l 2 -s <seconds> -o cpu -stats pid,command,cpu`.
if args.count == 3, args[1] == "--top", let seconds = UInt32(args[2]) {
    var lister = ProcessLister()
    lister.psEvery = 1
    _ = lister.sample()
    sleep(seconds)
    for entry in lister.sample()?.topCPU.prefix(8) ?? [] {
        print(String(format: "%6d %6.1f%% %@ %@", entry.pid, entry.cpu * 100, entry.memoryIsApproximate ? "ps " : "lib", entry.name))
    }
    exit(0)
}

if args.count == 2, args[1] == "--processes" {
    var lister = ProcessLister()
    _ = lister.sample()
    let clock = ContinuousClock()
    for round in 0..<6 {
        usleep(500_000)
        var sample: ProcessSample?
        let took = clock.measure { sample = lister.sample() }
        print("tur \(round) \(round % 2 == 0 ? "ps  " : "    ") \(took)  süreç \(sample?.processCount ?? 0)  ilk: \(sample?.topCPU.first?.name ?? "-")")
    }
    let reader = MemoryReader()
    print("bellek okuma", clock.measure { for _ in 0..<1000 { _ = reader.sample() } } / 1000)
    exit(0)
}

// `sistem-probe --gpu-check [seconds]`: GPUReader, PowerReader and CPUFrequencyReader
// once a second through idle → Metal load → idle, to see the numbers move.
if args.count >= 2, args[1] == "--gpu-check" {
    let loadSeconds = args.count > 2 ? Double(args[2]) ?? 12 : 12
    guard let gpu = GPUReader() else { print("GPUReader: yok"); exit(1) }
    let power = PowerReader()
    let frequency = CPUFrequencyReader()
    print("IOReport: \(IOReport.library != nil ? "var" : "yok")  güç okuyucu: \(power.isAvailable ? "var" : "yok")  frekans okuyucu: \(frequency != nil ? "var" : "yok")")
    print("saniye evre   cihaz% render% tiler%  bellek(MB)  tahsis(MB)  GPU(W)  ANE(W)  CPU(W)  Sistem(W)  frekans")
    _ = power.sample()
    _ = frequency?.sample()
    let plan: [(String, Int)] = [("boşta", 4), ("yük", Int(loadSeconds)), ("boşta", 4)]
    var second = 0
    for (phase, length) in plan {
        if phase == "yük" { Thread { gpuLoad(seconds: loadSeconds) }.start() }
        for _ in 0..<length {
            Thread.sleep(forTimeInterval: 1)
            second += 1
            let g = gpu.sample()
            let p = power.sample()
            let f = frequency?.sample()
            func w(_ value: Float?) -> String { value.map { String(format: "%6.2f", $0) } ?? "     —" }
            let clusters = f?.clusters.map { c in
                "\(c.name) \(c.averageMHz.map { String(format: "%.0f MHz", $0) } ?? "—") %\(Int(c.activeFraction * 100))"
            }.joined(separator: " · ") ?? "—"
            print(String(format: "%5d  %-6@ %6.0f %7.0f %6.0f  %10.0f  %10.0f", second, phase as NSString,
                         (g?.device ?? 0) * 100, (g?.renderer ?? 0) * 100, (g?.tiler ?? 0) * 100,
                         Double(g?.memoryInUse ?? 0) / 1_048_576, Double(g?.memoryAllocated ?? 0) / 1_048_576)
                  + "  \(w(p.gpu))  \(w(p.ane))  \(w(p.cpu))  \(w(p.system))   \(clusters)")
        }
    }
    exit(0)
}

// `sistem-probe --disk-check [MB]`, `--net-check [seconds]`, `--smart-check`: Faz 5 gate checks (IOChecks.swift).
if args.count >= 2, args[1] == "--disk-check" { diskCheck(megabytes: args.count > 2 ? Int(args[2]) ?? 512 : 512); exit(0) }
if args.count >= 2, args[1] == "--net-check" { netCheck(seconds: args.count > 2 ? Int(args[2]) ?? 10 : 10); exit(0) }
if args.count >= 3, args[1] == "--awake-check" {
    MainActor.assumeIsolated { awakeCheck(name: args[2], seconds: args.count > 3 ? Double(args[3]) ?? 20 : 20) }
    exit(0)
}
// `sistem-probe --display-check`: Phase 10 read-only look at displays and DDC (DisplayChecks.swift).
if args.count == 2, args[1] == "--display-check" { MainActor.assumeIsolated { displayCheck() }; exit(0) }
if args.count == 2, args[1] == "--io-bench" { ioBench(); exit(0) }
if args.count == 2, args[1] == "--smart-check" { smartCheck(); exit(0) }
// `sistem-probe --sensors-check [loadSeconds]`: Faz 6 gate check (SensorChecks.swift).
if args.count >= 2, args[1] == "--sensors-check" { sensorsCheck(loadSeconds: args.count > 2 ? Double(args[2]) ?? 20 : 20); exit(0) }

// `sistem-probe --battery-check [samples] [seconds between]`: Phase 7 gate check (BatteryChecks.swift).
if args.count >= 2, args[1] == "--battery-check" {
    batteryCheck(samples: args.count > 2 ? Int(args[2]) ?? 5 : 5, gap: args.count > 3 ? Double(args[3]) ?? 2 : 2)
    exit(0)
}

if args.count >= 2, args[1] == "--battery-watch" { batteryWatch(seconds: args.count > 2 ? Double(args[2]) ?? 60 : 60); exit(0) }

// `sistem-probe --freq-check`: cluster frequency while one Super-class thread, then all cores, run.
if args.count >= 2, args[1] == "--freq-check" {
    guard let frequency = CPUFrequencyReader() else { print("CPUFrequencyReader: yok"); exit(1) }
    for (name, ladder) in CPUFrequencyReader.discoveredLadders().sorted(by: { $0.key < $1.key }) {
        print("\(name): \(ladder.count) durum, \(ladder.first.map { String(format: "%.0f", $0) } ?? "—")–\(ladder.last.map { String(format: "%.0f", $0) } ?? "—") MHz")
    }
    let cores = HardwareInfo.current().totalCores
    let plan: [(String, Int, @Sendable () -> Void)] = [
        ("boşta", 4, {}),
        ("1 iş parçacığı", 6, { cpuLoad(threads: 1, seconds: 6) }),
        ("\(cores) iş parçacığı", 6, { cpuLoad(threads: cores, seconds: 6) }),
    ]
    _ = frequency.sample()
    for (phase, length, load) in plan {
        Thread { load() }.start()
        for _ in 0..<length {
            Thread.sleep(forTimeInterval: 1)
            let line = frequency.sample()?.clusters.map { c in
                "\(c.name): \(c.averageMHz.map { String(format: "%.0f MHz", $0) } ?? "—") (düzey \(c.performanceLevel.map { String(format: "%.2f", $0) } ?? "—"), aktif %\(Int(c.activeFraction * 100)), tavan \(c.maxMHz.map { String(format: "%.0f", $0) } ?? "—"))"
            }.joined(separator: " | ") ?? "—"
            print("\(phase): \(line)")
        }
    }
    exit(0)
}

// `sistem-probe --freq-verify <seconds>`: the busiest core's average clock per second, from
// raw IOReport residencies and the device-tree ladder, to compare with an independent
// cycle count (a dependent-add chain run alongside).
if args.count == 3, args[1] == "--freq-verify", let seconds = Int(args[2]), let io = IOReport.library,
   let sub = io.subscribe(to: [("CPU Stats", "CPU Core Performance States")]) {
    let ladders = CPUFrequencyReader.discoveredLadders()
    var before = sub.sample()
    for _ in 0..<seconds {
        Thread.sleep(forTimeInterval: 1)
        guard let after = sub.sample(), let earlier = before else { continue }
        before = after
        var best: (name: String, mhz: Double, active: Double)?
        for r in sub.readings(from: earlier, to: after) where !r.states.isEmpty {
            if ["PCPU0", "MCPU00"].contains(r.channel.name) { print("durumlar \(r.channel.name): \(r.states.map(\.name).joined(separator: " "))") }
            let indices = r.states.map { st -> Int? in
                guard st.name.hasPrefix("V"), let p = st.name.firstIndex(of: "P") else { return nil }
                return Int(st.name[st.name.index(after: st.name.startIndex)..<p])
            }
            let count = (indices.compactMap { $0 }.max() ?? -1) + 1
            guard let ladder = ladders.values.first(where: { $0.count == count }) else { continue }
            var total = 0.0, active = 0.0, mhz = 0.0
            for (st, index) in zip(r.states, indices) {
                total += Double(st.residency)
                if let index { active += Double(st.residency); mhz += Double(ladder[index]) * Double(st.residency) }
            }
            guard active > 0, active / total > (best?.active ?? 0) else { continue }
            best = (r.channel.name, mhz / active, active / total)
        }
        print(best.map { String(format: "IOReport: en meşgul çekirdek %@ aktif %%%.0f  ortalama %.0f MHz", $0.name, $0.active * 100, $0.mhz) } ?? "—")
    }
    exit(0)
}

// `sistem-probe --fps <seconds>`: the DCP counters that could stand in for a frame rate,
// summed per second per display controller, next to GPU load. Which of them follow what
// is drawn, and which just follow the panel's refresh?
if args.count == 3, args[1] == "--fps", let seconds = Int(args[2]), let io = IOReport.library {
    let groups = ["DCP", "DCPEXT0", "DCPEXT1", "DCPEXT2", "DCPEXT3"].flatMap { g in
        ["swap", "scanout", "display stats"].map { (group: g, subgroup: Optional($0)) }
    }
    guard let sub = io.subscribe(to: groups) else { print("abonelik yok"); exit(1) }
    let gpu = GPUReader()
    var before = sub.sample()
    print("saniye  gpu%  | DCP swap  scanout  frame_count | EXT0 swap  scanout  frame_count | EXT1 swap  scanout  frame_count")
    for second in 1...seconds {
        Thread.sleep(forTimeInterval: 1)
        guard let after = sub.sample(), let earlier = before else { continue }
        before = after
        var sums: [String: Double] = [:]
        for r in sub.readings(from: earlier, to: after) {
            let value = Double(r.value ?? 0)
            if r.channel.subgroup == "swap", r.channel.name.hasPrefix("subframes") { sums["\(r.channel.group)/swap", default: 0] += value }
            if r.channel.subgroup == "scanout", r.channel.name.hasPrefix("subframes") { sums["\(r.channel.group)/scanout", default: 0] += value }
            if r.channel.subgroup == "display stats", r.channel.name == "frame_count" { sums["\(r.channel.group)/frame", default: 0] += value }
        }
        func triple(_ g: String) -> String {
            String(format: "%8.0f %8.0f %11.0f", sums["\(g)/swap"] ?? 0, sums["\(g)/scanout"] ?? 0, sums["\(g)/frame"] ?? 0)
        }
        print(String(format: "%5d  %4.0f  | ", second, (gpu?.sample()?.device ?? 0) * 100) + triple("DCP") + " | " + triple("DCPEXT0") + " | " + triple("DCPEXT1"))
    }
    exit(0)
}

// `sistem-probe --bench`: cost of one read of each Phase 4 reader.
if args.count == 2, args[1] == "--bench" {
    let clock = ContinuousClock()
    func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
    func micros(_ label: String, _ count: Int, _ body: () -> Void) {
        body()
        let cpuBefore = cpuSeconds()
        let took = clock.measure { for _ in 0..<count { body() } }
        let cpu = (cpuSeconds() - cpuBefore) * 1e6 / Double(count)
        print(String(format: "%@: %.1f µs duvar saati, %.1f µs CPU / okuma", label, Double(took.components.attoseconds) / 1e12 / Double(count) + Double(took.components.seconds) * 1e6 / Double(count), cpu))
    }
    if let gpu = GPUReader() { micros("GPUReader", 2000) { _ = gpu.sample() } }
    let power = PowerReader()
    micros("PowerReader", 500) { _ = power.sample() }
    if let frequency = CPUFrequencyReader() { micros("CPUFrequencyReader", 500) { _ = frequency.sample() } }
    if let io = IOReport.library {
        let energy = io.subscribe(to: [("Energy Model", nil)]) { $0.name == "GPU Energy" || $0.name.hasPrefix("ANE") }
        let whole = io.subscribe(to: [("Energy Model", nil)])
        let cores = io.subscribe(to: [("CPU Stats", "CPU Core Performance States")])
        if let energy { micros("  Energy(2 kanal) sample()", 500) { _ = energy.sample() } }
        if let whole { micros("  Energy(tüm grup) sample()", 200) { _ = whole.sample() } }
        if let cores { micros("  CPU states sample()", 500) { _ = cores.sample() } }
        let both = io.subscribe(to: [("Energy Model", nil), ("CPU Stats", "CPU Core Performance States")]) { $0.group == "CPU Stats" || $0.name == "GPU Energy" || $0.name.hasPrefix("ANE") }
        if let both { micros("  Energy+CPU states (tek abonelik) sample()", 500) { _ = both.sample() } }
        let gpuOnly = io.subscribe(to: [("GPU Stats", "GPU Performance States")])
        if let gpuOnly { micros("  GPU Performance States sample()", 500) { _ = gpuOnly.sample() } }
        let dcp = io.subscribe(to: [("DCP", "swap")])
        if let dcp { micros("  DCP swap sample()", 500) { _ = dcp.sample() } }
        if let energy, let a = energy.sample(), let b = energy.sample() { micros("  Energy readings()", 500) { _ = energy.readings(from: a, to: b) } }
        if let cores, let a = cores.sample(), let b = cores.sample() { micros("  CPU states readings()", 500) { _ = cores.readings(from: a, to: b) } }
    }
    if let smc = SMC() { micros("SMC PPMC", 2000) { _ = smc.read("PPMC") } }
    exit(0)
}

// `sistem-probe --series <seconds> <interval>`: CPU total and GPU device utilisation, one line per
// tick, to replay through the menu bar's smoothing offline.
if args.count == 4, args[1] == "--series", let seconds = Int(args[2]), let interval = Double(args[3]) {
    var cpu = CPULoadReader()
    let gpu = GPUReader()
    _ = cpu.sample()
    for _ in 0..<Int(Double(seconds) / interval) {
        Thread.sleep(forTimeInterval: interval)
        print(String(format: "%.4f %.4f", cpu.sample()?.total ?? 0, gpu?.sample()?.device ?? 0))
        fflush(stdout)
    }
    exit(0)
}

// `sistem-probe --ane-check`: does the ANE0 energy channel move under a Vision workload
// (image classification, which Core ML schedules on the Neural Engine)?
if args.count == 2, args[1] == "--ane-check" {
    let side = 1024
    var pixels = Data(count: side * side * 4)
    for i in 0..<pixels.count { pixels[i] = UInt8.random(in: 0...255) }
    guard let provider = CGDataProvider(data: pixels as CFData),
          let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { print("görüntü kurulamadı"); exit(1) }
    let power = PowerReader()
    _ = power.sample()
    let deadline = Date().addingTimeInterval(10)
    let worker = Thread {
        while Date() < deadline {
            let request = VNClassifyImageRequest()
            try? VNImageRequestHandler(cgImage: image).perform([request])
        }
    }
    print("saniye  ANE(W)  GPU(W)  CPU(W)")
    for second in 1...12 {
        if second == 3 { worker.start() }
        Thread.sleep(forTimeInterval: 1)
        let p = power.sample()
        print(String(format: "%5d  %6.2f  %6.2f  %6.2f", second, p.ane ?? -1, p.gpu ?? -1, p.cpu ?? -1))
        fflush(stdout)
    }
    exit(0)
}

guard args.count > 1 else { log("kullanım: sistem-probe <çıktı.json> [--load]"); exit(2) }
let outputURL = URL(filePath: args[1])
let runLoad = args.contains("--load")

let info = HardwareInfo.current()
let os = ProcessInfo.processInfo.operatingSystemVersion
var report = Report(
    generatedAt: ISO8601DateFormatter().string(from: .now),
    macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
    hardware: Hardware(model: info.modelIdentifier, chip: info.chip,
                       memoryGB: Double(info.memoryBytes) / 1_073_741_824,
                       clusters: Dictionary(uniqueKeysWithValues: info.clusters.map { ($0.name, $0.count) }))
)

// HID: temperatures, currents, voltages. Time creation and reads separately — the
// read cost decides how often Phase 6 can afford to poll.
log("▸ HID sensörleri…")
var temperatureClient: HIDSensorClient?
for kind in HIDSensorClient.Kind.allCases {
    guard let client = time("hid.\(kind.rawValue).create", into: &report, { HIDSensorClient(kind: kind) }) else { continue }
    let values = time("hid.\(kind.rawValue).read", into: &report) { client.read() }
    _ = time("hid.\(kind.rawValue).read2", into: &report) { client.read() }
    if kind == .temperature { temperatureClient = client }
    for (service, value) in zip(client.services, values) {
        let plausible = value.map { kind == .temperature ? HIDSensorClient.isPlausibleTemperature($0) : $0.isFinite } ?? false
        report.hid.append(HIDEntry(kind: kind.rawValue, index: service.index, name: service.name, value: value, plausible: plausible))
    }
}

// SMC: every key with its decoded value.
log("▸ SMC anahtarları…")
let smcHandle = SMC()
var smcTemperatureKeys: [String] = []
if let smc = smcHandle {
    report.smc.available = true
    let keys = time("smc.enumerate", into: &report) { smc.allKeys() }
    report.smc.keyCount = keys.count
    report.smc.keys = time("smc.readAll", into: &report) {
        keys.compactMap { key in
            smc.read(key).map {
                SMCEntry(key: $0.key, type: $0.type, size: $0.bytes.count, writable: $0.isWritable, hex: $0.hex,
                         value: $0.number.flatMap { $0.isFinite ? $0 : nil })
            }
        }
    }
    _ = time("smc.readOne", into: &report) { smc.read("PSTR") }
    smcTemperatureKeys = report.smc.keys.filter { $0.key.hasPrefix("T") && ($0.value.map { (5.0...130).contains($0) } ?? false) }.map(\.key)
    _ = time("smc.readTemperatures(\(smcTemperatureKeys.count))", into: &report) { smcTemperatureKeys.map { smc.read($0) } }
    let fanKeys = report.smc.keys.filter { $0.key.first == "F" }
    report.findings.fanKeys = fanKeys.map { "\($0.key) \($0.type) = \($0.value.map { String($0) } ?? $0.hex)" }
    report.findings.fanWritableKeys = fanKeys.filter(\.writable).map(\.key)
}

// IOReport: every group/subgroup, plus one second of Energy Model.
log("▸ IOReport kanalları…")
if let ioreport = IOReport.library {
    report.ioreport.available = true
    let channels = time("ioreport.allChannels", into: &report) { ioreport.allChannels() }
    report.ioreport.channelCount = channels.count
    let grouped = Dictionary(grouping: channels) { "\($0.group)\u{1F}\($0.subgroup)" }
    report.ioreport.groups = grouped.values.map { members in
        GroupEntry(
            group: members[0].group, subgroup: members[0].subgroup, channels: members.count,
            formats: Array(Set(members.map { "\($0.format)" })).sorted(),
            units: Array(Set(members.map(\.unit))).filter { !$0.isEmpty }.sorted(),
            names: Array(members.map(\.name).prefix(40))
        )
    }.sorted { ($0.group, $0.subgroup) < ($1.group, $1.subgroup) }

    report.findings.aneGroups = Array(Set(channels.filter {
        ($0.group + $0.subgroup + $0.name).localizedCaseInsensitiveContains("ANE")
    }.map { "\($0.group) / \($0.subgroup)" })).sorted()
    let energy = channels.filter { $0.group == "Energy Model" }.map(\.name)
    report.findings.aneEnergyChannels = energy.filter { $0.localizedCaseInsensitiveContains("ANE") }
    report.findings.cpuEnergyChannels = energy.filter { $0.localizedCaseInsensitiveContains("CPU") }
    report.findings.gpuEnergyChannels = energy.filter { $0.localizedCaseInsensitiveContains("GPU") }
    report.findings.fpsCandidates += channels.filter {
        $0.name.localizedCaseInsensitiveContains("fps") || $0.name.localizedCaseInsensitiveContains("frame")
    }.map { "IOReport: \($0.group) / \($0.subgroup) / \($0.name)" }

    if let subscription = ioreport.subscribe(to: [("Energy Model", nil)]),
       let a = subscription.sample() {
        Thread.sleep(forTimeInterval: 1)
        if let b = subscription.sample() {
            report.ioreport.energySample = subscription.readings(from: a, to: b)
                .compactMap { r in r.value.map { EnergyEntry(channel: r.channel.name, unit: r.channel.unit, perSecond: Double($0)) } }
                .filter { $0.perSecond > 0 }
                .sorted { $0.perSecond > $1.perSecond }
        }
    }
}

// IORegistry: anything that smells like frame rate.
log("▸ IORegistry FPS araması…")
let ioreg = Process()
ioreg.executableURL = URL(filePath: "/usr/sbin/ioreg")
ioreg.arguments = ["-l", "-w0"]
let pipe = Pipe()
ioreg.standardOutput = pipe
try? ioreg.run()
let registry = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
ioreg.waitUntilExit()
report.registryHits = registry.split(separator: "\n").filter {
    $0.range(of: #"fps|framerate|frame rate|FrameCount|frames"#, options: [.regularExpression, .caseInsensitive]) != nil
}.map { String($0.trimmingCharacters(in: .whitespaces).prefix(220)) }.prefix(60).map { $0 }
report.findings.fpsCandidates += report.registryHits.prefix(10).map { "IORegistry: \($0)" }

// MARK: Load test

if runLoad, let temps = temperatureClient {
    let superCount = info.clusters.first?.count ?? 4
    let allCount = info.totalCores
    let phases: [(String, () -> Void)] = [
        ("cpu\(superCount)", { cpuLoad(threads: superCount, seconds: 12) }),
        ("cpu\(allCount)", { cpuLoad(threads: allCount, seconds: 12) }),
        ("gpu", { gpuLoad(seconds: 12) }),
    ]
    var section = LoadSection(phases: ["baseline"] + phases.map(\.0), temperatures: [:], busyCores: [:], power: [:])

    func snapshot() -> [String: Double] {
        var out: [String: Double] = [:]
        if let smc = smcHandle {
            for key in smcTemperatureKeys {
                if let value = smc.read(key)?.number, HIDSensorClient.isPlausibleTemperature(value) { out["SMC \(key)"] = value }
            }
        }
        for (service, value) in zip(temps.services, temps.read()) {
            if let value, HIDSensorClient.isPlausibleTemperature(value) { out["\(service.name)#\(service.index)"] = value }
        }
        return out
    }
    func record(_ values: [String: Double]) {
        for (key, value) in values { section.temperatures[key, default: []].append((value * 10).rounded() / 10) }
    }

    log("▸ Yük testi: taban çizgisi…")
    Thread.sleep(forTimeInterval: 3)
    record(snapshot())
    let subscription = IOReport.library?.subscribe(to: [("CPU Stats", nil), ("Energy Model", nil)])

    for (index, (name, run)) in phases.enumerated() {
        if index > 0 { log("  soğuma 20 sn…"); Thread.sleep(forTimeInterval: 20) }
        log("▸ Yük: \(name) (12 sn)…")
        let before = subscription?.sample()
        run()
        record(snapshot())
        if let subscription, let before, let after = subscription.sample() {
            let readings = subscription.readings(from: before, to: after)
            // A core is busy when little of its residency sits in idle/off states.
            let busy: [(String, Double)] = readings.filter { $0.channel.format == .state && !$0.states.isEmpty }.compactMap { r in
                let total = r.states.reduce(0) { $0 + $1.residency }
                guard total > 0 else { return nil }
                let idle = r.states.filter { ["IDLE", "OFF", "DOWN"].contains($0.name.uppercased()) }.reduce(0) { $0 + $1.residency }
                return ("\(r.channel.subgroup)/\(r.channel.name)", 1 - Double(idle) / Double(total))
            }
            section.busyCores[name] = busy.filter { $0.1 > 0.5 }.sorted { $0.1 > $1.1 }.prefix(30)
                .map { "\($0.0) \(Int($0.1 * 100))%" }
            let energy = readings.filter { $0.channel.group == "Energy Model" && ($0.value ?? 0) > 0 }
            // Energy over the 12 s phase → average watts. Units differ per channel.
            func watts(_ r: IOReport.Reading) -> Double {
                let scale: Double = switch r.channel.unit { case "mJ": 1e-3; case "uJ": 1e-6; case "nJ": 1e-9; default: 0 }
                return Double(r.value ?? 0) * scale / 12
            }
            section.power[name] = Dictionary(uniqueKeysWithValues: energy.map { ($0.channel.name, watts($0)) }
                .sorted { $0.1 > $1.1 }.prefix(14).map { ($0.0, ($0.1 * 1000).rounded() / 1000) })
        }
    }
    report.load = section
}

// MARK: Power / FPS mode

/// `--power`: which SMC power keys and IOReport energy channels follow CPU and GPU
/// load, and how fast each display's DCP frame counter ticks.
struct PowerSection: Codable {
    var smcWatts: [String: [Double]] = [:]          // key → idle, cpu, gpu
    var energyChannels: [String: [Double]] = [:]    // channel [unit] → idle, cpu, gpu (raw per second)
    var displayFramesPerSecond: [String: Double] = [:]
    var cpuStateNames: [String] = []
    var gpuStateNames: [String] = []
}

if args.contains("--power"), let smc = smcHandle, let io = IOReport.library {
    var power = PowerSection()
    let powerKeys = report.smc.keys.filter { "PIV".contains($0.key.first!) && $0.type == "flt " }.map(\.key)
    let energy = io.subscribe(to: [("Energy Model", nil), ("CPU Stats", "CPU Core Performance States"), ("GPU Stats", "GPU Performance States")])

    func measure(_ label: String, seconds: Double, load: @escaping @Sendable () -> Void) {
        log("▸ Güç: \(label)…")
        let before = energy?.sample()
        var sums: [String: Double] = [:]
        let worker = Thread { load() }
        worker.start()
        let samples = 5
        for _ in 0..<samples {
            Thread.sleep(forTimeInterval: seconds / Double(samples))
            for key in powerKeys { sums[key, default: 0] += smc.read(key)?.number ?? 0 }
        }
        while worker.isExecuting { Thread.sleep(forTimeInterval: 0.1) }
        for key in powerKeys { power.smcWatts[key, default: []].append(((sums[key] ?? 0) / Double(samples) * 100).rounded() / 100) }
        if let energy, let before, let after = energy.sample() {
            for r in energy.readings(from: before, to: after) {
                if r.channel.group == "Energy Model" {
                    power.energyChannels["\(r.channel.name) [\(r.channel.unit)]", default: []].append(Double(r.value ?? 0) / seconds)
                }
                if power.cpuStateNames.isEmpty, r.channel.subgroup == "CPU Core Performance States" { power.cpuStateNames = r.states.map(\.name) }
                if power.gpuStateNames.isEmpty, r.channel.subgroup == "GPU Performance States" { power.gpuStateNames = r.states.map(\.name) }
            }
        }
    }
    let cores = info.totalCores
    measure("boşta", seconds: 6) { Thread.sleep(forTimeInterval: 6) }
    measure("CPU \(cores)", seconds: 8) { cpuLoad(threads: cores, seconds: 8) }
    log("  soğuma 15 sn…"); Thread.sleep(forTimeInterval: 15)
    measure("GPU", seconds: 8) { gpuLoad(seconds: 8) }

    // Keep only keys that respond to load.
    power.smcWatts = power.smcWatts.filter { (_, v) in v.count == 3 && (v.max()! - v.min()!) > 0.3 }
    power.energyChannels = power.energyChannels.filter { $0.value.contains { $0 != 0 } }

    if let display = io.subscribe(to: [("DCP", "display stats"), ("DCPEXT0", "display stats"), ("DCPEXT1", "display stats"),
                                       ("DCPEXT2", "display stats"), ("DCPEXT3", "display stats")]),
       let a = display.sample() {
        Thread.sleep(forTimeInterval: 2)
        if let b = display.sample() {
            for r in display.readings(from: a, to: b) where r.channel.name == "frame_count" {
                power.displayFramesPerSecond[r.channel.group] = Double(r.value ?? 0) / 2
            }
        }
    }
    let encoded = try JSONEncoder().encode(power)
    try encoded.write(to: outputURL.deletingLastPathComponent().appending(path: "power-\(info.modelIdentifier).json"))
}

// MARK: Write

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try encoder.encode(report).write(to: outputURL)
log("✓ \(outputURL.path)")
