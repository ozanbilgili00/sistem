import AppKit
import Observation
import SwiftUI
import SystemKit

/// The app's view of the servers: wraps the controller and mirrors its state for SwiftUI.
/// With the module off, or on with nothing listed, nothing runs. Pages and popovers say when they are visible.
@Observable
final class ServersModel {
    private(set) var state = ServersState()
    /// "Quick connect" could not open the file (shown once, next to the list).
    private(set) var quickConnectFailed = false
    /// Aliases from `~/.ssh/config`, read when the page asks (never at launch).
    private(set) var aliases: [String] = []

    @ObservationIgnored private let controller: ServersController?
    @ObservationIgnored private var visibleCount = 0
    @ObservationIgnored private var pause: PauseMonitor?
    @ObservationIgnored private let commandDirectory: String
    @ObservationIgnored var onServerDown: (ServerConfig) -> Void = { _ in }

    /// `controller` nil = a frozen preview (snapshots): nothing is created, nothing touched.
    @MainActor
    init(controller: ServersController? = nil, live: Bool = true) {
        commandDirectory = NSHomeDirectory() + "/Library/Caches/com.ozan.sistem/terminal"
        if let controller {
            self.controller = controller
        } else if live {
            let environment = SSHEnvironment(controlDirectory: NSHomeDirectory() + "/Library/Caches/com.ozan.sistem/ssh")
            // Tunnels an earlier run left behind (it was killed) are ended first: one stat call when there is nothing to end.
            let tunnelDirectory = NSHomeDirectory() + "/Library/Caches/com.ozan.sistem/tunnels"
            TunnelReaper.reapOrphans(directory: tunnelDirectory)
            let remote = RemoteActor(runner: SystemProcessRunner(), clock: SystemServerClock(), environment: environment,
                                     tunnelRecordDirectory: tunnelDirectory)
            self.controller = ServersController(remote: remote, clock: SystemServerClock())
        } else {
            self.controller = nil
        }
        self.controller?.onChange = { [weak self] in self?.sync() }
        self.controller?.onServerDown = { [weak self] server in self?.onServerDown(server) }
    }

    #if DEBUG
    init(previewing state: ServersState, aliases: [String] = []) {
        controller = nil
        commandDirectory = NSTemporaryDirectory()
        self.state = state
        self.aliases = aliases
    }
    #endif

    @MainActor
    func apply(_ config: ServersConfig) {
        guard let controller else { return }
        controller.apply(config)
        // Sleep and lock pause polling; the monitor exists only while there is something to poll.
        if config.enabled, !config.servers.isEmpty, pause == nil {
            let monitor = PauseMonitor()
            monitor.onChange = { [weak self, weak monitor] in
                guard let monitor else { return }
                self?.controller?.setPaused(!monitor.reasons.isEmpty)
            }
            pause = monitor
        } else if !(config.enabled && !config.servers.isEmpty) {
            pause = nil
            controller.setPaused(false)
        }
        sync()
    }

    @MainActor
    func viewAppeared() {
        visibleCount += 1
        if visibleCount == 1 { controller?.setVisible(true) }
    }

    @MainActor
    func viewDisappeared() {
        visibleCount = max(0, visibleCount - 1)
        if visibleCount == 0 { controller?.setVisible(false) }
    }

    @MainActor func startTunnel(_ server: UUID, _ tunnel: UUID) { controller?.startTunnel(server: server, tunnel: tunnel) }
    @MainActor func stopTunnel(_ tunnel: UUID) { controller?.stopTunnel(tunnel) }

    /// Reads `~/.ssh/config` (read-only, aliases only). Only when the user opens the list.
    @MainActor
    func loadAliases() {
        aliases = SSHConfigReader.aliases()
    }

    /// Hands a validated `ssh` command to Terminal.app through a private `.command` file (see ``QuickConnect``).
    /// Opens Terminal only on the user's click.
    @MainActor
    func connect(host: String, user: String? = nil, port: Int? = nil) {
        guard let path = QuickConnect.writeCommandFile(host: host, user: user, port: port, in: commandDirectory),
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            quickConnectFailed = true
            return
        }
        quickConnectFailed = false
        NSWorkspace.shared.open([URL(filePath: path)], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Quitting: tunnels and shared connections end, files for Terminal are removed. The caller waits at most a few seconds.
    @MainActor
    func shutdown() async {
        await controller?.shutdown()
        QuickConnect.removeFiles(in: commandDirectory)
    }

    /// Makes sure the quit reply is sent once, whichever of shutdown and the time limit finishes first.
    final class TerminationGate: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func fire() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if fired { return false }
            fired = true
            return true
        }
    }

    @MainActor
    private func sync() {
        guard let controller else { return }
        if controller.state != state { state = controller.state }
    }
}
