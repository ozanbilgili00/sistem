import Foundation

/// DDC/CI framing for the I2C channel (VESA DDC/CI + MCCS). Pure functions; the transfers are done elsewhere.
///
/// The framing is the one m1ddc and MonitorControl (both MIT) document: chip 0x37, data
/// address 0x51, a length byte `0x80 | payloadLength`, the payload, and an XOR checksum seeded
/// with the destination (0x6E) and the data address (0x51).
public enum DDCPacket {
    public static let chip: UInt32 = 0x37
    public static let dataAddress: UInt32 = 0x51
    /// Length of the reply to a "get VCP" request.
    public static let replyLength = 12

    static let destination: UInt8 = 0x6E
    static let dataByte: UInt8 = 0x51

    static func checksum(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(destination ^ dataByte, ^)
    }

    /// "Set VCP feature": 0x84 0x03 code hi lo checksum.
    public static func setRequest(code: UInt8, value: UInt16) -> [UInt8] {
        let body: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)]
        return body + [checksum(body)]
    }

    /// "Get VCP feature": 0x82 0x01 code checksum.
    public static func getRequest(code: UInt8) -> [UInt8] {
        let body: [UInt8] = [0x82, 0x01, code]
        return body + [checksum(body)]
    }

    /// The value in a "get VCP" reply, or nil when the reply is short, its checksum is wrong,
    /// it answers another feature, reports an error (result code not 0) or is not a feature reply at all.
    ///
    /// Reply layout: source, length (0x88), opcode (0x02), result, code, type, max hi, max lo, current hi, current lo,
    /// checksum = 0x50 ^ every byte before it (the form MonitorControl checks; confirmed read-only on a real
    /// monitor 2026-10-11). The bus read returns 12 bytes; the twelfth is padding and not part of the frame.
    public static func parseReply(_ reply: [UInt8], code: UInt8) -> VCPValue? {
        guard reply.count >= 11, reply[0..<10].reduce(0x50, ^) == reply[10], reply[2] == 0x02, reply[3] == 0x00, reply[4] == code else { return nil }
        let maximum = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        return VCPValue(current: current, maximum: maximum)
    }
}

/// A DDC channel to one monitor. Calls block for tens of milliseconds (the monitor needs time
/// between request and reply), so they run on a worker queue, never on the main thread.
public protocol DDCTransport: Sendable {
    func read(_ code: UInt8) -> VCPValue?
    /// true when the transfer was accepted by the bus (monitors do not acknowledge the value itself).
    func write(_ code: UInt8, value: UInt16) -> Bool
}
