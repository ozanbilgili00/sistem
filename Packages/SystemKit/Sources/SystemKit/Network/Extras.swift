import Darwin
import Foundation
import Network

/// Outcome of the optional public-IP lookup. Off by default: nothing is requested
/// until the user turns it on.
public enum PublicIPState: Sendable, Equatable {
    case off
    case fetching
    case address(String, Date)
    case failed
}

/// Outcome of the optional latency probe.
public enum LatencyState: Sendable, Equatable {
    case off
    case measured(milliseconds: Double, Date)
    case failed(Date)
}

/// Looks up this Mac's public address. Called only on a connectivity change, only
/// when the user enabled it.
public struct PublicIPClient: Sendable {
    public static let endpoint = URL(string: "https://api.ipify.org")!
    /// Seconds: the hard ceiling for the whole request (K-01).
    public static let timeout: TimeInterval = 5

    public init() {}

    /// Ephemeral (no cookies, no disk cache), no waiting for connectivity, and an
    /// explicit timeout for both the request and the resource.
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return configuration
    }

    static func request() -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpShouldHandleCookies = false
        return request
    }

    /// nil on any error, timeout, bad status or a body that isn't an IP address.
    /// A session passed in (tests) is left alone; one made here is invalidated.
    public func fetch(session: URLSession? = nil) async -> String? {
        let own = session == nil ? URLSession(configuration: Self.configuration()) : nil
        defer { own?.finishTasksAndInvalidate() }
        guard let used = session ?? own, let (data, response) = try? await used.data(for: Self.request()) else { return nil }
        return Self.parse(data: data, response: response)
    }

    static func parse(data: Data, response: URLResponse) -> String? {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 64,
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              isIPAddress(text) else { return nil }
        return text
    }

    static func isIPAddress(_ text: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, text, &v4) == 1 || inet_pton(AF_INET6, text, &v6) == 1
    }
}

/// Round-trip estimate: how long a TCP handshake with a well-connected anycast
/// address takes. Run every 60 s while enabled and visible, never on battery.
public struct LatencyProbe: Sendable {
    public static let host = "1.1.1.1"
    public static let port: UInt16 = 443
    public static let timeout: TimeInterval = 5

    public init() {}

    /// Milliseconds to establish the connection, or nil on failure or timeout.
    public func measure() async -> Double? {
        await withCheckedContinuation { continuation in
            let once = Once(continuation)
            let connection = NWConnection(host: NWEndpoint.Host(Self.host), port: NWEndpoint.Port(rawValue: Self.port)!, using: .tcp)
            let queue = DispatchQueue(label: "sistem.latency", qos: .utility)
            let started = ContinuousClock.now
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let parts = (ContinuousClock.now - started).components
                    once.finish(Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15)
                    connection.cancel()
                case .failed, .cancelled:
                    once.finish(nil)
                    connection.cancel()
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + Self.timeout) {
                once.finish(nil)
                connection.cancel()
            }
            connection.start(queue: queue)
        }
    }

    /// Resumes a continuation exactly once, whichever of ready, failed or the timeout comes first.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Double?, Never>?
        init(_ continuation: CheckedContinuation<Double?, Never>) { self.continuation = continuation }
        func finish(_ value: Double?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }
}
