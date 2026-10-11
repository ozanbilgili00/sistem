import Darwin
import Foundation
import os

/// Why a server could not be read. The wording of ssh's error text never reaches the interface or a log;
/// it is reduced to one of these.
public enum RemoteFailure: Equatable, Sendable {
    /// Network down, no route, connection dropped, or an ssh error we do not recognise.
    case unreachable
    case refused
    case unresolved
    case timedOut
    /// The server did not accept the key (or the agent has none).
    case authRejected
    /// The server's key is not in `known_hosts`: connect once in Terminal.
    case hostKeyUnknown
    /// The key in `known_hosts` differs from the one the server presents.
    case hostKeyChanged
    case badOutput
    /// The remote command ran and failed.
    case commandFailed
    /// Docker is not installed (or not found) on that side.
    case toolMissing
    case launchFailed
    /// A tunnel's port could not be bound or forwarded.
    case forwardFailed

    /// A failure that says the server cannot be reached, as opposed to "reached but cannot be used".
    /// Only these count towards a "server is down" notification.
    public var isConnectivity: Bool {
        switch self {
        case .unreachable, .refused, .timedOut, .unresolved: true
        default: false
        }
    }

    /// A tunnel restart cannot fix these; only the user can (add the key, fix `known_hosts`, change the port).
    public var isPermanent: Bool {
        switch self {
        case .authRejected, .hostKeyUnknown, .hostKeyChanged, .forwardFailed, .launchFailed, .unresolved: true
        default: false
        }
    }
}

public enum SSHErrorClassifier {
    /// Reads ssh's standard error. Order matters: a changed key also says "Host key verification failed".
    public static func classify(_ stderr: Data) -> RemoteFailure {
        let text = String(decoding: stderr.prefix(8 * 1024), as: UTF8.self).lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { text.contains($0) } }
        if has("remote host identification has changed", "host key for", "offending") && has("changed", "offending") { return .hostKeyChanged }
        if has("host key verification failed", "no matching host key", "is known for", "host key is not known") { return .hostKeyUnknown }
        if has("permission denied", "too many authentication failures", "no supported authentication") { return .authRejected }
        if has("address already in use", "could not request local forwarding", "remote port forwarding failed",
               "cannot listen to port", "bind [") { return .forwardFailed }
        if has("could not resolve hostname", "nodename nor servname") { return .unresolved }
        if has("connection refused") { return .refused }
        if has("timed out", "timeout") { return .timedOut }
        return .unreachable
    }
}

public enum RemoteProbeResult: Equatable, Sendable {
    case reading(ServerReading)
    case failure(RemoteFailure)
}

/// All network work for servers: one actor apart from the sampler, so a slow or dead connection can never hold
/// up the readers of the rest of the app. Every call has a hard deadline on the injected clock; a call that
/// does not return by then is abandoned and its process killed.
public actor RemoteActor {
    /// The most any single call may take: ConnectTimeout (8 s) plus a little for the script.
    public static let deadline: TimeInterval = 10

    private let runner: any ProcessRunning
    private let clock: any ServerClock
    private let requestedEnvironment: SSHEnvironment
    private let dockerCandidates: [String]
    private var environment: SSHEnvironment?
    private let tunnelBook: TunnelRecordBook?
    private var calls = 0

    public init(runner: any ProcessRunning, clock: any ServerClock, environment: SSHEnvironment,
                dockerCandidates: [String] = RemoteActor.defaultDockerPaths, tunnelRecordDirectory: String? = nil) {
        tunnelBook = tunnelRecordDirectory.map { TunnelRecordBook(directory: $0) }
        self.runner = runner
        self.clock = clock
        requestedEnvironment = environment
        self.dockerCandidates = dockerCandidates
    }

    public static var defaultDockerPaths: [String] {
        let home = NSHomeDirectory()
        return ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker",
                "\(home)/.orbstack/bin/docker"]
    }

    /// How many calls reached this actor. Tests use it to show that a closed page does no work.
    public var callCount: Int { calls }

    // MARK: Reading a server

    public func probe(_ server: ServerConfig) async -> RemoteProbeResult {
        calls += 1
        if server.kind == .localDocker { return await probeLocalDocker() }
        let environment = prepareEnvironment()
        let request = ProcessRequest(
            executable: environment.executable,
            arguments: SSHCommand.scriptArguments(server: server, environment: environment),
            environment: SSHCommand.environment(),
            input: Data(ServerScripts.script(for: server.kind).utf8),
            timeout: Self.deadline)
        let runner = runner
        guard let result = await withDeadline(Self.deadline, clock: clock, { await runner.run(request) }) else { return .failure(.timedOut) }
        switch result.outcome {
        case .timedOut, .cancelled: return .failure(.timedOut)
        case .launchFailed: return .failure(.launchFailed)
        case .outputTooLarge: return .failure(.badOutput)
        case .exited(let status):
            if status == 255 { return .failure(SSHErrorClassifier.classify(result.errorOutput)) }
            guard status == 0 else { return .failure(.commandFailed) }
            switch ServerReadingParser.parse(result.output, expecting: server.kind) {
            case .reading(let reading): return .reading(reading)
            case .toolMissing: return .failure(.toolMissing)
            case .invalid: return .failure(.badOutput)
            }
        }
    }

    private func probeLocalDocker() async -> RemoteProbeResult {
        guard let docker = dockerCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return .failure(.toolMissing) }
        let request = ProcessRequest(executable: docker, arguments: ["stats", "--no-stream", "--format", ServerScripts.dockerFormat],
                                     environment: ["LC_ALL": "C", "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()], timeout: Self.deadline)
        let runner = runner
        guard let result = await withDeadline(Self.deadline, clock: clock, { await runner.run(request) }) else { return .failure(.timedOut) }
        guard case .exited(0) = result.outcome else {
            switch result.outcome {
            case .launchFailed: return .failure(.launchFailed)
            case .timedOut, .cancelled: return .failure(.timedOut)
            case .outputTooLarge: return .failure(.badOutput)
            default: return .failure(.commandFailed)
            }
        }
        let text = "SISTEM1 docker\n" + String(decoding: result.output.prefix(ServerReadingParser.sizeLimit), as: UTF8.self) + "\nEND\n"
        switch ServerReadingParser.parse(Data(text.utf8), expecting: .localDocker) {
        case .reading(let reading): return .reading(reading)
        default: return .failure(.badOutput)
        }
    }

    /// "Does it answer": nil = yes, else why not. No script, no data kept.
    public func reachability(_ server: ServerConfig) async -> RemoteFailure? {
        calls += 1
        guard server.kind.usesSSH else { return nil }
        let environment = prepareEnvironment()
        let request = ProcessRequest(
            executable: environment.executable,
            arguments: SSHCommand.reachabilityArguments(server: server, environment: environment),
            environment: SSHCommand.environment(), timeout: Self.deadline, outputLimit: 1024)
        let runner = runner
        guard let result = await withDeadline(Self.deadline, clock: clock, { await runner.run(request) }) else { return .timedOut }
        switch result.outcome {
        case .exited(0): return nil
        case .exited(255): return SSHErrorClassifier.classify(result.errorOutput)
        case .exited: return .commandFailed
        case .launchFailed: return .launchFailed
        default: return .timedOut
        }
    }

    // MARK: Connection sharing

    /// The environment with a checked control directory (created at the first call that needs it, never at launch).
    func prepareEnvironment() -> SSHEnvironment {
        if let environment { return environment }
        var prepared = requestedEnvironment
        if let requested = requestedEnvironment.controlDirectory {
            prepared.controlDirectory = Self.prepareDirectory(requested) ? requested : nil
        }
        environment = prepared
        return prepared
    }

    /// Creates the directory with mode 0700 if it is missing and accepts it only if it is a real directory
    /// (not a link) that belongs to us and nobody else can enter. Leftover sockets of an earlier run are removed.
    static func prepareDirectory(_ path: String) -> Bool {
        let manager = FileManager.default
        if !manager.fileExists(atPath: path) {
            guard (try? manager.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil else { return false }
        }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { return false }
        if info.st_mode & 0o077 != 0 { guard chmod(path, 0o700) == 0 else { return false } }
        for name in (try? manager.contentsOfDirectory(atPath: path)) ?? [] { try? manager.removeItem(atPath: path + "/" + name) }
        return true
    }

    /// Ends the shared connections and removes their sockets. Called when the app quits.
    public func shutdown(servers: [ServerConfig]) async {
        guard let environment else { return }
        let runner = runner
        for server in servers where server.kind.usesSSH {
            guard let arguments = SSHCommand.exitMasterArguments(server: server, environment: environment),
                  let path = SSHCommand.controlPath(for: server, in: environment), FileManager.default.fileExists(atPath: path) else { continue }
            let request = ProcessRequest(executable: environment.executable, arguments: arguments,
                                         environment: SSHCommand.environment(), timeout: 2, outputLimit: 1024)
            _ = await withDeadline(2, clock: clock, { await runner.run(request) })
            try? FileManager.default.removeItem(atPath: path)
        }
        if let directory = environment.controlDirectory {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] {
                try? FileManager.default.removeItem(atPath: directory + "/" + name)
            }
        }
    }

    /// Opens a long-lived tunnel process. nil if it could not start.
    public func launchTunnel(server: ServerConfig, tunnel: TunnelSpec) -> RunningProcess? {
        let environment = prepareEnvironment()
        guard let arguments = SSHCommand.tunnelArguments(server: server, tunnel: tunnel, environment: environment) else { return nil }
        let request = ProcessRequest(executable: environment.executable, arguments: arguments,
                                     environment: SSHCommand.environment(), timeout: 365 * 24 * 3600, outputLimit: 1024)
        guard let process = runner.launch(request) else { return nil }
        // Written down for the next launch, in case this app is killed before it can end the tunnel.
        guard let book = tunnelBook else { return process }
        book.add(pid: process.processIdentifier)
        return RecordedProcess(process: process, book: book)
    }

    /// Forgets the records once the tunnels have been ended.
    public func clearTunnelRecords() { tunnelBook?.removeAll() }
}

/// A tunnel process that removes its own record when it has ended.
private struct RecordedProcess: RunningProcess {
    let process: RunningProcess
    let book: TunnelRecordBook

    var processIdentifier: Int32 { process.processIdentifier }
    func terminate() { process.terminate() }
    func finished() async -> ProcessResult {
        let result = await process.finished()
        book.remove(pid: process.processIdentifier)
        return result
    }
}
