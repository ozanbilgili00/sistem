import Foundation
import Testing
@testable import SystemKit

@MainActor
struct ControllerFixture {
    let runner = FakeProcessRunner()
    let clock = ManualServerClock()
    let controller: ServersController
    let remote: RemoteActor

    init() {
        remote = RemoteActor(runner: runner, clock: clock, environment: SSHEnvironment(), dockerCandidates: [])
        controller = ServersController(remote: remote, clock: clock, registry: ProcessRegistry())
    }

    func state(of id: UUID) -> ServerRuntime? { controller.state.servers.first { $0.id == id } }
}

@Suite("Sunucu denetleyicisi")
@MainActor
struct ServersControllerTests {
    /// Kapı 2: servers listed, nothing visible, background check off → no task, no timer, no process.
    @Test func listedServersCostNothingWhileClosed() async throws {
        let f = ControllerFixture()
        f.controller.apply(ServersConfig(enabled: true, servers: [Samples.server("A"), Samples.server("B", host: "b.example.invalid")], reachabilityCheck: false))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!f.controller.isPolling)
        #expect(f.clock.sleeperCount == 0)
        #expect(f.runner.requests.isEmpty)
        #expect(await f.remote.callCount == 0)
        #expect(f.controller.runningTunnelCount == 0)
        // Module off entirely: even a visible page does nothing.
        f.controller.apply(ServersConfig(enabled: false, servers: [Samples.server()]))
        f.controller.setVisible(true)
        #expect(!f.controller.isPolling && f.runner.requests.isEmpty)
    }

    @Test func noServersMeansNoPollingEvenWhenVisible() {
        let f = ControllerFixture()
        f.controller.apply(ServersConfig(enabled: true, servers: [], reachabilityCheck: true))
        f.controller.setVisible(true)
        #expect(!f.controller.isPolling)
    }

    @Test func visiblePageReadsAndClosingStopsEverything() async throws {
        let f = ControllerFixture()
        f.runner.respond { _ in .result(Samples.ok(Samples.linux)) }
        let server = Samples.server()
        f.controller.apply(ServersConfig(enabled: true, servers: [server]))
        f.controller.setVisible(true)
        #expect(f.controller.isPolling)
        #expect(f.state(of: server.id)?.phase == .connecting)
        #expect(await eventuallyOnMain { f.state(of: server.id)?.phase == .online })
        #expect(f.state(of: server.id)?.metrics?.memoryTotal == 8_000_000 * 1024)
        #expect(await eventuallyOnMain { f.clock.sleeperCount == 1 }, "sonraki okuma 4 sn sonra")
        let before = f.runner.requests.count
        f.clock.advance(by: ServersController.visibleInterval)
        #expect(await eventuallyOnMain { f.runner.requests.count == before + 1 })
        f.controller.setVisible(false)
        #expect(!f.controller.isPolling)
        #expect(f.state(of: server.id)?.phase == .idle && f.state(of: server.id)?.metrics == nil)
        #expect(await eventuallyOnMain { f.clock.sleeperCount == 0 })
        let after = f.runner.requests.count
        f.clock.advance(by: 600)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(f.runner.requests.count == after, "kapalıyken tek istek yok")
    }

    /// Kapı 1: a hung ssh never blocks the main actor; the UI state ends as timed out at 10 s.
    @Test func hungConnectionDoesNotBlockTheMainActorAndTimesOut() async throws {
        let f = ControllerFixture()
        f.runner.respond { _ in .hang }
        let server = Samples.server()
        f.controller.apply(ServersConfig(enabled: true, servers: [server]))
        f.controller.setVisible(true)
        #expect(await eventuallyOnMain { f.runner.requests.count == 1 && f.clock.sleeperCount >= 1 })
        // The main actor stays free while the connection hangs: this loop is interleaved with the hung call.
        var turns = 0
        for _ in 0..<20 { await Task.yield(); turns += 1 }
        #expect(turns == 20)
        #expect(f.state(of: server.id)?.phase == .connecting)
        f.clock.advance(by: 10)
        #expect(await eventuallyOnMain { f.state(of: server.id)?.phase == .failed(.timedOut) })
        #expect(await eventuallyOnMain { f.runner.cancelledCount == 1 })
    }

    @Test func failuresShowAsStatesAndRecovery() async {
        let f = ControllerFixture()
        let server = Samples.server()
        f.controller.apply(ServersConfig(enabled: true, servers: [server]))
        f.runner.respond { _ in .result(Samples.sshError("Host key verification failed.")) }
        f.controller.setVisible(true)
        #expect(await eventuallyOnMain { f.state(of: server.id)?.phase == .failed(.hostKeyUnknown) })
        f.runner.respond { _ in .result(Samples.ok(Samples.linux)) }
        #expect(await eventuallyOnMain { f.clock.sleeperCount == 1 })
        f.clock.advance(by: 4)
        #expect(await eventuallyOnMain { f.state(of: server.id)?.phase == .online })
    }

    @Test func cpuRateComesFromTwoReadings() async {
        let f = ControllerFixture()
        let server = Samples.server()
        f.controller.apply(ServersConfig(enabled: true, servers: [server]))
        f.runner.respond { _ in .result(Samples.ok(Samples.linux)) }
        f.controller.setVisible(true)
        #expect(await eventuallyOnMain { f.state(of: server.id)?.phase == .online })
        #expect(f.state(of: server.id)?.metrics?.cpu == nil, "tek okuma: oran yok")
        let later = Samples.linux.replacingOccurrences(of: "cpu 1000 10 500 8000 100 0 20 0", with: "cpu 1500 10 500 8500 100 0 20 0")
        f.runner.respond { _ in .result(Samples.ok(later)) }
        #expect(await eventuallyOnMain { f.clock.sleeperCount == 1 })
        f.clock.advance(by: 4)
        #expect(await eventuallyOnMain { f.state(of: server.id)?.metrics?.cpu != nil })
        #expect(f.state(of: server.id)?.metrics?.cpu == 0.5)
    }

    @Test func backgroundCheckIsOptInAndLightweight() async {
        let f = ControllerFixture()
        let server = Samples.server()
        f.runner.respond { _ in .result(ProcessResult(outcome: .exited(0))) }
        f.controller.apply(ServersConfig(enabled: true, servers: [server], reachabilityCheck: true))
        #expect(f.controller.isPolling)
        #expect(await eventuallyOnMain { f.state(of: server.id)?.phase == .reachable })
        #expect(f.runner.requests.allSatisfy { $0.arguments.last == "true" && $0.input == nil }, "betik değil, yalnız `true`")
        #expect(f.state(of: server.id)?.metrics == nil)
        #expect(await eventuallyOnMain { f.clock.sleeperCount == 1 })
        f.clock.advance(by: 59)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(f.runner.requests.count == 1)
        f.clock.advance(by: 1)
        #expect(await eventuallyOnMain { f.runner.requests.count == 2 })
        // A visible page upgrades to full reads; closing it falls back to the check.
        f.controller.setVisible(true)
        #expect(await eventuallyOnMain { f.runner.requests.contains { $0.input != nil } })
        f.controller.setVisible(false)
        #expect(f.controller.isPolling)
    }

    @Test func sleepAndLockPausePolling() async {
        let f = ControllerFixture()
        f.runner.respond { _ in .result(Samples.ok(Samples.linux)) }
        f.controller.apply(ServersConfig(enabled: true, servers: [Samples.server()], reachabilityCheck: true))
        #expect(f.controller.isPolling)
        f.controller.setPaused(true)
        #expect(!f.controller.isPolling)
        f.controller.setPaused(false)
        #expect(f.controller.isPolling)
    }

    @Test func downNotificationFiresOnceAfterTwoMinutesAndRecovers() async {
        let f = ControllerFixture()
        let server = Samples.server()
        var notified: [UUID] = []
        f.controller.onServerDown = { notified.append($0.id) }
        f.runner.respond { _ in .result(Samples.sshError("Connection timed out")) }
        f.controller.apply(ServersConfig(enabled: true, servers: [server], reachabilityCheck: true))
        for step in 0..<4 {
            #expect(await eventuallyOnMain { f.state(of: server.id)?.phase == .failed(.timedOut) && f.clock.sleeperCount == 1 })
            #expect(notified.isEmpty == (step < 2), "ikinci dakikanın sonunda tek bildirim (adım \(step))")
            let count = f.runner.requests.count
            f.clock.advance(by: ServersController.reachabilityInterval)
            #expect(await eventuallyOnMain { f.runner.requests.count == count + 1 })
        }
        #expect(notified == [server.id])
        #expect(f.state(of: server.id)?.isDown == true)
        f.runner.respond { _ in .result(ProcessResult(outcome: .exited(0))) }
        #expect(await eventuallyOnMain { f.clock.sleeperCount == 1 })
        f.clock.advance(by: 60)
        #expect(await eventuallyOnMain { f.state(of: server.id)?.isDown == false })
    }

    @Test func authFailureDoesNotCountAsDown() async {
        let f = ControllerFixture()
        let server = Samples.server()
        var notified = 0
        f.controller.onServerDown = { _ in notified += 1 }
        f.runner.respond { _ in .result(Samples.sshError("Permission denied (publickey).")) }
        f.controller.apply(ServersConfig(enabled: true, servers: [server], reachabilityCheck: true))
        for _ in 0..<5 {
            #expect(await eventuallyOnMain { f.clock.sleeperCount == 1 })
            f.clock.advance(by: 60)
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(notified == 0)
    }

    @Test func noAlertsWithoutTheBackgroundCheck() async {
        let f = ControllerFixture()
        var notified = 0
        f.controller.onServerDown = { _ in notified += 1 }
        f.runner.respond { _ in .result(Samples.sshError("Connection timed out")) }
        f.controller.apply(ServersConfig(enabled: true, servers: [Samples.server()]))
        f.controller.setVisible(true)
        for _ in 0..<40 {
            #expect(await eventuallyOnMain { f.clock.sleeperCount == 1 })
            f.clock.advance(by: 4)
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(notified == 0)
    }

    @Test func removingAServerDropsItsStateAndEditingResetsIt() async {
        let f = ControllerFixture()
        f.runner.respond { _ in .result(Samples.ok(Samples.linux)) }
        let a = Samples.server("A"), b = Samples.server("B", host: "b.example.invalid")
        f.controller.apply(ServersConfig(enabled: true, servers: [a, b]))
        f.controller.setVisible(true)
        #expect(await eventuallyOnMain { f.controller.state.servers.allSatisfy { $0.phase == .online } })
        f.controller.apply(ServersConfig(enabled: true, servers: [b]))
        #expect(f.controller.state.servers.map(\.id) == [b.id])
        var edited = b
        edited.host = "other.example.invalid"
        f.controller.apply(ServersConfig(enabled: true, servers: [edited]))
        #expect(f.state(of: b.id)?.metrics == nil, "bağlantı değişince eski ölçüm atılır")
    }
}

@Suite("SSH tünelleri")
@MainActor
struct TunnelTests {
    func fixture() -> (ControllerFixture, ServerConfig, TunnelSpec) {
        let f = ControllerFixture()
        let tunnel = TunnelSpec(kind: .local, listenPort: 8080, targetHost: "db.internal", targetPort: 5432)
        let server = Samples.server(tunnels: [tunnel])
        f.controller.apply(ServersConfig(enabled: true, servers: [server]))
        return (f, server, tunnel)
    }

    func phase(_ f: ControllerFixture, _ server: ServerConfig, _ tunnel: TunnelSpec) -> TunnelStatus.Phase? {
        f.state(of: server.id)?.tunnels[tunnel.id]?.phase
    }

    @Test func backoffGrowsAndIsCapped() {
        let delays = (0..<10).map { ServersController.Backoff.delay(afterAttempt: $0) }
        #expect(delays == [2, 4, 8, 16, 32, 60, 60, 60, 60, 60])
        #expect(ServersController.Backoff.delay(afterAttempt: -3) == 2)
        #expect(ServersController.Backoff.delay(afterAttempt: 100_000) == 60)
    }

    @Test func startsRunsAndStops() async {
        let (f, server, tunnel) = fixture()
        f.controller.startTunnel(server: server.id, tunnel: tunnel.id)
        #expect(await eventuallyOnMain { f.runner.launched.count == 1 })
        #expect(phase(f, server, tunnel) == .starting)
        #expect(f.runner.requests.last?.arguments.contains("-N") == true)
        #expect(await eventuallyOnMain { f.clock.sleeperCount == 1 })
        f.clock.advance(by: ServersController.tunnelSettleTime)
        #expect(await eventuallyOnMain { phase(f, server, tunnel) == .running })
        f.controller.stopTunnel(tunnel.id)
        #expect(await eventuallyOnMain { f.runner.launched[0].wasTerminated })
        #expect(phase(f, server, tunnel) == .stopped)
        #expect(f.controller.runningTunnelCount == 0)
    }

    @Test func droppedTunnelReconnectsWithGrowingDelay() async {
        let (f, server, tunnel) = fixture()
        f.controller.startTunnel(server: server.id, tunnel: tunnel.id)
        var expectedDelays: [TimeInterval] = []
        for attempt in 0..<4 {
            #expect(await eventuallyOnMain { f.runner.launched.count == attempt + 1 })
            f.runner.launched[attempt].end(Samples.sshError("Connection timed out"))
            let delay = ServersController.Backoff.delay(afterAttempt: attempt)
            expectedDelays.append(delay)
            #expect(await eventuallyOnMain {
                if case .waiting(let retryAt)? = phase(f, server, tunnel) { return abs(retryAt.timeIntervalSince(f.clock.now()) - delay) < 0.01 }
                return false
            }, "deneme \(attempt): \(delay) sn beklenmeli")
            #expect(await eventuallyOnMain { f.clock.sleeperCount >= 1 })
            f.clock.advance(by: delay - 0.5)
            try? await Task.sleep(for: .milliseconds(20))
            #expect(f.runner.launched.count == attempt + 1, "erken yeniden bağlanma yok")
            f.clock.advance(by: 0.5)
        }
        #expect(expectedDelays == [2, 4, 8, 16])
        f.controller.stopTunnel(tunnel.id)
    }

    @Test func stableTunnelResetsTheBackoff() async {
        let (f, server, tunnel) = fixture()
        f.controller.startTunnel(server: server.id, tunnel: tunnel.id)
        for attempt in 0..<2 {
            #expect(await eventuallyOnMain { f.runner.launched.count == attempt + 1 })
            f.runner.launched[attempt].end(Samples.sshError("Connection timed out"))
            #expect(await eventuallyOnMain { if case .waiting? = phase(f, server, tunnel) { return f.clock.sleeperCount == 1 }; return false })
            f.clock.advance(by: 60)
        }
        #expect(await eventuallyOnMain { f.runner.launched.count == 3 })
        #expect(await eventuallyOnMain { f.clock.sleeperCount == 1 })
        f.clock.advance(by: ServersController.tunnelStableTime + 1)
        f.runner.launched[2].end(Samples.sshError("Connection reset by peer"))
        #expect(await eventuallyOnMain {
            if case .waiting(let retryAt)? = phase(f, server, tunnel) { return abs(retryAt.timeIntervalSince(f.clock.now()) - 2) < 0.01 }
            return false
        }, "uzun süre ayakta kalan tünelin bekleme süresi başa döner")
        f.controller.stopTunnel(tunnel.id)
    }

    @Test(arguments: [
        ("Permission denied (publickey).", RemoteFailure.authRejected),
        ("Host key verification failed.", .hostKeyUnknown),
        ("bind [127.0.0.1]:8080: Address already in use\nCould not request local forwarding.", .forwardFailed),
    ])
    func permanentFailuresAreNotRetried(text: String, expected: RemoteFailure) async {
        let (f, server, tunnel) = fixture()
        f.controller.startTunnel(server: server.id, tunnel: tunnel.id)
        #expect(await eventuallyOnMain { f.runner.launched.count == 1 })
        f.runner.launched[0].end(Samples.sshError(text))
        #expect(await eventuallyOnMain { phase(f, server, tunnel) == .failed(expected) })
        f.clock.advance(by: 600)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(f.runner.launched.count == 1)
        // The user can try again after fixing it.
        f.controller.startTunnel(server: server.id, tunnel: tunnel.id)
        #expect(await eventuallyOnMain { f.runner.launched.count == 2 })
        f.controller.stopTunnel(tunnel.id)
    }

    @Test func launchFailureIsAState() async {
        let (f, server, tunnel) = fixture()
        f.runner.allowLaunch { _ in false }
        f.controller.startTunnel(server: server.id, tunnel: tunnel.id)
        #expect(await eventuallyOnMain { phase(f, server, tunnel) == .failed(.launchFailed) })
    }

    @Test func tunnelsNeverStartWhenModuleIsOffAndStopWhenItGoesOff() async {
        let (f, server, tunnel) = fixture()
        f.controller.apply(ServersConfig(enabled: false, servers: [server]))
        f.controller.startTunnel(server: server.id, tunnel: tunnel.id)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(f.runner.launched.isEmpty)
        f.controller.apply(ServersConfig(enabled: true, servers: [server]))
        f.controller.startTunnel(server: server.id, tunnel: tunnel.id)
        #expect(await eventuallyOnMain { f.runner.launched.count == 1 })
        f.controller.apply(ServersConfig(enabled: false, servers: [server]))
        #expect(await eventuallyOnMain { f.runner.launched[0].wasTerminated })
        #expect(f.controller.runningTunnelCount == 0)
    }

    @Test func removingOrEditingAServerStopsItsTunnels() async {
        let (f, server, tunnel) = fixture()
        f.controller.startTunnel(server: server.id, tunnel: tunnel.id)
        #expect(await eventuallyOnMain { f.runner.launched.count == 1 })
        var edited = server
        edited.tunnels[0].targetPort = 6000
        f.controller.apply(ServersConfig(enabled: true, servers: [edited]))
        #expect(await eventuallyOnMain { f.runner.launched[0].wasTerminated }, "değiştirilen tünel durdurulur")
        f.controller.startTunnel(server: server.id, tunnel: tunnel.id)
        #expect(await eventuallyOnMain { f.runner.launched.count == 2 })
        f.controller.apply(ServersConfig(enabled: true, servers: []))
        #expect(await eventuallyOnMain { f.runner.launched[1].wasTerminated }, "silinen sunucunun tüneli durdurulur")
    }

    @Test func shutdownEndsEveryTunnel() async {
        let (f, server, tunnel) = fixture()
        f.controller.startTunnel(server: server.id, tunnel: tunnel.id)
        #expect(await eventuallyOnMain { f.runner.launched.count == 1 })
        await f.controller.shutdown()
        #expect(f.runner.launched[0].wasTerminated)
        #expect(f.controller.runningTunnelCount == 0 && !f.controller.isPolling)
    }

    @Test func tunnelCountIsLimited() async {
        let f = ControllerFixture()
        let tunnels = (0..<10).map { TunnelSpec(kind: .dynamic, listenPort: 2000 + $0) }
        let a = Samples.server("A", tunnels: tunnels)
        let b = Samples.server("B", host: "b.example.invalid", tunnels: [TunnelSpec(kind: .dynamic, listenPort: 3000)])
        f.controller.apply(ServersConfig(enabled: true, servers: [a, b]))
        for tunnel in tunnels { f.controller.startTunnel(server: a.id, tunnel: tunnel.id) }
        f.controller.startTunnel(server: b.id, tunnel: b.tunnels[0].id)
        #expect(f.controller.runningTunnelCount == ServersController.maxRunningTunnels)
        for tunnel in tunnels { f.controller.stopTunnel(tunnel.id) }
    }
}
