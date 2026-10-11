import Foundation
import Testing
@testable import SystemKit

/// Real `/usr/bin/ssh` against a throw-away user-level sshd on 127.0.0.1 (key pair, known_hosts and config all in a
/// scratch directory). Runs only when `SISTEM_E2E_DIR` points at the prepared directory; otherwise it does nothing.
@Suite("Gerçek sshd (yalnız 127.0.0.1)")
struct ServerEndToEndTests {
    static var directory: String? { ProcessInfo.processInfo.environment["SISTEM_E2E_DIR"] }

    @Test func fullFlowAgainstLocalSshd() async throws {
        guard let dir = Self.directory else { return }
        let hostPub = try String(contentsOfFile: dir + "/hostkey.pub", encoding: .utf8).split(separator: " ").prefix(2).joined(separator: " ")
        let known = dir + "/known_hosts"
        try Data().write(to: URL(filePath: known))
        let control = NSTemporaryDirectory() + "sse-\(UUID().uuidString.prefix(5))"
        defer { try? FileManager.default.removeItem(atPath: control) }
        let registry = ProcessRegistry()
        let environment = SSHEnvironment(configFile: dir + "/client_config", controlDirectory: control)
        let remote = RemoteActor(runner: SystemProcessRunner(registry: registry), clock: SystemServerClock(), environment: environment)
        let server = ServerConfig(name: "e2e", kind: .macOS, host: "e2e", user: NSUserName())

        // 1. Unknown host key: a clean state, and known_hosts is not written by us.
        #expect(await remote.probe(server) == .failure(.hostKeyUnknown))
        #expect((try String(contentsOfFile: known, encoding: .utf8)).isEmpty, "known_hosts kendiliğinden yazılmamalı")

        // 2. Host key known: the fixed script runs and parses.
        try "[127.0.0.1]:49222 \(hostPub)\n".write(toFile: known, atomically: true, encoding: .utf8)
        guard case .reading(let first) = await remote.probe(server) else { Issue.record("okuma bekleniyordu"); return }
        #expect(first.memoryTotal ?? 0 > 0 && first.cores ?? 0 > 0 && first.diskTotal ?? 0 > 0 && first.load?.count == 3)
        #expect(first.cpuFraction != nil && first.uptime ?? 0 > 0)
        // 3. One shared connection: a socket exists in our private directory, and the second call reuses it.
        let sockets = try FileManager.default.contentsOfDirectory(atPath: control)
        #expect(sockets.count == 1)
        let mode = try FileManager.default.attributesOfItem(atPath: control)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        #expect(await remote.reachability(server) == nil)

        // 4. A tunnel: its own ssh process forwards 49300 to the sshd port; ending it closes the port.
        let tunnel = TunnelSpec(kind: .local, listenPort: 49_300, targetHost: "127.0.0.1", targetPort: 49_222)
        var withTunnel = server
        withTunnel.tunnels = [tunnel]
        let process = try #require(await remote.launchTunnel(server: withTunnel, tunnel: tunnel))
        let prober = SystemPortProber()
        var open = false
        for _ in 0..<40 where !open {
            open = await prober.probe(host: "127.0.0.1", port: 49_300, timeout: 2).state == .open
            if !open { try? await Task.sleep(for: .milliseconds(200)) }
        }
        #expect(open, "tünel portu açılmalı")
        process.terminate()
        _ = await process.finished()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await prober.probe(host: "127.0.0.1", port: 49_300, timeout: 2).state == .refused, "tünel kapanınca port kapanmalı")

        // 5. Shutdown closes the master and removes the sockets.
        await remote.shutdown(servers: [server])
        #expect((try FileManager.default.contentsOfDirectory(atPath: control)).isEmpty)
        #expect(registry.count == 0)

        // 6. A key the server does not accept: "key rejected", no prompt, no hang.
        let wrong = dir + "/client_config_wrong"
        try (try String(contentsOfFile: dir + "/client_config", encoding: .utf8).replacingOccurrences(of: "userkey", with: "wrongkey")).write(toFile: wrong, atomically: true, encoding: .utf8)
        let other = RemoteActor(runner: SystemProcessRunner(registry: registry), clock: SystemServerClock(), environment: SSHEnvironment(configFile: wrong))
        let started = ContinuousClock.now
        #expect(await other.probe(server) == .failure(.authRejected))
        #expect(started.duration(to: .now) < .seconds(10))

        // 7. Nothing listening: refused, quickly.
        let dead = ServerConfig(name: "dead", kind: .macOS, host: "127.0.0.1", user: NSUserName(), port: 49_299)
        let result = await other.probe(dead)
        #expect(result == .failure(.refused) || result == .failure(.hostKeyUnknown), "\(result)")
    }
}
