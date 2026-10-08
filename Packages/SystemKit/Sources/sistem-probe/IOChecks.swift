import Foundation
import SystemKit

/// Fixed-argv helper for the comparison tools (`iostat`, `netstat`); no shell.
func run(_ tool: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// Cumulative megabytes (read + write) `iostat -Id <disk>` reports since boot.
func iostatMegabytes(_ disk: String) -> Double? {
    let lines = run("/usr/sbin/iostat", ["-Id", disk]).split(separator: "\n")
    guard let last = lines.last, let value = last.split(separator: " ").last else { return nil }
    return Double(value)
}

/// Samples DiskReader every 0.5 s on its own thread and integrates rate × elapsed.
final class DiskProbeState: @unchecked Sendable {
    private let reader: DiskReader
    private let lock = NSLock()
    private var written = 0.0, bytesRead = 0.0, peakWrite = 0.0, peakRead = 0.0
    private var stop = false

    init(_ reader: DiskReader) { self.reader = reader }

    func run() {
        while true {
            Thread.sleep(forTimeInterval: 0.5)
            let sample = reader.sample()
            let dt = sample.interval
            lock.lock()
            written += sample.writeRate * dt
            bytesRead += sample.readRate * dt
            peakWrite = max(peakWrite, sample.writeRate)
            peakRead = max(peakRead, sample.readRate)
            let done = stop
            lock.unlock()
            if done { return }
        }
    }

    func finish() { lock.lock(); stop = true; lock.unlock() }

    func totals() -> (written: Double, read: Double, peakWrite: Double, peakRead: Double) {
        lock.lock(); defer { lock.unlock() }
        return (written, bytesRead, peakWrite, peakRead)
    }
}

/// `sistem-probe --disk-check [megabytes]`: writes a temp file, reads it back with
/// caching off, and compares what DiskReader saw with `iostat` over the same window.
func diskCheck(megabytes: Int) {
    let queue = DispatchQueue(label: "probe.disk")
    let reader = DiskReader(queue: queue)
    print("fiziksel diskler: \(reader.deviceCount)")
    let first = reader.sample()
    for device in first.devices { print("  \(device.name) (\(device.bsdName ?? "?")) \(device.isInternal ? "dahili" : "harici")") }
    for volume in first.volumes ?? [] {
        print(String(format: "  birim %@ (%@) %@: %.1f GB toplam, %.1f GB boş", volume.name, volume.mountPoint, "\(volume.kind)",
                     Double(volume.total) / 1e9, Double(volume.available) / 1e9))
    }
    let disk = first.devices.first?.bsdName ?? "disk0"
    guard let before = iostatMegabytes(disk) else { print("iostat okunamadı"); return }
    // Prime and start the integration clock together: the first rate covers prime → first sample.
    reader.prime()
    let state = DiskProbeState(reader)

    let directory = FileManager.default.temporaryDirectory.appending(path: "sistem-probe-\(getpid())")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appending(path: "yuk.bin")
    defer { try? FileManager.default.removeItem(at: directory) }

    let sampler = Thread { state.run() }
    sampler.start()

    // Write: random data, caching off so it really reaches the SSD.
    let chunk = [UInt8](repeating: 0xA5, count: 1 << 20)
    let fd = open(file.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    _ = fcntl(fd, F_NOCACHE, 1)
    for _ in 0..<megabytes { _ = chunk.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } }
    fsync(fd)
    close(fd)
    // Read it back, caching off.
    var buffer = [UInt8](repeating: 0, count: 1 << 20)
    let rfd = open(file.path, O_RDONLY)
    _ = fcntl(rfd, F_NOCACHE, 1)
    while buffer.withUnsafeMutableBytes({ read(rfd, $0.baseAddress, $0.count) }) > 0 {}
    close(rfd)
    Thread.sleep(forTimeInterval: 1.2)
    state.finish()
    Thread.sleep(forTimeInterval: 0.8)

    guard let after = iostatMegabytes(disk) else { return }
    let totals = state.totals()
    let written = totals.written, bytesRead = totals.read
    let ourWrite = written / 1_048_576, ourRead = bytesRead / 1_048_576
    let peakW = totals.peakWrite / 1_048_576, peakR = totals.peakRead / 1_048_576
    let iostat = after - before
    print(String(format: "bilinen yük: %d MB yazma + %d MB okuma", megabytes, megabytes))
    print(String(format: "bizim ölçüm : yazma %.1f MB, okuma %.1f MB, toplam %.1f MB (tepe %.0f / %.0f MB/s)", ourWrite, ourRead, ourWrite + ourRead, peakW, peakR))
    print(String(format: "iostat %@   : toplam %.1f MB (aynı pencere; iostat MB = 2^20 bayt)", disk, iostat))
    let ours = ourWrite + ourRead
    print(String(format: "bizim toplam: %.1f MB   iostat: %.1f MB   fark: %.1f%% (%.1f MB)", ours, iostat, iostat > 0 ? (ours - iostat) / iostat * 100 : 0, ours - iostat))
}

/// `sistem-probe --net-check [seconds]`: our interface totals against `netstat -ib`
/// deltas over the same window (no traffic is generated; whatever the Mac does anyway).
func netCheck(seconds: Int) {
    let reader = NetworkReader()
    _ = reader.sample()
    let before = netstat()
    var total: NetworkSample?
    for _ in 0..<seconds {
        Thread.sleep(forTimeInterval: 1)
        total = reader.sample()
    }
    let after = netstat()
    guard let total else { return }
    print("arayüz     bizim ↓ (bayt)  netstat ↓      bizim ↑        netstat ↑")
    var sumNetstat = (down: UInt64(0), up: UInt64(0))
    for interface in total.interfaces.sorted(by: { $0.name < $1.name }) {
        let b = before[interface.name] ?? (0, 0), a = after[interface.name] ?? (0, 0)
        let down = a.down &- b.down, up = a.up &- b.up
        sumNetstat.down += down
        sumNetstat.up += up
        print(String(format: "%-8@ %14llu %14llu %14llu %14llu", interface.name as NSString, interface.totalDown, down, interface.totalUp, up))
    }
    print("toplam    \(total.totalDown) \(sumNetstat.down) \(total.totalUp) \(sumNetstat.up)")
}

/// Ibytes/Obytes of every `<Link#n>` row of `netstat -ib` (64-bit, from sysctl).
func netstat() -> [String: (down: UInt64, up: UInt64)] {
    var result: [String: (down: UInt64, up: UInt64)] = [:]
    for line in run("/usr/sbin/netstat", ["-ib"]).split(separator: "\n") where line.contains("<Link#") {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // Name Mtu Network [Address] Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll; the address column is optional.
        guard fields.count >= 10, let obytes = UInt64(fields[fields.count - 2]), let ibytes = UInt64(fields[fields.count - 5])
        else { continue }
        result[fields[0].trimmingCharacters(in: CharacterSet(charactersIn: "*"))] = (ibytes, obytes)
    }
    return result
}

/// `sistem-probe --smart-check`: NVMe SMART through IONVMeSMARTUserClient, no root.
func smartCheck() {
    guard let reader = NVMeHealthReader() else { print("SMART: NVMe SMART destekli servis bulunamadı veya açılamadı"); return }
    let clock = ContinuousClock()
    var health: DiskHealth?
    let took = clock.measure { for _ in 0..<100 { health = reader.read() } }
    guard let health else { print("SMART: okuma başarısız"); return }
    print("SMART: OKUNDU (100 okuma ortalama \(took / 100))")
    print(String(format: "  sıcaklık %.0f °C · harcanan %d%% · yedek alan %d%% (eşik %d%%) · kritik uyarı 0x%02x", health.temperatureCelsius ?? -1,
                 health.percentageUsed, health.availableSpare, health.availableSpareThreshold, health.criticalWarning))
    print(String(format: "  yazılan %.2f TB · okunan %.2f TB · açık %llu saat · %llu güç döngüsü · %llu güvensiz kapanış · %llu ortam hatası",
                 Double(health.bytesWritten) / 1e12, Double(health.bytesRead) / 1e12, health.powerOnHours, health.powerCycles,
                 health.unsafeShutdowns, health.mediaErrors))
}

/// `sistem-probe --io-bench`: what one read of each Faz 5 reader costs.
func ioBench() {
    let clock = ContinuousClock()
    func micros(_ duration: Duration) -> Double {
        let parts = duration.components
        return (Double(parts.seconds) * 1e6) + Double(parts.attoseconds) / 1e12
    }
    func report(_ name: String, _ count: Int, _ body: () -> Void) {
        body()  // warm up
        let total = clock.measure { for _ in 0..<count { body() } }
        print(String(format: "%-34@ %10.1f µs/okuma  (%d okuma)", name as NSString, micros(total) / Double(count), count))
    }
    let disk = DiskReader(volumeInterval: .max)
    _ = disk.sample()
    report("DiskReader.sample (kapasitesiz)", 5000) { _ = disk.sample() }
    // Force capacity refreshes: a new reader's first sample lists and measures everything.
    report("DiskReader ilk örnek (liste+kapasite)", 40) { _ = DiskReader().sample() }
    let network = NetworkReader()
    _ = network.sample()
    report("NetworkReader.sample", 5000) { _ = network.sample() }
    report("NetworkReader.localAddresses", 2000) { _ = NetworkReader.localAddresses() }
    let wifi = WiFiReader()
    report("WiFiReader.sample", 500) { _ = wifi.sample() }
    if let health = NVMeHealthReader() { report("NVMeHealthReader.read", 2000) { _ = health.read() } }
}
