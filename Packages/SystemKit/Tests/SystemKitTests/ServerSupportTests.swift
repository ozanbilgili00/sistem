import Foundation
import Network
import Testing
@testable import SystemKit

/// The live runner with harmless system programs (never ssh).
@Suite("Süreç çalıştırıcı")
struct SystemProcessRunnerTests {
    let registry = ProcessRegistry()
    var runner: SystemProcessRunner { SystemProcessRunner(registry: registry) }

    @Test func capturesOutputAndStatus() async {
        let result = await runner.run(ProcessRequest(executable: "/bin/echo", arguments: ["merhaba"], timeout: 5))
        #expect(result.outcome == .exited(0))
        #expect(String(decoding: result.output, as: UTF8.self) == "merhaba\n")
    }

    @Test func feedsStandardInputAndCapturesStderr() async {
        let cat = await runner.run(ProcessRequest(executable: "/bin/cat", arguments: [], input: Data("girdi".utf8), timeout: 5))
        #expect(String(decoding: cat.output, as: UTF8.self) == "girdi")
        let ls = await runner.run(ProcessRequest(executable: "/bin/ls", arguments: ["/yok/boyle/bir/yer"], timeout: 5))
        #expect(ls.exitStatus != 0 && !ls.errorOutput.isEmpty)
    }

    @Test func argumentsAreNotInterpretedByAShell() async {
        let result = await runner.run(ProcessRequest(executable: "/bin/echo", arguments: ["$(id)", ";", "`id`", "*", "a b"], timeout: 5))
        #expect(String(decoding: result.output, as: UTF8.self) == "$(id) ; `id` * a b\n")
    }

    @Test func timeoutKillsTheProcess() async {
        let started = ContinuousClock.now
        let result = await runner.run(ProcessRequest(executable: "/bin/sleep", arguments: ["30"], timeout: 0.4))
        #expect(result.outcome == .timedOut)
        #expect(started.duration(to: .now) < .seconds(5))
    }

    @Test func cancellationKillsTheProcess() async {
        let task = Task { await runner.run(ProcessRequest(executable: "/bin/sleep", arguments: ["30"], timeout: 60)) }
        #expect(await eventually { registry.count >= 1 })
        task.cancel()
        let result = await task.value
        #expect(result.outcome == .cancelled)
    }

    @Test func outputIsBounded() async {
        let result = await runner.run(ProcessRequest(executable: "/usr/bin/yes", arguments: [], timeout: 5, outputLimit: 4096))
        #expect(result.outcome == .outputTooLarge)
        #expect(result.output.count <= 4096)
    }

    @Test func refusesRelativeAndMissingPrograms() async {
        #expect(await runner.run(ProcessRequest(executable: "echo", arguments: [], timeout: 1)).outcome == .launchFailed)
        #expect(await runner.run(ProcessRequest(executable: "/nonexistent/prog", arguments: [], timeout: 1)).outcome == .launchFailed)
        #expect(runner.launch(ProcessRequest(executable: "../bin/echo", arguments: [], timeout: 1)) == nil)
    }

    @Test func longLivedProcessCanBeTerminatedAndLeavesTheRegistry() async {
        let before = registry.count
        let process = try? #require(runner.launch(ProcessRequest(executable: "/bin/sleep", arguments: ["60"], timeout: 120)))
        #expect(registry.count == before + 1)
        process?.terminate()
        let result = await process?.finished()
        #expect(result?.outcome != .exited(0))
        #expect(await eventually { registry.count == before })
    }

    /// A private registry: the shared one also holds the children of tests running at the same time.
    @Test func registryTerminatesWhatItHolds() async throws {
        let registry = ProcessRegistry()
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        registry.add(process.processIdentifier)
        registry.terminateAll(grace: 1)
        process.waitUntilExit()
        #expect(process.terminationReason == .uncaughtSignal)
    }
}

@Suite("withDeadline")
struct DeadlineTests {
    @Test func returnsTheWorkWhenItIsFast() async {
        let clock = ManualServerClock()
        #expect(await withDeadline(10, clock: clock, { 42 }) == 42)
    }

    @Test func abandonsWorkThatIgnoresCancellation() async {
        let clock = ManualServerClock()
        let task = Task {
            await withDeadline(10, clock: clock, { () async -> Int in
                // Does not look at cancellation at all.
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                return 1
            })
        }
        #expect(await eventually { clock.sleeperCount == 1 })
        clock.advance(by: 10)
        #expect(await task.value == nil)
    }

    @Test func cancelledCallerGetsNilAtOnce() async {
        let clock = ManualServerClock()
        let task = Task { await withDeadline(10, clock: clock, { () async -> Int in try? await Task.sleep(for: .seconds(60)); return 1 }) }
        #expect(await eventually { clock.sleeperCount == 1 })
        task.cancel()
        #expect(await task.value == nil)
    }
}

@Suite("Hızlı bağlan")
struct QuickConnectTests {
    @Test func scriptIsOneFixedLineWithQuotedValidatedWords() {
        #expect(QuickConnect.script(host: "prod-web") == "#!/bin/sh\nexec '/usr/bin/ssh' '--' 'prod-web'\n")
        #expect(QuickConnect.script(host: "10.0.0.5", user: "ozan", port: 2222) == "#!/bin/sh\nexec '/usr/bin/ssh' '-l' 'ozan' '-p' '2222' '--' '10.0.0.5'\n")
        #expect(QuickConnect.script(host: "2001:db8::1")?.hasSuffix("'--' '2001:db8::1'\n") == true)
    }

    @Test func hostileValuesProduceNoScript() {
        for host in ServerInputTests.hostile { #expect(QuickConnect.script(host: host) == nil, "\(host.debugDescription)") }
        for user in ["-oProxyCommand=x", "a b", "a;b", "$(id)", "a'b", ""] { #expect(QuickConnect.script(host: "srv", user: user) == nil, "\(user.debugDescription)") }
        for port in [0, 65_536, -1] { #expect(QuickConnect.script(host: "srv", port: port) == nil) }
        // Whatever the input, the finished text never has a quote that is not ours and never a second line of commands.
        for host in ["srv", "a-b.c", "x_y"] {
            let text = QuickConnect.script(host: host)!
            #expect(text.split(separator: "\n").count == 2)
            #expect(text.filter { $0 == "'" }.count == 6)
        }
    }

    @Test func fileIsWrittenPrivateAndRemovable() throws {
        let directory = NSTemporaryDirectory() + "sistem-qc-\(UUID().uuidString.prefix(6))"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = try #require(QuickConnect.writeCommandFile(host: "prod-web", user: "ozan", in: directory))
        #expect(path.hasPrefix(directory + "/") && path.hasSuffix(".command") && !path.dropFirst(directory.count + 1).contains("/"))
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect(attributes[.posixPermissions] as? Int == 0o700)
        #expect((try FileManager.default.attributesOfItem(atPath: directory)[.posixPermissions] as? Int ?? 0) & 0o077 == 0)
        #expect(QuickConnect.writeCommandFile(host: "-oBad", in: directory) == nil)
        QuickConnect.removeFiles(in: directory)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func configReaderTakesOnlyPlainAliases() {
        let config = """
        # comment
        Host prod-web staging
            HostName 10.1.2.3
            User deploy
            IdentityFile ~/.ssh/secret_key
        Host *
            ServerAliveInterval 30
        host Lower-Case
        Host !blocked *.example.com a?b x
        Host "quoted"
        Host  tab\tsep
        HostName not-an-alias
        Host evil;rm $(id) -oProxyCommand=x
        Host good # trailing comment
        """
        let aliases = SSHConfigReader.aliases(in: config)
        #expect(aliases == ["Lower-Case", "good", "prod-web", "sep", "staging", "tab", "x"])
    }

    @Test func configReaderHandlesMissingHugeAndBinaryFiles() throws {
        #expect(SSHConfigReader.aliases(at: "/nonexistent/config").isEmpty)
        let path = NSTemporaryDirectory() + "sistem-cfg-\(UUID().uuidString.prefix(6))"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data(repeating: 0x48, count: SSHConfigReader.sizeLimit + 10).write(to: URL(filePath: path))
        #expect(SSHConfigReader.aliases(at: path).isEmpty)
        try Data((0..<2000).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: URL(filePath: path))
        _ = SSHConfigReader.aliases(at: path)
        let many = (0..<1000).map { "Host h\($0)" }.joined(separator: "\n")
        #expect(SSHConfigReader.aliases(in: many).count <= SSHConfigReader.aliasLimit)
    }
}

final class FakeResolver: HostResolving, @unchecked Sendable {
    var answer: [String]?
    func resolve(_ host: String) async -> [String]? { answer }
}

final class FakeProber: PortProbing, @unchecked Sendable {
    var result = PortResult(state: .open, milliseconds: 1)
    func probe(host: String, port: Int, timeout: TimeInterval) async -> PortResult { result }
}

@Suite("Ağ tanılama")
struct DiagnosticsTests {
    let pingText = """
    PING 127.0.0.1 (127.0.0.1): 56 data bytes
    64 bytes from 127.0.0.1: icmp_seq=0 ttl=64 time=0.092 ms

    --- 127.0.0.1 ping statistics ---
    4 packets transmitted, 3 packets received, 25.0% packet loss
    round-trip min/avg/max/stddev = 0.092/0.113/0.133/0.021 ms
    """

    @Test func parsesPing() {
        let result = NetworkDiagnostics.parsePing(pingText)
        #expect(result == PingResult(sent: 4, received: 3, minimum: 0.092, average: 0.113, maximum: 0.133))
        #expect(result?.lossPercent == 25)
        let lost = NetworkDiagnostics.parsePing("--- x ping statistics ---\n4 packets transmitted, 0 packets received, 100.0% packet loss")
        #expect(lost?.received == 0 && lost?.average == nil)
        #expect(NetworkDiagnostics.parsePing("ping: cannot resolve nope: Unknown host") == nil)
        #expect(NetworkDiagnostics.parsePing("99999 packets transmitted, 5 packets received") == nil)
        #expect(NetworkDiagnostics.parsePing("4 packets transmitted, 9 packets received") == nil)
    }

    @Test func parsesTraceroute() {
        let text = """
        traceroute to 1.1.1.1 (1.1.1.1), 15 hops max, 40 byte packets
         1  192.168.1.1  1.5 ms
         2  *
         3  10.0.0.1  12.3 ms
         4  evil<script>  1 ms
         999  1.2.3.4  1 ms
        """
        let hops = NetworkDiagnostics.parseTraceroute(text)
        #expect(hops.map(\.index) == [1, 2, 3])
        #expect(hops[1].address == nil && hops[2].milliseconds == 12.3)
        #expect(NetworkDiagnostics.parseTraceroute(String(repeating: "garbage\n", count: 500)).isEmpty)
    }

    @Test func requestsUseAbsolutePathsFixedArgumentsAndDashDashBeforeTheHost() {
        for host in ["127.0.0.1", "example.invalid"] {
            for request in [NetworkDiagnostics.pingRequest(host: host), NetworkDiagnostics.tracerouteRequest(host: host)] {
                #expect(request.executable.hasPrefix("/"))
                #expect(request.arguments.suffix(2) == ["--", host])
                #expect(request.timeout <= 45)
            }
        }
        #expect(NetworkDiagnostics.pingRequest(host: "::1").executable == "/sbin/ping6")
    }

    @Test func invalidInputNeverReachesAProcess() async {
        let runner = FakeProcessRunner()
        let tools = NetworkDiagnostics(runner: runner, resolver: FakeResolver(), prober: FakeProber(), clock: ManualServerClock())
        for host in ["-c 100000", "-f", "a;b", "$(id)", "", "a b", "-oProxyCommand=x"] {
            for tool in DiagnosticTool.allCases {
                #expect(await tools.run(tool, host: host, port: "80") == .failed(.invalidInput), "\(tool) \(host.debugDescription)")
            }
        }
        #expect(await tools.run(.port, host: "127.0.0.1", port: "0") == .failed(.invalidInput))
        #expect(await tools.run(.port, host: "127.0.0.1", port: "99999") == .failed(.invalidInput))
        #expect(await tools.run(.port, host: "127.0.0.1", port: "") == .failed(.invalidInput))
        #expect(runner.requests.isEmpty)
    }

    @Test func toolsMapResultsWithFakes() async {
        let runner = FakeProcessRunner()
        runner.respond { _ in .result(Samples.ok(pingTextStatic)) }
        let resolver = FakeResolver()
        let prober = FakeProber()
        let tools = NetworkDiagnostics(runner: runner, resolver: resolver, prober: prober, clock: ManualServerClock())
        if case .ping(let ping) = await tools.run(.ping, host: "127.0.0.1") { #expect(ping.sent == 4) } else { Issue.record("ping") }
        resolver.answer = ["127.0.0.1", "::1"]
        #expect(await tools.run(.dns, host: "localhost") == .dns(DNSResult(addresses: ["127.0.0.1", "::1"])))
        resolver.answer = nil
        #expect(await tools.run(.dns, host: "nope.invalid") == .failed(.noAnswer))
        #expect(await tools.run(.port, host: "127.0.0.1", port: "80") == .port(PortResult(state: .open, milliseconds: 1)))
        runner.respond { _ in .result(ProcessResult(outcome: .launchFailed)) }
        #expect(await tools.run(.traceroute, host: "127.0.0.1") == .failed(.toolMissing))
        runner.respond { _ in .result(Samples.ok("nothing useful")) }
        #expect(await tools.run(.traceroute, host: "127.0.0.1") == .failed(.badOutput))
    }

    @Test func hangingToolEndsAtItsDeadline() async {
        let runner = FakeProcessRunner()
        runner.respond { _ in .hang }
        let clock = ManualServerClock()
        let tools = NetworkDiagnostics(runner: runner, resolver: FakeResolver(), prober: FakeProber(), clock: clock)
        let task = Task { await tools.run(.ping, host: "127.0.0.1") }
        #expect(await eventually { clock.sleeperCount == 1 })
        clock.advance(by: NetworkDiagnostics.pingTimeout + 1)
        #expect(await task.value == .failed(.timedOut))
    }

    // Loopback only: the sanctioned local target, real system tools.
    @Test func realPingAndTracerouteOnLoopback() async {
        let tools = NetworkDiagnostics()
        if case .ping(let ping) = await tools.run(.ping, host: "127.0.0.1") { #expect(ping.received == 4 && ping.lossPercent == 0) } else { Issue.record("ping başarısız") }
        if case .traceroute(let trace) = await tools.run(.traceroute, host: "127.0.0.1") { #expect(trace.hops.first?.address == "127.0.0.1") } else { Issue.record("traceroute başarısız") }
    }

    @Test func realDNSOnLocalhost() async {
        if case .dns(let result) = await NetworkDiagnostics().run(.dns, host: "localhost") { #expect(result.addresses.contains("127.0.0.1") || result.addresses.contains("::1")) } else { Issue.record("dns başarısız") }
    }

    @Test func realPortCheckOnLoopback() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { $0.cancel() }
        let ready = AsyncStream<UInt16>.makeStream()
        listener.stateUpdateHandler = { state in if case .ready = state, let port = listener.port?.rawValue { ready.continuation.yield(port) } }
        listener.start(queue: .global())
        defer { listener.cancel() }
        var openPort: UInt16 = 0
        for await port in ready.stream { openPort = port; break }
        let tools = NetworkDiagnostics()
        if case .port(let open) = await tools.run(.port, host: "127.0.0.1", port: String(openPort)) { #expect(open.state == .open) } else { Issue.record("port") }
        listener.cancel()
        try? await Task.sleep(for: .milliseconds(200))
        if case .port(let closed) = await tools.run(.port, host: "127.0.0.1", port: String(openPort)) { #expect(closed.state == .refused) } else { Issue.record("port") }
    }
}

private let pingTextStatic = "--- x ping statistics ---\n4 packets transmitted, 4 packets received, 0.0% packet loss\nround-trip min/avg/max/stddev = 1/2/3/4 ms"
