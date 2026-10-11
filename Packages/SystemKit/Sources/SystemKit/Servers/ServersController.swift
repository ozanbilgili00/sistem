import Foundation
import os

/// What the user switched on and listed. Stored by the app, handed over whole.
public struct ServersConfig: Equatable, Sendable {
    public var enabled = false
    public var servers: [ServerConfig] = []
    /// Background "is it up" check every ``ServersController/reachabilityInterval``, plus a notification when a server stays down. Off by default.
    public var reachabilityCheck = false

    public init(enabled: Bool = false, servers: [ServerConfig] = [], reachabilityCheck: Bool = false) {
        self.enabled = enabled
        self.servers = servers
        self.reachabilityCheck = reachabilityCheck
    }
}

public enum ServerPhase: Equatable, Sendable {
    /// Nothing is being asked: the page is closed (and no background check runs).
    case idle
    case connecting
    /// Answers, but the metrics are not read right now (background check only).
    case reachable
    case online
    case failed(RemoteFailure)
}

public struct TunnelStatus: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case stopped
        /// Process started, not yet alive for ``ServersController/tunnelSettleTime``.
        case starting
        case running
        /// Dropped; the next attempt is at the given time.
        case waiting(Date)
        /// Will not be retried: only the user can fix it.
        case failed(RemoteFailure)
    }
    public var phase: Phase = .stopped
    public var attempt = 0
    public init(phase: Phase = .stopped, attempt: Int = 0) {
        self.phase = phase
        self.attempt = attempt
    }
}

public struct ServerRuntime: Equatable, Sendable, Identifiable {
    public var config: ServerConfig
    public var phase: ServerPhase = .idle
    public var metrics: ServerMetrics?
    public var lastSeen: Date?
    /// The "down" notification fired and the server has not come back.
    public var isDown = false
    public var tunnels: [UUID: TunnelStatus] = [:]
    public var id: UUID { config.id }

    public init(config: ServerConfig) { self.config = config }
}

public struct ServersState: Equatable, Sendable {
    public var enabled = false
    public var servers: [ServerRuntime] = []
    public init() {}
}

/// Owns everything about the servers that changes over time: when to ask, what was answered, the tunnels.
///
/// - **No work without a reason.** A task exists only while (a) a page or popover is visible, or (b) the
///   background check is switched on; otherwise there is no task, no timer and no process, however many servers are listed.
/// - **Visible**: every ``visibleInterval`` all servers are read through one ssh connection each. **Background**:
///   every ``reachabilityInterval`` a bare "does it answer". Sleep and screen lock pause both.
/// - **Tunnels** are processes this controller supervises: a dropped one is restarted with a growing delay
///   (``Backoff``), unless the failure is one only the user can fix.
/// - Host names, users and ssh's error text are neither logged nor kept; failures are reduced to ``RemoteFailure``.
@MainActor
public final class ServersController {
    public static let visibleInterval: TimeInterval = 4
    public static let reachabilityInterval: TimeInterval = 60
    public static let tunnelSettleTime: TimeInterval = 3
    /// A tunnel that stayed up this long starts its next backoff from the beginning.
    public static let tunnelStableTime: TimeInterval = 30
    public static let maxRunningTunnels = 10

    public private(set) var state = ServersState()
    public var onChange: (() -> Void)?
    /// A server has been unreachable long enough to notify (once, then silence until it recovers and the cooldown passes).
    public var onServerDown: ((ServerConfig) -> Void)?

    private let remote: RemoteActor
    private let clock: any ServerClock
    private let registry: ProcessRegistry
    private let log = Logger(subsystem: "com.ozan.sistem", category: "servers")

    private var config = ServersConfig()
    private var visible = false
    private var paused = false
    private enum Mode: Equatable { case visible, background }
    private var mode: Mode?
    private var pollTask: Task<Void, Never>?
    private var generation = 0
    private var previous: [UUID: (reading: ServerReading, date: Date)] = [:]
    private var machines: [UUID: ThresholdMachine] = [:]
    private var lastPublished: ServersState?

    private var tunnelTasks: [UUID: Task<Void, Never>] = [:]
    private var tunnelProcesses: [UUID: RunningProcess] = [:]

    public init(remote: RemoteActor, clock: any ServerClock, registry: ProcessRegistry = .shared) {
        self.remote = remote
        self.clock = clock
        self.registry = registry
    }

    /// Whether the polling task exists. For tests and diagnostics.
    public var isPolling: Bool { pollTask != nil }
    public var runningTunnelCount: Int { tunnelTasks.count }

    // MARK: Configuration

    public func apply(_ new: ServersConfig) {
        guard new != config else { return }
        let old = config
        config = new
        let newIDs = Set(new.servers.map(\.id))
        let removed = old.servers.filter { !newIDs.contains($0.id) }

        if !new.enabled { stopAllTunnels() }
        for server in removed { stopTunnels(of: server.id) }
        for server in new.servers {
            guard let before = old.servers.first(where: { $0.id == server.id }) else { continue }
            if before.connectionKey != server.connectionKey { stopTunnels(of: server.id); previous[server.id] = nil }
            // A tunnel that was edited or deleted while running is stopped; it can be started again from the new definition.
            for tunnel in before.tunnels where server.tunnels.first(where: { $0.id == tunnel.id }) != tunnel { stopTunnel(tunnel.id) }
        }

        var runtimes: [ServerRuntime] = []
        for server in new.servers {
            var runtime = state.servers.first { $0.id == server.id } ?? ServerRuntime(config: server)
            if runtime.config.connectionKey != server.connectionKey {
                runtime = ServerRuntime(config: server)
            }
            runtime.config = server
            runtime.tunnels = runtime.tunnels.filter { id, _ in server.tunnels.contains { $0.id == id } }
            runtimes.append(runtime)
        }
        state.servers = runtimes
        state.enabled = new.enabled
        machines = machines.filter { newIDs.contains($0.key) }
        previous = previous.filter { newIDs.contains($0.key) }
        if !removed.isEmpty, old.enabled {
            let gone = removed
            Task { await remote.shutdown(servers: gone) }
        }
        updatePolling()
        publish()
    }

    /// A page or popover with the servers is on screen (true) or not.
    public func setVisible(_ shown: Bool) {
        guard shown != visible else { return }
        visible = shown
        updatePolling()
    }

    /// The Mac is asleep or locked: nobody can look, and a connection would only time out.
    public func setPaused(_ value: Bool) {
        guard value != paused else { return }
        paused = value
        updatePolling()
    }

    // MARK: Polling

    private func updatePolling() {
        var wanted: Mode?
        if config.enabled, !config.servers.isEmpty, !paused {
            if visible { wanted = .visible } else if config.reachabilityCheck { wanted = .background }
        }
        guard wanted != mode else { return }
        pollTask?.cancel()
        pollTask = nil
        generation += 1
        let leaving = mode
        mode = wanted
        guard let wanted else {
            // Nothing is asked any more; what was shown is dropped so a later page starts from "connecting".
            if leaving != nil { resetTransientState(keepFailures: !visible) }
            publish()
            return
        }
        if wanted == .visible { for index in state.servers.indices where state.servers[index].phase == .idle { state.servers[index].phase = .connecting } }
        let token = generation
        pollTask = Task { [weak self] in await self?.pollLoop(wanted, token: token) }
        publish()
    }

    private func resetTransientState(keepFailures: Bool) {
        previous = [:]
        for index in state.servers.indices {
            state.servers[index].metrics = nil
            state.servers[index].phase = .idle
        }
    }

    private func pollLoop(_ mode: Mode, token: Int) async {
        while !Task.isCancelled {
            await pollOnce(mode, token: token)
            let interval = mode == .visible ? Self.visibleInterval : Self.reachabilityInterval
            do { try await clock.sleep(for: interval) } catch { return }
        }
    }

    private func pollOnce(_ mode: Mode, token: Int) async {
        let servers = state.servers.map(\.config)
        let remote = remote
        await withTaskGroup(of: (UUID, RemoteProbeResult).self) { group in
            for server in servers {
                group.addTask {
                    switch mode {
                    case .visible:
                        return (server.id, await remote.probe(server))
                    case .background:
                        if let failure = await remote.reachability(server) { return (server.id, .failure(failure)) }
                        return (server.id, .reading(ServerReading(kind: server.kind)))
                    }
                }
            }
            for await (id, result) in group {
                guard token == generation else { continue }
                received(result, for: id, mode: mode)
            }
        }
    }

    private func received(_ result: RemoteProbeResult, for id: UUID, mode: Mode) {
        guard let index = state.servers.firstIndex(where: { $0.id == id }) else { return }
        let date = clock.now()
        switch result {
        case .reading(let reading):
            if mode == .visible {
                state.servers[index].metrics = ServerMetrics.make(reading, at: date, previous: previous[id])
                state.servers[index].phase = .online
                previous[id] = (reading, date)
            } else {
                state.servers[index].phase = .reachable
            }
            state.servers[index].lastSeen = date
            feedAlert(id, value: 0, at: date)
        case .failure(let failure):
            state.servers[index].phase = .failed(failure)
            state.servers[index].metrics = nil
            previous[id] = nil
            feedAlert(id, value: failure.isConnectivity ? 1 : nil, at: date)
        }
        log.debug("server result mode=\(mode == .visible ? "visible" : "background")")
        publish()
    }

    /// Only with the background check on: that is the user's request for notifications.
    private func feedAlert(_ id: UUID, value: Double?, at date: Date) {
        guard config.reachabilityCheck, let index = state.servers.firstIndex(where: { $0.id == id }) else { return }
        var machine = machines[id] ?? ThresholdMachine(Self.downSpec)
        let transition = machine.feed(value, at: date)
        machines[id] = machine
        switch transition {
        case .triggered?:
            state.servers[index].isDown = true
            onServerDown?(state.servers[index].config)
        case .recovered?:
            state.servers[index].isDown = false
        case nil:
            break
        }
    }

    /// Down = unreachable for two minutes; back = one good answer. One notification per half hour at most.
    static let downSpec = ThresholdSpec(direction: .above, trigger: 1, clear: 0, minDuration: 120, clearDuration: 0, cooldown: 1800, staleAfter: 900)

    // MARK: Tunnels

    /// Backoff between restarts: 2, 4, 8, 16, 32, then 60 seconds.
    public enum Backoff {
        public static func delay(afterAttempt attempt: Int) -> TimeInterval {
            min(60, 2 * pow(2, Double(min(max(attempt, 0), 10))))
        }
    }

    public func startTunnel(server serverID: UUID, tunnel tunnelID: UUID) {
        guard config.enabled, tunnelTasks[tunnelID] == nil, tunnelTasks.count < Self.maxRunningTunnels,
              let server = config.servers.first(where: { $0.id == serverID }), server.kind.usesSSH,
              let tunnel = server.tunnels.first(where: { $0.id == tunnelID }) else { return }
        setTunnel(serverID, tunnelID, TunnelStatus(phase: .starting, attempt: 0))
        tunnelTasks[tunnelID] = Task { [weak self] in await self?.superviseTunnel(server: server, tunnel: tunnel) }
    }

    public func stopTunnel(_ tunnelID: UUID) {
        tunnelTasks.removeValue(forKey: tunnelID)?.cancel()
        tunnelProcesses.removeValue(forKey: tunnelID)?.terminate()
        for index in state.servers.indices where state.servers[index].tunnels[tunnelID] != nil {
            state.servers[index].tunnels[tunnelID] = TunnelStatus()
        }
        publish()
    }

    private func stopTunnels(of serverID: UUID) {
        guard let server = state.servers.first(where: { $0.id == serverID }) ?? config.servers.first(where: { $0.id == serverID }).map({ ServerRuntime(config: $0) }) else { return }
        for tunnel in server.config.tunnels { stopTunnel(tunnel.id) }
    }

    private func stopAllTunnels() {
        for id in Array(tunnelTasks.keys) { stopTunnel(id) }
    }

    private func setTunnel(_ serverID: UUID, _ tunnelID: UUID, _ status: TunnelStatus) {
        guard let index = state.servers.firstIndex(where: { $0.id == serverID }) else { return }
        state.servers[index].tunnels[tunnelID] = status
        publish()
    }

    private func superviseTunnel(server: ServerConfig, tunnel: TunnelSpec) async {
        var attempt = 0
        while !Task.isCancelled {
            setTunnel(server.id, tunnel.id, TunnelStatus(phase: .starting, attempt: attempt))
            guard let process = await remote.launchTunnel(server: server, tunnel: tunnel) else {
                setTunnel(server.id, tunnel.id, TunnelStatus(phase: .failed(.launchFailed), attempt: attempt))
                finishTunnel(tunnel.id)
                return
            }
            if Task.isCancelled { process.terminate(); return }
            tunnelProcesses[tunnel.id] = process
            let startedAt = clock.now()
            let clock = clock
            let settleAttempt = attempt
            let settle = Task { [weak self] in
                do { try await clock.sleep(for: Self.tunnelSettleTime) } catch { return }
                guard !Task.isCancelled else { return }
                self?.tunnelSettled(server.id, tunnel.id, attempt: settleAttempt)
            }
            let result = await process.finished()
            settle.cancel()
            tunnelProcesses[tunnel.id] = nil
            if Task.isCancelled { return }
            let failure = SSHErrorClassifier.classify(result.errorOutput)
            if failure.isPermanent || result.outcome == .launchFailed {
                setTunnel(server.id, tunnel.id, TunnelStatus(phase: .failed(failure), attempt: attempt))
                finishTunnel(tunnel.id)
                return
            }
            if clock.now().timeIntervalSince(startedAt) >= Self.tunnelStableTime { attempt = 0 }
            let delay = Backoff.delay(afterAttempt: attempt)
            attempt += 1
            setTunnel(server.id, tunnel.id, TunnelStatus(phase: .waiting(clock.now().addingTimeInterval(delay)), attempt: attempt))
            do { try await clock.sleep(for: delay) } catch { return }
        }
    }

    private func tunnelSettled(_ serverID: UUID, _ tunnelID: UUID, attempt: Int) {
        guard tunnelProcesses[tunnelID] != nil else { return }
        setTunnel(serverID, tunnelID, TunnelStatus(phase: .running, attempt: attempt))
    }

    private func finishTunnel(_ id: UUID) {
        tunnelTasks[id] = nil
    }

    // MARK: Quitting

    /// Ends tunnels and shared connections. The app waits for this (with a cap) before it exits.
    public func shutdown() async {
        pollTask?.cancel()
        pollTask = nil
        mode = nil
        stopAllTunnels()
        await remote.shutdown(servers: config.servers)
        registry.terminateAll()
        await remote.clearTunnelRecords()
    }

    private func publish() {
        guard state != lastPublished else { return }
        lastPublished = state
        onChange?()
    }
}
