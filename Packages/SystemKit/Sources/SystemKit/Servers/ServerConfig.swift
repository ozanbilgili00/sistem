import Foundation

/// What a server is, and so which fixed script reads it.
public enum ServerKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case linux, macOS, docker
    /// Docker on this Mac: no ssh, `docker stats` runs here.
    case localDocker

    public var id: String { rawValue }
    public var usesSSH: Bool { self != .localDocker }
}

/// A port forward that belongs to a server. Opened and closed by hand; never started on launch.
public struct TunnelSpec: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable, Identifiable {
        /// `-L`: a port on this Mac reaches a host seen from the server.
        case local
        /// `-R`: a port on the server reaches a host seen from this Mac.
        case remote
        /// `-D`: a SOCKS proxy on this Mac.
        case dynamic
        public var id: String { rawValue }
    }

    public var id: UUID
    public var kind: Kind
    /// local / dynamic: the port on this Mac (1024...65535). remote: the port on the server.
    public var listenPort: Int
    /// local: the target as the server sees it. remote: the target as this Mac sees it. dynamic: unused.
    public var targetHost: String
    public var targetPort: Int

    public init(id: UUID = UUID(), kind: Kind, listenPort: Int, targetHost: String = "127.0.0.1", targetPort: Int = 0) {
        self.id = id
        self.kind = kind
        self.listenPort = listenPort
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    /// The same tunnel with every value checked, or nil.
    public func validated() -> TunnelSpec? {
        switch kind {
        case .dynamic:
            guard (1_024...65_535).contains(listenPort) else { return nil }
            return TunnelSpec(id: id, kind: kind, listenPort: listenPort, targetHost: "", targetPort: 0)
        case .local, .remote:
            guard let host = ServerInput.host(targetHost), (1...65_535).contains(targetPort) else { return nil }
            guard kind == .remote ? (1...65_535).contains(listenPort) : (1_024...65_535).contains(listenPort) else { return nil }
            return TunnelSpec(id: id, kind: kind, listenPort: listenPort, targetHost: host, targetPort: targetPort)
        }
    }
}

/// One server in the user's list. Only host, user, port and kind are stored: there is no place for a secret in it.
public struct ServerConfig: Codable, Equatable, Identifiable, Sendable {
    public static let maxServers = 20
    public static let maxTunnels = 10

    public var id: UUID
    public var name: String
    public var kind: ServerKind
    /// Host name, IP address or `~/.ssh/config` alias. Empty for ``ServerKind/localDocker``.
    public var host: String
    public var user: String?
    public var port: Int?
    public var tunnels: [TunnelSpec]

    public init(id: UUID = UUID(), name: String, kind: ServerKind, host: String = "", user: String? = nil, port: Int? = nil,
                tunnels: [TunnelSpec] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.user = user
        self.port = port
        self.tunnels = tunnels
    }

    /// The same server with every field checked, or nil. Unusable tunnels are dropped, not repaired.
    public func validated() -> ServerConfig? {
        guard let name = ServerInput.displayName(name) else { return nil }
        var copy = self
        copy.name = name
        if kind.usesSSH {
            guard let host = ServerInput.host(host) else { return nil }
            copy.host = host
            if let user { guard let valid = ServerInput.user(user) else { return nil }; copy.user = valid }
            if let port { guard (1...65_535).contains(port) else { return nil }; copy.port = port }
        } else {
            copy.host = ""
            copy.user = nil
            copy.port = nil
            copy.tunnels = []
        }
        var seen = Set<UUID>()
        copy.tunnels = Array(tunnels.compactMap { $0.validated() }.filter { seen.insert($0.id).inserted }.prefix(Self.maxTunnels))
        return copy
    }

    /// What identifies the connection (not the label): a change means the old session is stale.
    var connectionKey: String { "\(kind.rawValue)|\(host)|\(user ?? "")|\(port ?? 0)" }

    /// The list as stored: JSON text. Short, so it can also be given on the command line for a measurement.
    public static func encode(_ servers: [ServerConfig]) -> String {
        guard let data = try? JSONEncoder().encode(servers) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Decodes a stored list: unreadable elements and invalid servers are dropped, ids stay unique, the count is capped.
    /// `dropped` counts what was refused (for the import line).
    public static func decode(_ text: String?) -> (servers: [ServerConfig], dropped: Int) {
        guard let text, text.utf8.count <= 256 * 1024, let data = text.data(using: .utf8),
              let elements = try? JSONDecoder().decode([Lossy].self, from: data) else { return ([], text == nil ? 0 : 1) }
        var result: [ServerConfig] = []
        var seen = Set<UUID>()
        var dropped = 0
        for element in elements {
            guard let server = element.server?.validated(), seen.insert(server.id).inserted, result.count < maxServers else {
                dropped += 1
                continue
            }
            result.append(server)
        }
        return (result, dropped)
    }

    private struct Lossy: Decodable {
        var server: ServerConfig?
        init(from decoder: Decoder) throws { server = try? ServerConfig(from: decoder) }
    }
}
