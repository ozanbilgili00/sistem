import Foundation

/// Where `ssh` lives and what it may be told besides the fixed options. Tests point `configFile` at a
/// throw-away file; the app leaves it nil and so uses the user's own `~/.ssh/config`.
public struct SSHEnvironment: Sendable, Equatable {
    public var executable = "/usr/bin/ssh"
    public var configFile: String?
    /// Own 0700 directory for ControlMaster sockets; nil = no connection sharing.
    public var controlDirectory: String?

    public init(executable: String = "/usr/bin/ssh", configFile: String? = nil, controlDirectory: String? = nil) {
        self.executable = executable
        self.configFile = configFile
        self.controlDirectory = controlDirectory
    }
}

/// The argument lists. Pure functions: nothing is executed here and nothing is interpolated into a string
/// that a shell would read. The host is always the first thing after `--`, so no value can become an option.
public enum SSHCommand {
    public static let connectTimeout = 8
    /// ControlMaster sockets stay this many seconds after the last use, so closing the page lets the connection go by itself.
    public static let controlPersist = 30
    /// `sun_path` holds 104 bytes; ssh adds a 17 character suffix while it creates the socket.
    static let socketPathLimit = 104 - 18

    /// Options every call carries. They are on the command line, so they win over the user's config file:
    /// no prompt of any kind (`BatchMode`), keys only, and the host key must already be known.
    static func fixedOptions(_ environment: SSHEnvironment) -> [String] {
        var arguments: [String] = []
        if let config = environment.configFile { arguments += ["-F", config] }
        let options = [
            "BatchMode=yes",
            "PasswordAuthentication=no",
            "KbdInteractiveAuthentication=no",
            "PreferredAuthentications=publickey",
            "NumberOfPasswordPrompts=0",
            "StrictHostKeyChecking=yes",
            // Even a known server must not make ssh add new key types to known_hosts: this app never writes that file.
            "UpdateHostKeys=no",
            "ConnectTimeout=\(connectTimeout)",
            "ConnectionAttempts=1",
            "ServerAliveInterval=5",
            "ServerAliveCountMax=2",
            "ForwardAgent=no",
            "ForwardX11=no",
            "PermitLocalCommand=no",
            "RequestTTY=no",
            "RemoteCommand=none",
            "LogLevel=ERROR",
        ]
        for option in options { arguments += ["-o", option] }
        return arguments
    }

    static func targetOptions(_ server: ServerConfig) -> [String] {
        var arguments: [String] = []
        if let user = server.user { arguments += ["-l", user] }
        if let port = server.port { arguments += ["-p", String(port)] }
        return arguments
    }

    /// The socket of a server, or nil when the path would not fit (the call then simply uses its own connection).
    public static func controlPath(for server: ServerConfig, in environment: SSHEnvironment) -> String? {
        guard let directory = environment.controlDirectory else { return nil }
        let path = directory + "/" + socketName(for: server.id)
        guard path.utf8.count <= socketPathLimit, !path.contains("%"), !path.contains("\""), !path.contains("\\") else { return nil }
        return path
    }

    /// Eight hex digits of the server's id: short, unique enough for a list of twenty, and no host name in a file name.
    public static func socketName(for id: UUID) -> String {
        String(id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
    }

    private static func controlOptions(path: String?) -> [String] {
        guard let path else { return ["-o", "ControlMaster=no", "-o", "ControlPath=none"] }
        // Quoted: ssh reads `-o` like a config line, and a path may hold spaces.
        return ["-o", "ControlMaster=auto", "-o", "ControlPath=\"\(path)\"", "-o", "ControlPersist=\(controlPersist)"]
    }

    /// Runs the fixed script given on standard input through `sh -s`. The reply is the script's output.
    public static func scriptArguments(server: ServerConfig, environment: SSHEnvironment) -> [String] {
        fixedOptions(environment) + ["-o", "ClearAllForwardings=yes", "-T"]
            + controlOptions(path: controlPath(for: server, in: environment))
            + targetOptions(server) + ["--", server.host, "sh -s"]
    }

    /// `ssh … -- host true`: only "does it answer". Shares the connection like the script does.
    public static func reachabilityArguments(server: ServerConfig, environment: SSHEnvironment) -> [String] {
        fixedOptions(environment) + ["-o", "ClearAllForwardings=yes", "-T"]
            + controlOptions(path: controlPath(for: server, in: environment))
            + targetOptions(server) + ["--", server.host, "true"]
    }

    /// Closes the shared connection of a server, if there is one.
    public static func exitMasterArguments(server: ServerConfig, environment: SSHEnvironment) -> [String]? {
        guard let path = controlPath(for: server, in: environment) else { return nil }
        var arguments: [String] = []
        if let config = environment.configFile { arguments += ["-F", config] }
        arguments += ["-o", "ControlPath=\"\(path)\"", "-O", "exit"] + targetOptions(server) + ["--", server.host]
        return arguments
    }

    /// A tunnel: its own connection (no sharing), no remote command, and it ends if the forward cannot be set up.
    public static func tunnelArguments(server: ServerConfig, tunnel: TunnelSpec, environment: SSHEnvironment) -> [String]? {
        guard let tunnel = tunnel.validated() else { return nil }
        let forward: [String]
        switch tunnel.kind {
        case .local:
            forward = ["-L", "127.0.0.1:\(tunnel.listenPort):\(ServerInput.bracketed(tunnel.targetHost)):\(tunnel.targetPort)"]
        case .remote:
            forward = ["-R", "127.0.0.1:\(tunnel.listenPort):\(ServerInput.bracketed(tunnel.targetHost)):\(tunnel.targetPort)"]
        case .dynamic:
            forward = ["-D", "127.0.0.1:\(tunnel.listenPort)"]
        }
        return fixedOptions(environment) + ["-o", "ExitOnForwardFailure=yes", "-N", "-T"] + controlOptions(path: nil)
            + targetOptions(server) + forward + ["--", server.host]
    }

    /// What Terminal runs for "Quick connect": plain `ssh`, user's config, the host after `--`.
    public static func interactiveArguments(server: ServerConfig) -> [String] {
        targetOptions(server) + ["--", server.host]
    }

    /// The environment ssh gets: its own small one. The agent socket stays (key login), everything else goes —
    /// in particular no `SSH_ASKPASS` / `DISPLAY`, which could turn a refused key into a password dialog.
    public static func environment(from source: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = ["LC_ALL": "C", "PATH": "/usr/bin:/bin"]
        for key in ["HOME", "USER", "LOGNAME", "SSH_AUTH_SOCK"] { if let value = source[key] { result[key] = value } }
        return result
    }
}
