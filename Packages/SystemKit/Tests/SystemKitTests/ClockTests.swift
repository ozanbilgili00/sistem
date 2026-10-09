import Foundation
import Testing
@testable import SystemKit

@Test func secondsDetectionIgnoresQuotedText() {
    #expect(!ClockFormat.containsSeconds("HH:mm"))
    #expect(ClockFormat.containsSeconds("HH:mm:ss"))
    #expect(ClockFormat.containsSeconds("h:mm:ss a"))
    #expect(!ClockFormat.containsSeconds("HH 'saat' mm"))       // 's' in a literal
    #expect(ClockFormat.containsSeconds("HH 'saat' mm:ss"))
    #expect(!ClockFormat.containsSeconds("EEE d MMM HH:mm"))
    #expect(!ClockFormat.containsSeconds(""))
    for preset in ClockFormat.presets { #expect(ClockFormat.containsSeconds(preset) == (preset == "HH:mm:ss")) }
}

@Test func nextUpdateIsTheNextBoundary() {
    let t = Date(timeIntervalSince1970: 1_791_000_000 + 17.4)  // 17.4 s into a minute-aligned stamp
    let minute = ClockFormat.nextUpdate(after: t, pattern: "HH:mm")
    #expect(Int(minute.timeIntervalSince1970) % 60 == 0)
    #expect(minute > t && minute.timeIntervalSince(t) <= 60.05 && minute.timeIntervalSince(t) > 42)
    let second = ClockFormat.nextUpdate(after: t, pattern: "HH:mm:ss")
    #expect(second.timeIntervalSince(t) > 0.5 && second.timeIntervalSince(t) < 1.1)
    // Exactly on a boundary: the next one, never the same instant again.
    let boundary = Date(timeIntervalSince1970: 1_791_000_060)
    #expect(ClockFormat.nextUpdate(after: boundary, pattern: "HH:mm").timeIntervalSince(boundary) > 59.9)
    // An update is never earlier than the boundary: formatting at it shows the new minute.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "HH:mm"
    #expect(formatter.string(from: minute) != formatter.string(from: t))
}

@Test func patternsAreSanitized() {
    #expect(ClockFormat.sanitized("HH:mm\n") == "HH:mm")
    #expect(ClockFormat.sanitized(String(repeating: "H", count: 100)).count == 40)
    #expect(ClockFormat.sanitized("EEE d MMM") == "EEE d MMM")
    #expect(!ClockFormat.defaultPattern().isEmpty)
    #expect(ClockFormat.defaultPattern(locale: Locale(identifier: "en_US")).contains("a"))
    #expect(!ClockFormat.defaultPattern(locale: Locale(identifier: "tr_TR")).contains("a"))
}

// MARK: SNTP

private func reply(sent: Date, serverReceive: Double, serverTransmit: Double, mode: UInt8 = 4, stratum: UInt8 = 2, leap: UInt8 = 0,
                   originate: [UInt8]? = nil) -> Data {
    var packet = [UInt8](repeating: 0, count: 48)
    packet[0] = leap << 6 | 4 << 3 | mode
    packet[1] = stratum
    packet.replaceSubrange(24..<32, with: originate ?? SNTPClient.timestamp(sent))
    packet.replaceSubrange(32..<40, with: SNTPClient.timestamp(Date(timeIntervalSince1970: serverReceive)))
    packet.replaceSubrange(40..<48, with: SNTPClient.timestamp(Date(timeIntervalSince1970: serverTransmit)))
    return Data(packet)
}

@Test func sntpComputesOffsetAndRoundTrip() throws {
    let sent = Date(timeIntervalSince1970: 1_791_000_000)
    // Server is 2 s ahead of us; 40 ms each way, 1 ms of processing.
    let received = sent.addingTimeInterval(0.081)
    let data = reply(sent: sent, serverReceive: 1_791_000_000 + 2.04, serverTransmit: 1_791_000_000 + 2.041)
    let result = try #require(SNTPClient.parse(data, sent: sent, received: received))
    #expect(abs(result.offset - 2.0) < 0.001)
    #expect(abs(result.roundTrip - 0.080) < 0.001)
}

@Test func sntpRejectsBadReplies() {
    let sent = Date(timeIntervalSince1970: 1_791_000_000), received = sent.addingTimeInterval(0.05)
    let good = (1_791_000_000.02, 1_791_000_000.03)
    #expect(SNTPClient.parse(reply(sent: sent, serverReceive: good.0, serverTransmit: good.1), sent: sent, received: received) != nil)
    #expect(SNTPClient.parse(reply(sent: sent, serverReceive: good.0, serverTransmit: good.1, mode: 3), sent: sent, received: received) == nil)
    #expect(SNTPClient.parse(reply(sent: sent, serverReceive: good.0, serverTransmit: good.1, stratum: 0), sent: sent, received: received) == nil)
    #expect(SNTPClient.parse(reply(sent: sent, serverReceive: good.0, serverTransmit: good.1, leap: 3), sent: sent, received: received) == nil)
    // Doesn't echo our send time: not an answer to our question.
    #expect(SNTPClient.parse(reply(sent: sent, serverReceive: good.0, serverTransmit: good.1, originate: [UInt8](repeating: 7, count: 8)),
                             sent: sent, received: received) == nil)
    #expect(SNTPClient.parse(Data(count: 47), sent: sent, received: received) == nil)
    #expect(SNTPClient.parse(reply(sent: sent, serverReceive: 0, serverTransmit: 0), sent: sent, received: received) == nil)
}

@Test func sntpRequestShape() {
    let packet = SNTPClient.request(at: Date(timeIntervalSince1970: 1_791_000_000))
    #expect(packet.count == 48 && packet[0] == 0x23)
    #expect(SNTPClient.timeout <= 5)
}
