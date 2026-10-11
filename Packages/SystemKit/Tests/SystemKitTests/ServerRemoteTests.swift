import Foundation
import Testing
@testable import SystemKit

@Suite("Uzak çıktı ayrıştırma")
struct ServerReadingTests {
    func reading(_ text: String, _ kind: ServerKind) -> ServerReading? {
        if case .reading(let reading) = ServerReadingParser.parse(Data(text.utf8), expecting: kind) { reading } else { nil }
    }

    @Test func linuxReading() throws {
        let r = try #require(reading(Samples.linux, .linux))
        #expect(r.cores == 4)
        #expect(r.cpuCounters == CPUCounters(busy: 1530, total: 9630))  // total 9630, idle 8000+100
        #expect(r.memoryTotal == 8_000_000 * 1024 && r.memoryUsed == 6_000_000 * 1024)
        #expect(r.swapUsed == 100_000 * 1024)
        #expect(r.load == [0.5, 0.4, 0.3])
        #expect(r.uptime == 86_400.55)
        #expect(r.net == NetCounters(received: 1_000_000, sent: 500_000))
        #expect(r.diskTotal == 100_000_000 * 1024 && r.diskUsed == 40_000_000 * 1024)
    }

    @Test func macOSReading() throws {
        let r = try #require(reading(Samples.macOS, .macOS))
        #expect(r.memoryTotal == 17_179_869_184)
        #expect(r.memoryUsed == (200_000 + 150_000 + 50_000) * 16_384)
        #expect(abs((r.cpuFraction ?? 0) - 0.16) < 0.0001)
        #expect(r.uptime == 3600)
        #expect(r.cores == 12)
    }

    @Test func dockerReading() throws {
        let r = try #require(reading(Samples.docker, .docker))
        #expect(r.containers.count == 2)
        #expect(r.containers[0].name == "web" && r.containers[0].cpuPercent == 1.5)
        #expect(r.containers[0].memoryUsed == 52_534_067 || r.containers[0].memoryUsed == UInt64(50.1 * 1_048_576))
        #expect(r.containers[1].memoryLimit == UInt64(4_294_967_296))
    }

    @Test func noDockerOnRemote() {
        let text = "SISTEM1 docker\nNODOCKER\nEND\n"
        #expect(ServerReadingParser.parse(Data(text.utf8), expecting: .docker) == .toolMissing)
        let failed = "SISTEM1 docker\nDOCKERFAIL\nEND\n"
        #expect(ServerReadingParser.parse(Data(failed.utf8), expecting: .docker) == .invalid)
    }

    @Test func wrongOrTruncatedOutputIsInvalid() {
        #expect(reading(Samples.linux, .macOS) == nil, "başlık türle eşleşmeli")
        #expect(reading(String(Samples.linux.dropLast(3)), .linux) == nil, "END yok: kesilmiş")
        #expect(reading("", .linux) == nil)
        #expect(reading("Welcome to Ubuntu\nlast login...\nSISTEM1 linux\nEND", .linux) == nil, "başlık ilk satır olmalı")
        #expect(reading("SISTEM1 linux\nEND", .linux) == nil, "kullanılabilir veri yok")
    }

    @Test func outOfRangeValuesAreDropped() throws {
        let text = """
        SISTEM1 linux
        cpu -5 10 20 30
        cores 99999
        mem 100 200 0 0
        load 1e999 2 3
        up -4
        net 18446744073709551615 5
        disk 100 200
        END
        """
        #expect(reading(text, .linux) == nil, "hiçbir değer aralıkta değil")
        let mixed = text.replacingOccurrences(of: "up -4", with: "up 100")
        let r = try #require(reading(mixed, .linux))
        #expect(r.uptime == 100 && r.cpuCounters == nil && r.memoryTotal == nil && r.load == nil && r.net == nil && r.diskTotal == nil && r.cores == nil)
    }

    @Test func repeatedKeysKeepTheFirstLine() throws {
        let r = try #require(reading("SISTEM1 linux\nup 100\nup 999\nEND", .linux))
        #expect(r.uptime == 100)
    }

    @Test func oversizedInputIsRefused() {
        let big = Data(repeating: UInt8(ascii: "x"), count: ServerReadingParser.sizeLimit + 1)
        #expect(ServerReadingParser.parse(big, expecting: .linux) == .invalid)
        let longLine = "SISTEM1 linux\nup 5\nnoise " + String(repeating: "z", count: 5000) + "\nEND"
        #expect(reading(longLine, .linux)?.uptime == 5, "uzun satır atlanır, geri kalan okunur")
    }

    @Test func containerLimitAndHostileNames() throws {
        var text = "SISTEM1 docker\n"
        for i in 0..<250 { text += "ctr c\(i)|1.0%|1MiB / 2MiB\n" }
        text += "ctr ../../etc|1.0%|1MiB / 2MiB\nctr -rf|1%|1B / 1B\nctr a b|1%|1B / 1B\nEND\n"
        let r = try #require(reading(text, .docker))
        #expect(r.containers.count == ServerReadingParser.containerLimit)
        #expect(!r.containers.contains { $0.name.contains("/") || $0.name.hasPrefix("-") })
        #expect(ServerReadingParser.byteCount("1.5GiB") == 1_610_612_736)
        #expect(ServerReadingParser.byteCount("12") == nil && ServerReadingParser.byteCount("-1MiB") == nil && ServerReadingParser.byteCount("nanMiB") == nil)
        #expect(ServerReadingParser.byteCount("99999999999TiB") == nil)
    }

    /// Random, mutated and truncated input must never crash, and anything accepted must be inside the ranges.
    @Test func fuzzedInputNeverCrashesAndStaysInRange() {
        var generator = SeededGenerator(seed: 42)
        let seeds = [Samples.linux, Samples.macOS, Samples.docker]
        let kinds: [ServerKind] = [.linux, .macOS, .docker]
        var accepted = 0
        for round in 0..<3_000 {
            let index = round % 3
            var bytes = Array(seeds[index].utf8)
            switch round % 5 {
            case 0: for _ in 0..<(1 + Int(generator.next() % 8)) { if !bytes.isEmpty { bytes[Int(generator.next() % UInt64(bytes.count))] = UInt8(truncatingIfNeeded: generator.next()) } }
            case 1: bytes = Array(bytes.prefix(Int(generator.next() % UInt64(bytes.count + 1))))
            case 2: bytes = (0..<Int(generator.next() % 400)).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
            case 3: bytes += Array("\nup 99999999999999999999999\ncpu \(generator.next()) \(generator.next()) 1 2\nEND".utf8)
            default: for _ in 0..<20 { if !bytes.isEmpty { bytes.insert(UInt8(truncatingIfNeeded: generator.next()), at: Int(generator.next() % UInt64(bytes.count))) } }
            }
            guard case .reading(let r) = ServerReadingParser.parse(Data(bytes), expecting: kinds[index]) else { continue }
            accepted += 1
            if let used = r.memoryUsed, let total = r.memoryTotal { #expect(used <= total || r.kind == .macOS) }
            if let diskUsed = r.diskUsed, let diskTotal = r.diskTotal { #expect(diskUsed <= diskTotal) }
            if let c = r.cpuCounters { #expect(c.busy <= c.total) }
            if let f = r.cpuFraction { #expect((0...1).contains(f)) }
            if let load = r.load { #expect(load.allSatisfy { $0.isFinite && $0 >= 0 }) }
            #expect(r.containers.count <= ServerReadingParser.containerLimit)
            let metrics = ServerMetrics.make(r, at: Date(), previous: nil)
            if let m = metrics.memoryFraction { #expect((0...1).contains(m)) }
        }
        #expect(accepted > 0, "sağlam girdiler de kabul edilmeli")
    }

    @Test func metricsFromCounterDifferences() throws {
        let first = try #require(reading(Samples.linux, .linux))
        var second = first
        second.cpuCounters = CPUCounters(busy: first.cpuCounters!.busy + 500, total: first.cpuCounters!.total + 1000)
        second.net = NetCounters(received: first.net!.received + 4000, sent: first.net!.sent + 1000)
        let t0 = Date(timeIntervalSinceReferenceDate: 100)
        let metrics = ServerMetrics.make(second, at: t0.addingTimeInterval(4), previous: (first, t0))
        #expect(metrics.cpu == 0.5)
        #expect(metrics.receiveRate == 1000 && metrics.sendRate == 250)
        #expect(ServerMetrics.make(first, at: t0, previous: nil).cpu == nil, "ilk okumada oran yok")
        // Counters that went backwards (reboot): no rate, no negative.
        var rebooted = first
        rebooted.net = NetCounters(received: 1, sent: 1)
        rebooted.cpuCounters = CPUCounters(busy: 1, total: 2)
        let after = ServerMetrics.make(rebooted, at: t0.addingTimeInterval(4), previous: (first, t0))
        #expect(after.receiveRate == nil && after.sendRate == nil && after.cpu == nil)
        // Time did not advance: no division by zero.
        #expect(ServerMetrics.make(second, at: t0, previous: (first, t0)).receiveRate == nil)
    }
}

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

@Suite("ssh hata sınıflandırma")
struct ClassifierTests {
    @Test(arguments: [
        ("ozan@srv: Permission denied (publickey).", RemoteFailure.authRejected),
        ("No ED25519 host key is known for srv and you have requested strict checking.\nHost key verification failed.", .hostKeyUnknown),
        ("@@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@@\nOffending ECDSA key in /x/known_hosts:3\nHost key verification failed.", .hostKeyChanged),
        ("ssh: Could not resolve hostname nope: nodename nor servname provided, or not known", .unresolved),
        ("ssh: connect to host 10.0.0.1 port 22: Connection refused", .refused),
        ("ssh: connect to host 10.0.0.1 port 22: Operation timed out", .timedOut),
        ("Connection timed out during banner exchange", .timedOut),
        ("ssh: connect to host 10.0.0.1 port 22: No route to host", .unreachable),
        ("bind [127.0.0.1]:8080: Address already in use\nCould not request local forwarding.", .forwardFailed),
        ("", .unreachable),
        ("kex_exchange_identification: read: Connection reset by peer", .unreachable),
    ])
    func classifies(text: String, expected: RemoteFailure) {
        #expect(SSHErrorClassifier.classify(Data(text.utf8)) == expected)
    }

    @Test func connectivityAndPermanentSets() {
        #expect(RemoteFailure.timedOut.isConnectivity && RemoteFailure.refused.isConnectivity && !RemoteFailure.authRejected.isConnectivity)
        #expect(RemoteFailure.hostKeyUnknown.isPermanent && !RemoteFailure.unreachable.isPermanent && !RemoteFailure.timedOut.isPermanent)
    }
}

@Suite("RemoteActor")
struct RemoteActorTests {
    func actor(_ runner: FakeProcessRunner, clock: ManualServerClock = ManualServerClock(), control: String? = nil) -> RemoteActor {
        RemoteActor(runner: runner, clock: clock, environment: SSHEnvironment(controlDirectory: control), dockerCandidates: ["/nonexistent/docker"])
    }

    @Test func successfulProbeSendsTheFixedScriptOnStdin() async throws {
        let runner = FakeProcessRunner()
        runner.respond { _ in .result(Samples.ok(Samples.linux)) }
        let result = await actor(runner).probe(Samples.server())
        guard case .reading(let reading) = result else { Issue.record("beklenen okuma, gelen \(result)"); return }
        #expect(reading.cores == 4)
        let request = try #require(runner.requests.first)
        #expect(request.executable == "/usr/bin/ssh")
        #expect(request.input == Data(ServerScripts.linux.utf8))
        #expect(request.timeout <= 10)
        #expect(request.environment["SSH_ASKPASS"] == nil)
        #expect(request.arguments.contains("BatchMode=yes"))
    }

    @Test func sshFailuresBecomeStates() async {
        let cases: [(ProcessResult, RemoteFailure)] = [
            (Samples.sshError("Permission denied (publickey)."), .authRejected),
            (Samples.sshError("Host key verification failed."), .hostKeyUnknown),
            (Samples.sshError("Connection refused"), .refused),
            (ProcessResult(outcome: .exited(1)), .commandFailed),
            (ProcessResult(outcome: .timedOut), .timedOut),
            (ProcessResult(outcome: .launchFailed), .launchFailed),
            (ProcessResult(outcome: .outputTooLarge), .badOutput),
            (Samples.ok("<html>captive portal</html>"), .badOutput),
            (Samples.ok(""), .badOutput),
        ]
        for (result, expected) in cases {
            let runner = FakeProcessRunner()
            runner.respond { _ in .result(result) }
            #expect(await actor(runner).probe(Samples.server()) == .failure(expected), "\(expected)")
        }
    }

    /// Kapı 1: an ssh that never answers ends as a clean "timed out" at the 10 s mark on the injected clock,
    /// the process is cancelled (the live runner kills it), and nothing waited on a real second.
    @Test func hangingConnectionTimesOutAtTenSecondsAndIsCancelled() async {
        let runner = FakeProcessRunner()
        runner.respond { _ in .hang }
        let clock = ManualServerClock()
        let remote = actor(runner, clock: clock)
        let call = Task { await remote.probe(Samples.server()) }
        #expect(await eventually { runner.requests.count == 1 && clock.sleeperCount == 1 })
        clock.advance(by: 9.9)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(runner.cancelledCount == 0, "10 sn dolmadan vazgeçilmez")
        clock.advance(by: 0.2)
        #expect(await call.value == .failure(.timedOut))
        #expect(await eventually { runner.cancelledCount == 1 })
        #expect(RemoteActor.deadline <= 10 && SSHCommand.connectTimeout <= 10)
    }

    @Test func reachabilityCheck() async {
        let runner = FakeProcessRunner()
        runner.respond { _ in .result(ProcessResult(outcome: .exited(0))) }
        #expect(await actor(runner).reachability(Samples.server()) == nil)
        runner.respond { _ in .result(Samples.sshError("Connection timed out")) }
        #expect(await actor(runner).reachability(Samples.server()) == .timedOut)
        #expect(runner.requests.last?.arguments.last == "true")
    }

    @Test func localDockerWithoutDockerIsAStateNotACrash() async {
        let runner = FakeProcessRunner()
        let result = await actor(runner).probe(ServerConfig(name: "D", kind: .localDocker))
        #expect(result == .failure(.toolMissing))
        #expect(runner.requests.isEmpty)
    }

    @Test func controlDirectoryIsCreatedPrivateOnFirstUseOnly() async throws {
        let directory = NSTemporaryDirectory() + "sistem-ctl-\(UUID().uuidString.prefix(6))"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let runner = FakeProcessRunner()
        runner.respond { _ in .result(Samples.ok(Samples.linux)) }
        let remote = actor(runner, control: directory)
        #expect(!FileManager.default.fileExists(atPath: directory), "başlatmada dizin oluşmaz")
        _ = await remote.probe(Samples.server())
        let attributes = try FileManager.default.attributesOfItem(atPath: directory)
        #expect((attributes[.posixPermissions] as? Int ?? 0) & 0o077 == 0)
        #expect(runner.requests.first?.arguments.contains { $0.hasPrefix("ControlPath=") } == true)
    }

    @Test func looseControlDirectoryIsTightenedAndALinkIsRefused() throws {
        let base = NSTemporaryDirectory() + "sistem-ctl2-\(UUID().uuidString.prefix(6))"
        defer { try? FileManager.default.removeItem(atPath: base) }
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        #expect(RemoteActor.prepareDirectory(base))
        #expect((try FileManager.default.attributesOfItem(atPath: base)[.posixPermissions] as? Int ?? 0) & 0o077 == 0)
        let link = base + "-link"
        defer { try? FileManager.default.removeItem(atPath: link) }
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: base)
        #expect(!RemoteActor.prepareDirectory(link), "sembolik bağ kabul edilmez")
    }

    @Test func shutdownClosesMastersAndRemovesSockets() async throws {
        let directory = NSTemporaryDirectory() + "sistem-ctl3-\(UUID().uuidString.prefix(6))"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let runner = FakeProcessRunner()
        runner.respond { _ in .result(Samples.ok(Samples.linux)) }
        let remote = actor(runner, control: directory)
        let server = Samples.server()
        _ = await remote.probe(server)
        let path = try #require(SSHCommand.controlPath(for: server, in: SSHEnvironment(controlDirectory: directory)))
        FileManager.default.createFile(atPath: path, contents: Data())
        await remote.shutdown(servers: [server])
        #expect(runner.requests.last?.arguments.contains("exit") == true)
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
