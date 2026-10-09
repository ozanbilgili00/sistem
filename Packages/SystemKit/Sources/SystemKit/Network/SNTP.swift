import Foundation
import Network

/// How far this Mac's clock is from a network time server. Run only when the user presses
/// the button (nothing contacts a time server on its own).
public struct ClockOffset: Sendable, Equatable {
    /// Seconds to add to this Mac's clock to get the server's time. Positive: the Mac is behind.
    public var offset: Double
    /// Seconds the exchange took.
    public var roundTrip: Double
    public var measuredAt: Date

    public init(offset: Double, roundTrip: Double, measuredAt: Date) {
        self.offset = offset
        self.roundTrip = roundTrip
        self.measuredAt = measuredAt
    }
}

/// A one-shot SNTP (RFC 4330) client: one 48-byte UDP packet out, one back.
public struct SNTPClient: Sendable {
    public static let host = "time.apple.com"
    public static let port: UInt16 = 123
    /// Seconds: the hard ceiling for the whole exchange (K-01).
    public static let timeout: TimeInterval = 5

    /// Seconds between the NTP era (1900) and the Unix epoch (1970).
    static let ntpEpochOffset: Double = 2_208_988_800

    public init() {}

    /// nil on any error, timeout or a reply that does not check out.
    public func measure() async -> ClockOffset? {
        await withCheckedContinuation { continuation in
            let once = Once(continuation)
            let connection = NWConnection(host: NWEndpoint.Host(Self.host), port: NWEndpoint.Port(rawValue: Self.port)!, using: .udp)
            let queue = DispatchQueue(label: "sistem.sntp", qos: .utility)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let sent = Date()
                    connection.send(content: Self.request(at: sent), completion: .contentProcessed { error in
                        if error != nil { once.finish(nil); connection.cancel() }
                    })
                    connection.receiveMessage { data, _, _, error in
                        let received = Date()
                        if error == nil, let data { once.finish(Self.parse(data, sent: sent, received: received)) } else { once.finish(nil) }
                        connection.cancel()
                    }
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

    // MARK: Packet

    /// Version 4, client mode, with our send time as the transmit timestamp (the server echoes it back).
    static func request(at date: Date) -> Data {
        var packet = [UInt8](repeating: 0, count: 48)
        packet[0] = 0b00_100_011
        packet.replaceSubrange(40..<48, with: timestamp(date))
        return Data(packet)
    }

    static func timestamp(_ date: Date) -> [UInt8] {
        let seconds = date.timeIntervalSince1970 + ntpEpochOffset
        let whole = UInt32(truncatingIfNeeded: Int64(seconds))
        let fraction = UInt32((seconds - seconds.rounded(.down)) * 4_294_967_296)
        return withUnsafeBytes(of: whole.bigEndian, Array.init) + withUnsafeBytes(of: fraction.bigEndian, Array.init)
    }

    static func seconds(in packet: [UInt8], at offset: Int) -> Double {
        let whole = packet[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let fraction = packet[offset + 4..<offset + 8].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return Double(whole) + Double(fraction) / 4_294_967_296 - ntpEpochOffset
    }

    /// θ = ((T2 − T1) + (T3 − T4)) / 2, δ = (T4 − T1) − (T3 − T2). Rejects a reply that is the wrong
    /// size or mode, from a server that says it is unsynchronised, or that does not echo our send time.
    static func parse(_ data: Data, sent: Date, received: Date) -> ClockOffset? {
        let packet = [UInt8](data)
        guard packet.count >= 48 else { return nil }
        let leap = packet[0] >> 6, version = (packet[0] >> 3) & 0b111, mode = packet[0] & 0b111
        guard leap != 3, (3...4).contains(version), mode == 4, (1...15).contains(packet[1]) else { return nil }
        // The server copies our transmit timestamp into "originate": a stray or forged reply won't match.
        guard Array(packet[24..<32]) == timestamp(sent) else { return nil }
        let t1 = sent.timeIntervalSince1970, t4 = received.timeIntervalSince1970
        let t2 = seconds(in: packet, at: 32), t3 = seconds(in: packet, at: 40)
        guard t2 > 0, t3 > 0 else { return nil }
        let offset = ((t2 - t1) + (t3 - t4)) / 2
        let roundTrip = (t4 - t1) - (t3 - t2)
        guard offset.isFinite, roundTrip.isFinite, abs(offset) < 86_400 * 365, roundTrip > -1, roundTrip < 30 else { return nil }
        return ClockOffset(offset: offset, roundTrip: max(0, roundTrip), measuredAt: received)
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ClockOffset?, Never>?
        init(_ continuation: CheckedContinuation<ClockOffset?, Never>) { self.continuation = continuation }
        func finish(_ value: ClockOffset?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }
}
