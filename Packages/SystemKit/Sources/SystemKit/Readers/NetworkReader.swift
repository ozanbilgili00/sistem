import Darwin
import Foundation

/// Throughput of one network interface over the last interval, bytes per second.
public struct NetworkInterfaceRate: Sendable, Equatable, Identifiable {
    public var name: String
    public var down: Double
    public var up: Double
    /// Bytes since the app started watching (the 32-bit kernel counters wrapped and
    /// summed into 64 bits).
    public var totalDown: UInt64
    public var totalUp: UInt64

    public var id: String { name }

    public init(name: String, down: Double, up: Double, totalDown: UInt64, totalUp: UInt64) {
        self.name = name
        self.down = down
        self.up = up
        self.totalDown = totalDown
        self.totalUp = totalUp
    }
}

public struct NetworkSample: Sendable, Equatable {
    /// Bytes per second over every real interface (loopback, tunnels and bridges
    /// excluded so nothing counts twice).
    public var down: Double
    public var up: Double
    public var totalDown: UInt64
    public var totalUp: UInt64
    /// Interfaces that are up, busiest first.
    public var interfaces: [NetworkInterfaceRate]
    /// Interface carrying the default route (from `NWPathMonitor`), if known.
    public var primary: String?

    public init(down: Double, up: Double, totalDown: UInt64, totalUp: UInt64, interfaces: [NetworkInterfaceRate],
                primary: String? = nil) {
        self.primary = primary
        self.down = down
        self.up = up
        self.totalDown = totalDown
        self.totalUp = totalUp
        self.interfaces = interfaces
    }

    public func interface(named name: String?) -> NetworkInterfaceRate? {
        name.flatMap { name in interfaces.first { $0.name == name } }
    }
}

/// An IPv4 or IPv6 address on one of the Mac's real interfaces.
public struct LocalAddress: Sendable, Equatable, Identifiable {
    public var interface: String
    public var address: String
    public var isIPv6: Bool

    public var id: String { "\(interface)/\(address)" }

    public init(interface: String, address: String, isIPv6: Bool) {
        self.interface = interface
        self.address = address
        self.isIPv6 = isIPv6
    }
}

/// Reads the per-interface byte counters of `getifaddrs` (AF_LINK `if_data`) and
/// turns two readings into rates.
///
/// `if_data` carries **32-bit** `ifi_ibytes`/`ifi_obytes`; they wrap every 4 GiB, so
/// the delta is taken modulo 2³² and accumulated into 64-bit totals. One call is a
/// few microseconds and allocates a list that is always freed.
///
/// Not thread-safe: confine to one executor.
public final class NetworkReader {
    private struct Counters {
        var down: UInt32
        var up: UInt32
        var totalDown: UInt64
        var totalUp: UInt64
    }

    private var previous: [String: Counters] = [:]
    private var lastSampleAt: ContinuousClock.Instant?

    public init() {}

    public func reset() {
        previous.removeAll(keepingCapacity: true)
        lastSampleAt = nil
    }

    public func sample() -> NetworkSample? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(first) }

        let now = ContinuousClock.now
        let elapsed = lastSampleAt.map { Self.seconds(now - $0) } ?? 0
        lastSampleAt = now

        var rates: [NetworkInterfaceRate] = []
        var seen: Set<String> = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.pointee.ifa_data,
                  Self.isCounted(flags: entry.pointee.ifa_flags, name: entry.pointee.ifa_name) else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            let current = (down: counters.ifi_ibytes, up: counters.ifi_obytes)
            seen.insert(name)

            var state = previous[name] ?? Counters(down: current.down, up: current.up, totalDown: 0, totalUp: 0)
            let isBaseline = previous[name] == nil
            let deltaDown = isBaseline ? 0 : Self.delta(from: state.down, to: current.down)
            let deltaUp = isBaseline ? 0 : Self.delta(from: state.up, to: current.up)
            state.down = current.down
            state.up = current.up
            state.totalDown += deltaDown
            state.totalUp += deltaUp
            previous[name] = state

            rates.append(NetworkInterfaceRate(
                name: name,
                down: elapsed > 0 ? Double(deltaDown) / elapsed : 0,
                up: elapsed > 0 ? Double(deltaUp) / elapsed : 0,
                totalDown: state.totalDown, totalUp: state.totalUp))
        }
        // An interface that vanished (USB adapter pulled) forgets its baseline, so
        // its return doesn't produce a bogus delta.
        if previous.count != seen.count { previous = previous.filter { seen.contains($0.key) } }

        rates.sort { ($0.down + $0.up, $1.name) > ($1.down + $1.up, $0.name) }
        return NetworkSample(
            down: rates.reduce(0) { $0 + $1.down }, up: rates.reduce(0) { $0 + $1.up },
            totalDown: rates.reduce(0) { $0 + $1.totalDown }, totalUp: rates.reduce(0) { $0 + $1.totalUp },
            interfaces: rates)
    }

    // MARK: Pure helpers

    /// Difference of two readings of a 32-bit counter. A smaller new value is either
    /// a wrap (the counter passed 2³²) or a reset (interface restarted); a wrap
    /// that implies more than 1 GiB in one interval (4 Gbit/s at the default 2 s)
    /// is far likelier to be a reset.
    static func delta(from old: UInt32, to new: UInt32) -> UInt64 {
        if new >= old { return UInt64(new - old) }
        let wrapped = (UInt64(1) << 32) - UInt64(old) + UInt64(new)
        return wrapped <= (UInt64(1) << 30) ? wrapped : UInt64(new)
    }

    /// Interfaces whose bytes are real traffic: up, not loopback, and not a tunnel,
    /// bridge or peer-to-peer link that carries (or duplicates) bytes already
    /// counted on a physical interface.
    static func isCounted(flags: UInt32, name: String) -> Bool {
        guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_LOOPBACK) == 0 else { return false }
        return !excludedPrefixes.contains { name.hasPrefix($0) }
    }

    private static func isCounted(flags: UInt32, name: UnsafePointer<CChar>) -> Bool {
        isCounted(flags: flags, name: String(cString: name))
    }

    private static let excludedPrefixes = ["lo", "utun", "awdl", "llw", "bridge", "ap", "anpi", "gif", "stf", "ipsec", "ppp"]

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    // MARK: Addresses

    /// Addresses worth showing: counted interfaces only, no link-local IPv6.
    public static func localAddresses() -> [LocalAddress] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(first) }
        var result: [LocalAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) || address.pointee.sa_family == UInt8(AF_INET6),
                  isCounted(flags: entry.pointee.ifa_flags, name: entry.pointee.ifa_name) else { continue }
            let isIPv6 = address.pointee.sa_family == UInt8(AF_INET6)
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            if isIPv6 && text.lowercased().hasPrefix("fe80") { continue }
            result.append(LocalAddress(interface: String(cString: entry.pointee.ifa_name), address: text, isIPv6: isIPv6))
        }
        return result.sorted { ($0.interface, $0.isIPv6 ? 1 : 0, $0.address) < ($1.interface, $1.isIPv6 ? 1 : 0, $1.address) }
    }
}
