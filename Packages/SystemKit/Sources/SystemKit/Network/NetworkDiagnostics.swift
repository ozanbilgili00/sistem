import Darwin
import Foundation
import Network
import os

public enum DiagnosticTool: String, CaseIterable, Identifiable, Sendable {
    case ping, dns, port, traceroute
    public var id: String { rawValue }
}

public struct PingResult: Equatable, Sendable {
    public var sent: Int
    public var received: Int
    public var minimum: Double?
    public var average: Double?
    public var maximum: Double?
    public init(sent: Int, received: Int, minimum: Double? = nil, average: Double? = nil, maximum: Double? = nil) {
        self.sent = sent
        self.received = received
        self.minimum = minimum
        self.average = average
        self.maximum = maximum
    }

    public var lossPercent: Double { sent > 0 ? Double(sent - received) / Double(sent) * 100 : 100 }
}

public struct DNSResult: Equatable, Sendable {
    public var addresses: [String]
    public init(addresses: [String]) { self.addresses = addresses }
}

public struct PortResult: Equatable, Sendable {
    public enum State: Equatable, Sendable { case open, refused, timedOut }
    public var state: State
    public var milliseconds: Double?
    public init(state: State, milliseconds: Double?) {
        self.state = state
        self.milliseconds = milliseconds
    }
}

public struct TraceHop: Equatable, Sendable, Identifiable {
    public var index: Int
    /// nil = no answer (`* * *`).
    public var address: String?
    public var milliseconds: Double?
    public var id: Int { index }
    public init(index: Int, address: String?, milliseconds: Double?) {
        self.index = index
        self.address = address
        self.milliseconds = milliseconds
    }
}

public struct TraceResult: Equatable, Sendable {
    public var hops: [TraceHop]
    public init(hops: [TraceHop]) { self.hops = hops }
}

public enum DiagnosticFailure: Equatable, Sendable {
    case invalidInput
    case timedOut
    case toolMissing
    case noAnswer
    case cancelled
    case badOutput
}

public enum DiagnosticOutcome: Equatable, Sendable {
    case ping(PingResult)
    case dns(DNSResult)
    case port(PortResult)
    case traceroute(TraceResult)
    case failed(DiagnosticFailure)
}

public protocol HostResolving: Sendable {
    /// Addresses (numeric text) or nil when the name does not resolve.
    func resolve(_ host: String) async -> [String]?
}

public protocol PortProbing: Sendable {
    func probe(host: String, port: Int, timeout: TimeInterval) async -> PortResult
}

/// ping, DNS lookup, TCP port check and traceroute. Only ever run by a button press: nothing here starts by itself,
/// and nothing is repeated. The host is validated like every other host (``ServerInput/host(_:)``), the programs are
/// system tools given as absolute paths with a fixed argument list and `--` in front of the host.
public struct NetworkDiagnostics: Sendable {
    public static let pingTimeout: TimeInterval = 15
    public static let dnsTimeout: TimeInterval = 5
    public static let portTimeout: TimeInterval = 5
    public static let tracerouteTimeout: TimeInterval = 40

    private let runner: any ProcessRunning
    private let resolver: any HostResolving
    private let prober: any PortProbing
    private let clock: any ServerClock

    public init(runner: any ProcessRunning = SystemProcessRunner(), resolver: any HostResolving = SystemHostResolver(),
                prober: any PortProbing = SystemPortProber(), clock: any ServerClock = SystemServerClock()) {
        self.runner = runner
        self.resolver = resolver
        self.prober = prober
        self.clock = clock
    }

    public func run(_ tool: DiagnosticTool, host rawHost: String, port rawPort: String = "") async -> DiagnosticOutcome {
        guard let host = ServerInput.host(rawHost) else { return .failed(.invalidInput) }
        switch tool {
        case .ping:
            return await ping(host)
        case .dns:
            let resolver = resolver
            guard let addresses = await withDeadline(Self.dnsTimeout, clock: clock, { await resolver.resolve(host) }) else { return .failed(.timedOut) }
            guard let addresses, !addresses.isEmpty else { return .failed(.noAnswer) }
            return .dns(DNSResult(addresses: Array(addresses.prefix(32))))
        case .port:
            guard let port = ServerInput.port(rawPort) else { return .failed(.invalidInput) }
            let prober = prober
            guard let result = await withDeadline(Self.portTimeout + 1, clock: clock, { await prober.probe(host: host, port: port, timeout: Self.portTimeout) }) else {
                return .failed(.timedOut)
            }
            return .port(result)
        case .traceroute:
            return await traceroute(host)
        }
    }

    // MARK: ping

    static func pingRequest(host: String) -> ProcessRequest {
        let v6 = host.contains(":")
        return ProcessRequest(executable: v6 ? "/sbin/ping6" : "/sbin/ping",
                              arguments: v6 ? ["-c", "4", "-n", "--", host] : ["-c", "4", "-n", "-W", "2000", "-t", "10", "--", host],
                              environment: ["LC_ALL": "C"], timeout: pingTimeout, outputLimit: 16 * 1024)
    }

    private func ping(_ host: String) async -> DiagnosticOutcome {
        let request = Self.pingRequest(host: host)
        let runner = runner
        guard let result = await withDeadline(request.timeout + 1, clock: clock, { await runner.run(request) }) else { return .failed(.timedOut) }
        switch result.outcome {
        case .launchFailed: return .failed(.toolMissing)
        case .timedOut: return .failed(.timedOut)
        case .cancelled: return .failed(.cancelled)
        case .outputTooLarge: return .failed(.badOutput)
        case .exited:
            // Exit status 2 = no reply at all; the summary line is still there and says "0 packets received".
            guard let parsed = Self.parsePing(String(decoding: result.output, as: UTF8.self)) else {
                return .failed(result.exitStatus == 68 ? .noAnswer : .badOutput)
            }
            return .ping(parsed)
        }
    }

    /// "4 packets transmitted, 4 packets received, 0.0% packet loss" and "round-trip min/avg/max/stddev = a/b/c/d ms".
    static func parsePing(_ text: String) -> PingResult? {
        var sent: Int?
        var received: Int?
        var times: [Double] = []
        for line in text.split(separator: "\n").prefix(200) {
            if line.contains("packets transmitted") {
                let numbers = line.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                if numbers.count >= 2, numbers[0] <= 1000, numbers[1] <= numbers[0] { sent = numbers[0]; received = numbers[1] }
            } else if line.hasPrefix("round-trip"), let equals = line.firstIndex(of: "=") {
                let values = line[line.index(after: equals)...].replacingOccurrences(of: "ms", with: "")
                    .split(separator: "/").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if values.count >= 3, values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < 1e7 }) { times = values }
            }
        }
        guard let sent, let received else { return nil }
        return PingResult(sent: sent, received: received, minimum: times.first, average: times.count > 1 ? times[1] : nil,
                          maximum: times.count > 2 ? times[2] : nil)
    }

    // MARK: traceroute

    static func tracerouteRequest(host: String) -> ProcessRequest {
        let v6 = host.contains(":")
        return ProcessRequest(executable: v6 ? "/usr/sbin/traceroute6" : "/usr/sbin/traceroute",
                              arguments: ["-n", "-q", "1", "-w", "2", "-m", "15", "--", host],
                              environment: ["LC_ALL": "C"], timeout: tracerouteTimeout, outputLimit: 16 * 1024)
    }

    private func traceroute(_ host: String) async -> DiagnosticOutcome {
        let request = Self.tracerouteRequest(host: host)
        let runner = runner
        guard let result = await withDeadline(request.timeout + 1, clock: clock, { await runner.run(request) }) else { return .failed(.timedOut) }
        switch result.outcome {
        case .launchFailed: return .failed(.toolMissing)
        case .cancelled: return .failed(.cancelled)
        case .outputTooLarge: return .failed(.badOutput)
        case .timedOut, .exited:
            let hops = Self.parseTraceroute(String(decoding: result.output, as: UTF8.self))
            if hops.isEmpty { return .failed(result.outcome == .timedOut ? .timedOut : .badOutput) }
            return .traceroute(TraceResult(hops: hops))
        }
    }

    /// " 3  10.0.0.1  4.2 ms" or " 4  *". The first line ("traceroute to …") has no leading hop number and is skipped.
    static func parseTraceroute(_ text: String) -> [TraceHop] {
        var hops: [TraceHop] = []
        for line in text.split(separator: "\n").prefix(64) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let first = fields.first, let index = Int(first), (1...64).contains(index), fields.count >= 2 else { continue }
            if fields[1] == "*" {
                hops.append(TraceHop(index: index, address: nil, milliseconds: nil))
                continue
            }
            let address = String(fields[1])
            guard address.count <= 45, address.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == ":" }) else { continue }
            let time = fields.count >= 3 ? Double(fields[2]) : nil
            hops.append(TraceHop(index: index, address: address, milliseconds: time.flatMap { $0.isFinite && $0 >= 0 && $0 < 1e7 ? $0 : nil }))
        }
        return hops
    }
}

/// `getaddrinfo`: what every app on the Mac sees, including `/etc/hosts` (so `localhost` never leaves the machine).
public struct SystemHostResolver: HostResolving {
    public init() {}

    public func resolve(_ host: String) async -> [String]? {
        await withCheckedContinuation { continuation in
            // getaddrinfo cannot be interrupted; the deadline above abandons the wait, this thread ends when the call returns.
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                var list: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else {
                    continuation.resume(returning: nil)
                    return
                }
                defer { freeaddrinfo(list) }
                var seen = Set<String>()
                var addresses: [String] = []
                var cursor: UnsafeMutablePointer<addrinfo>? = first
                while let info = cursor {
                    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        if seen.insert(text).inserted { addresses.append(text) }
                    }
                    cursor = info.pointee.ai_next
                }
                continuation.resume(returning: addresses)
            }
        }
    }
}

/// A TCP connect through Network.framework. For an address on the local network the system asks for the Local
/// Network permission the first time; that only happens here, after the user pressed the button.
public struct SystemPortProber: PortProbing {
    public init() {}

    public func probe(host: String, port: Int, timeout: TimeInterval) async -> PortResult {
        guard let number = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return PortResult(state: .refused, milliseconds: nil) }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: number, using: .tcp)
            let gate = OSAllocatedUnfairLock(initialState: false)
            let started = ContinuousClock.now
            @Sendable func finish(_ state: PortResult.State) {
                let first = gate.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                guard first else { return }
                let elapsed = started.duration(to: .now)
                let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
                connection.cancel()
                continuation.resume(returning: PortResult(state: state, milliseconds: state == .open ? milliseconds : nil))
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.open)
                case .failed: finish(.refused)
                case .waiting(let error):
                    if case .posix(let code) = error, code == .ECONNREFUSED { finish(.refused) }
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { finish(.timedOut) }
        }
    }
}
