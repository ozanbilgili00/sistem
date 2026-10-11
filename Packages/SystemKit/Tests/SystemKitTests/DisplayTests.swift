import Foundation
import Testing
@testable import SystemKit

// MARK: Fakes — nothing here touches a real screen

@MainActor
final class FakeDisplayClock: DisplayClock {
    private var current = Date(timeIntervalSinceReferenceDate: 3_000_000)
    private var timers: [(id: Int, due: Date, action: @MainActor () -> Void)] = []
    private var nextID = 0

    func now() -> Date { current }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void {
        nextID += 1
        let id = nextID
        timers.append((id, current.addingTimeInterval(delay), action))
        return { [weak self] in MainActor.assumeIsolated { self?.timers.removeAll { $0.id == id } } }
    }

    /// Moves time forward, firing due timers in order (a timer may schedule another one).
    func advance(by seconds: TimeInterval) {
        let target = current.addingTimeInterval(seconds)
        while let next = timers.filter({ $0.due <= target }).min(by: { $0.due < $1.due }) {
            timers.removeAll { $0.id == next.id }
            current = max(current, next.due)
            next.action()
        }
        current = target
    }

    var pendingTimers: Int { timers.count }
}

@MainActor
final class FakeDisplayBackend: DisplayBackend {
    var list: [DisplayInfo]
    var modeTable: [DisplayID: [DisplayMode]] = [:]
    var setModeCalls: [(id: DisplayID, mode: DisplayMode, scope: ModeScope)] = []
    var refuseSetMode = false
    var listCalls = 0
    private(set) var handler: (@MainActor (DisplayChangeFlags) -> Void)?

    init(_ list: [DisplayInfo]) { self.list = list }

    func displays() -> [DisplayInfo] {
        listCalls += 1
        return list
    }

    func modes(for id: DisplayID) -> [DisplayMode] { modeTable[id] ?? [] }

    func setMode(_ mode: DisplayMode, on id: DisplayID, scope: ModeScope) -> Bool {
        setModeCalls.append((id, mode, scope))
        guard !refuseSetMode, let index = list.firstIndex(where: { $0.id == id }) else { return false }
        list[index].mode = mode
        return true
    }

    func startObserving(_ handler: @escaping @MainActor (DisplayChangeFlags) -> Void) { self.handler = handler }
    func stopObserving() { handler = nil }

    func fire(_ flags: DisplayChangeFlags) { handler?(flags) }
}

@MainActor
final class FakeDisplayGamma: GammaBackend {
    var applied: [DisplayID: GammaTable] = [:]
    var resets = 0

    func apply(_ table: GammaTable, to id: DisplayID) -> Bool {
        applied[id] = table
        return true
    }

    func resetAll() {
        resets += 1
        applied = [:]
    }
}

final class FakeDDCTransport: DDCTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt8: VCPValue]
    private var _writes: [(code: UInt8, value: UInt16)] = []

    init(_ values: [UInt8: VCPValue]) { self.values = values }

    var writes: [(code: UInt8, value: UInt16)] { lock.withLock { _writes } }

    func read(_ code: UInt8) -> VCPValue? { lock.withLock { values[code] } }

    func write(_ code: UInt8, value: UInt16) -> Bool {
        lock.withLock { _writes.append((code, value)) }
        return true
    }
}

@MainActor
final class FakeDDC: DDCProvider {
    var transports: [DisplayID: DDCTransport] = [:]
    var lookups = 0

    func transport(for display: DisplayInfo, among all: [DisplayInfo]) -> DDCTransport? {
        lookups += 1
        return transports[display.id]
    }
}

/// Runs work at once on the calling thread, so tests need no waiting.
@MainActor
final class ImmediateDisplayWorker: DisplayWorker {
    var jobs = 0

    func run<T: Sendable>(_ work: @escaping @Sendable () -> T, then: @escaping @MainActor (T) -> Void) {
        jobs += 1
        then(work())
    }
}

private let builtIn = DisplayInfo(id: 1, name: "Built-in", isBuiltIn: true, isMain: true,
                                  mode: DisplayMode(id: 10, width: 1728, height: 1117, pixelWidth: 3456, pixelHeight: 2234, refreshRate: 120), brightness: 0.6)
private let monitor = DisplayInfo(id: 4, name: "Monitor", vendor: 0x4C2D, model: 0x79CF,
                                  mode: DisplayMode(id: 20, width: 2560, height: 1440, refreshRate: 200))
private let monitorModes = [
    DisplayMode(id: 20, width: 2560, height: 1440, refreshRate: 200),
    DisplayMode(id: 21, width: 2560, height: 1440, refreshRate: 60),
    DisplayMode(id: 22, width: 1920, height: 1080, refreshRate: 60),
]

@MainActor
private struct Rig {
    let clock = FakeDisplayClock()
    let backend: FakeDisplayBackend
    let gamma = FakeDisplayGamma()
    let ddc = FakeDDC()
    let worker = ImmediateDisplayWorker()
    let controller: DisplayController

    init(_ list: [DisplayInfo] = [builtIn, monitor]) {
        backend = FakeDisplayBackend(list)
        backend.modeTable[4] = monitorModes
        controller = DisplayController(backend: backend, gamma: gamma, ddc: ddc, worker: worker, clock: clock)
    }

    func entry(_ id: DisplayID) -> DisplayEntry? { controller.state.entries.first { $0.id == id } }
}

// MARK: Gate 1 — a display without DDC falls back cleanly

@MainActor
@Test func displayWithoutDDCChannelEndsUnsupportedWithoutWork() {
    let rig = Rig()
    rig.controller.start()
    rig.controller.setVisible(true)
    #expect(rig.entry(4)?.ddc == .unsupported(.noChannel))
    #expect(rig.entry(1)?.ddc == .unsupported(.builtIn))
    #expect(rig.worker.jobs == 0)  // no channel, so no transfer was even attempted
    // Setting a control on it is ignored, not a crash.
    rig.controller.setControl(.brightness, to: 50, on: 4)
    #expect(rig.entry(4)?.controls.isEmpty == true)
}

@MainActor
@Test func monitorThatDoesNotAnswerEndsUnsupportedNoAnswer() {
    let rig = Rig()
    let silent = FakeDDCTransport([:])
    rig.ddc.transports[4] = silent
    rig.controller.start()
    rig.controller.setVisible(true)
    #expect(rig.entry(4)?.ddc == .unsupported(.noAnswer))
    rig.controller.setControl(.brightness, to: 50, on: 4)
    #expect(silent.writes.isEmpty)
}

@MainActor
@Test func answeringMonitorExposesOnlyTheControlsItHas() {
    let rig = Rig()
    rig.ddc.transports[4] = FakeDDCTransport([0x10: VCPValue(current: 30, maximum: 100), 0x12: VCPValue(current: 75, maximum: 100)])
    rig.controller.start()
    rig.controller.setVisible(true)
    #expect(rig.entry(4)?.ddc == .supported)
    #expect(Set(rig.entry(4)?.controls.keys.map { $0 } ?? []) == [.brightness, .contrast])
    #expect(rig.entry(4)?.controls[.brightness]?.fraction == 0.3)
}

@MainActor
@Test func nothingIsReadWhileNothingIsVisible() {
    let rig = Rig()
    rig.ddc.transports[4] = FakeDDCTransport([0x10: VCPValue(current: 30, maximum: 100)])
    rig.controller.start()
    rig.backend.fire(.setMode)
    rig.clock.advance(by: 1)
    #expect(rig.worker.jobs == 0)
    #expect(rig.ddc.lookups == 0)
    #expect(rig.entry(4)?.modes.isEmpty == true)
    rig.controller.setVisible(true)
    #expect(rig.worker.jobs == 1)
    #expect(rig.entry(4)?.modes.count == 3)
    rig.controller.setVisible(false)
    #expect(rig.entry(4)?.modes.isEmpty == true)
}

// MARK: DDC framing and the write limiter

@Test func ddcSetRequestHasTheDocumentedBytesAndChecksum() {
    // 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x00 ^ 0x32
    let packet = DDCPacket.setRequest(code: 0x10, value: 50)
    #expect(Array(packet.dropLast()) == [0x84, 0x03, 0x10, 0x00, 0x32])
    let expectedSum: [UInt8] = [0x6E, 0x51, 0x84, 0x03, 0x10, 0x00, 0x32]
    #expect(packet.last == expectedSum.reduce(0, ^))
    let getSum: [UInt8] = [0x6E, 0x51, 0x82, 0x01, 0x62]
    #expect(DDCPacket.getRequest(code: 0x62) == [0x82, 0x01, 0x62, getSum.reduce(0, ^)])
}

@Test func ddcReplyParsingAcceptsGoodRepliesAndRejectsBadOnes() {
    let good: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x2D, 0xED, 0x36]
    #expect(DDCPacket.parseReply(good, code: 0x10) == VCPValue(current: 45, maximum: 100))
    #expect(DDCPacket.parseReply(good, code: 0x12) == nil)  // another feature
    var unsupported = good
    unsupported[3] = 0x01
    unsupported[10] = unsupported[0..<10].reduce(0x50, ^)  // a valid frame that reports an error
    #expect(DDCPacket.parseReply(unsupported, code: 0x10) == nil)  // monitor says "unsupported VCP"
    #expect(DDCPacket.parseReply([0x6E, 0x88], code: 0x10) == nil)  // short
    #expect(DDCPacket.parseReply([UInt8](repeating: 0, count: 12), code: 0x10) == nil)  // empty bus
}

@Test func ddcReplyChecksumIsVerified() {
    // Bytes captured read-only from a real monitor (brightness 100/100, input 15/14).
    let real: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x64, 0xA4, 0x36]
    #expect(DDCPacket.parseReply(real, code: 0x10) == VCPValue(current: 100, maximum: 100))
    let input: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x60, 0x00, 0x00, 0x0E, 0x00, 0x0F, 0xD5, 0x36]
    #expect(DDCPacket.parseReply(input, code: 0x60) == VCPValue(current: 15, maximum: 14))
    for bit in 0..<8 {
        var corrupt = real
        corrupt[9] ^= UInt8(1 << bit)  // one flipped bit in the value
        #expect(DDCPacket.parseReply(corrupt, code: 0x10) == nil)
    }
    var wrongSum = real
    wrongSum[10] ^= 0x01
    #expect(DDCPacket.parseReply(wrongSum, code: 0x10) == nil)
}

@MainActor
@Test func inputSelectionIsWrittenExactlyAndNeverClampedToTheReportedMaximum() {
    let rig = Rig()
    let transport = FakeDDCTransport([0x60: VCPValue(current: 15, maximum: 14), 0x10: VCPValue(current: 50, maximum: 100)])
    rig.ddc.transports[4] = transport
    rig.controller.start()
    rig.controller.setVisible(true)
    rig.controller.setControl(.inputSource, to: 17, on: 4)
    #expect(transport.writes.last?.code == 0x60 && transport.writes.last?.value == 17)
    rig.controller.setControl(.inputSource, to: 99, on: 4)  // not a known input: nothing is written
    #expect(transport.writes.count == 1)
    rig.controller.setControl(.brightness, to: 500, on: 4)  // still clamped
    #expect(transport.writes.last?.code == 0x10 && transport.writes.last?.value == 100)
}

@MainActor
@Test func sliderDragIsLimitedToTenWritesPerSecondAndEndsOnTheLastValue() {
    let rig = Rig()
    let transport = FakeDDCTransport([0x10: VCPValue(current: 0, maximum: 100)])
    rig.ddc.transports[4] = transport
    rig.controller.start()
    rig.controller.setVisible(true)
    // A two second drag at 100 events per second.
    for step in 1...200 {
        rig.controller.setControl(.brightness, to: UInt16(step % 101), on: 4)
        rig.clock.advance(by: 0.01)
    }
    rig.clock.advance(by: 0.5)
    let writes = transport.writes
    #expect(writes.count <= 22)  // 10 per second, plus the first one
    #expect(writes.count >= 15)
    #expect(writes.last?.value == UInt16(200 % 101))
    #expect(rig.entry(4)?.controls[.brightness]?.current == UInt16(200 % 101))  // the slider never lagged
    #expect(rig.clock.pendingTimers == 0)  // nothing keeps running afterwards
}

@MainActor
@Test func controlValueIsClampedToTheMonitorsMaximum() {
    let rig = Rig()
    let transport = FakeDDCTransport([0x10: VCPValue(current: 10, maximum: 80)])
    rig.ddc.transports[4] = transport
    rig.controller.start()
    rig.controller.setVisible(true)
    rig.controller.setControl(.brightness, to: 500, on: 4)
    #expect(transport.writes.last?.value == 80)
}

// MARK: Gate 2 — an unconfirmed mode change returns after 15 s

@MainActor
@Test func unconfirmedModeChangeRevertsAfterFifteenSeconds() {
    let rig = Rig()
    rig.controller.start()
    rig.controller.setVisible(true)
    let slow = monitorModes[1]
    #expect(rig.controller.requestMode(slow, on: 4))
    #expect(rig.backend.list[1].mode == slow)
    #expect(rig.backend.setModeCalls.last?.scope == .appOnly)  // a trial dies with the process
    #expect(rig.controller.state.pending?.from.id == 20)
    rig.clock.advance(by: 14.9)
    #expect(rig.backend.list[1].mode == slow)
    #expect(rig.controller.state.pending != nil)
    rig.clock.advance(by: 0.2)
    #expect(rig.backend.list[1].mode?.id == 20)
    #expect(rig.controller.state.pending == nil)
    #expect(rig.controller.state.events.first?.kind == .modeReverted)
    #expect(rig.clock.pendingTimers == 0)
}

@MainActor
@Test func confirmedModeChangeStaysAndIsKeptForTheSession() {
    let rig = Rig()
    rig.controller.start()
    rig.controller.setVisible(true)
    let slow = monitorModes[1]
    rig.controller.requestMode(slow, on: 4)
    rig.clock.advance(by: 10)
    rig.controller.confirmModeChange()
    #expect(rig.backend.setModeCalls.last?.scope == .session)
    rig.clock.advance(by: 60)
    #expect(rig.backend.list[1].mode == slow)
    #expect(rig.controller.state.pending == nil)
}

@MainActor
@Test func revertButtonAndShutdownBothPutTheOldModeBack() {
    let rig = Rig()
    rig.controller.start()
    rig.controller.setVisible(true)
    rig.controller.requestMode(monitorModes[2], on: 4)
    rig.controller.revertModeChange()
    #expect(rig.backend.list[1].mode?.id == 20)
    rig.controller.requestMode(monitorModes[2], on: 4)
    rig.controller.stop()  // quitting during a trial
    #expect(rig.backend.list[1].mode?.id == 20)
    #expect(rig.controller.state.pending == nil)
    #expect(rig.clock.pendingTimers == 0)
}

@MainActor
@Test func refusedModeChangeOpensNoTrialAndSecondRequestWaits() {
    let rig = Rig()
    rig.controller.start()
    rig.controller.setVisible(true)
    rig.backend.refuseSetMode = true
    #expect(!rig.controller.requestMode(monitorModes[1], on: 4))
    #expect(rig.controller.state.pending == nil)
    #expect(rig.controller.state.modeChangeFailed)
    #expect(rig.clock.pendingTimers == 0)
    rig.backend.refuseSetMode = false
    #expect(rig.controller.requestMode(monitorModes[1], on: 4))
    #expect(!rig.controller.requestMode(monitorModes[2], on: 4))  // one trial at a time
    #expect(!rig.controller.requestMode(monitorModes[1], on: 99))  // unknown display
}

@MainActor
@Test func displayVanishingDuringTrialCancelsIt() {
    let rig = Rig()
    rig.controller.start()
    rig.controller.setVisible(true)
    rig.controller.requestMode(monitorModes[1], on: 4)
    rig.backend.list.removeAll { $0.id == 4 }
    rig.backend.fire(.removed)
    rig.clock.advance(by: 1)
    #expect(rig.controller.state.pending == nil)
    #expect(rig.clock.pendingTimers == 0)
    let calls = rig.backend.setModeCalls.count
    rig.clock.advance(by: 30)
    #expect(rig.backend.setModeCalls.count == calls)  // no revert aimed at a display that is gone
}

// MARK: Events, no timers

@MainActor
@Test func burstOfCallbacksIsOneReloadAndAnnouncementsAreIgnored() {
    let rig = Rig()
    rig.controller.start()
    let before = rig.backend.listCalls
    rig.backend.fire(.beginConfiguration)
    rig.clock.advance(by: 1)
    #expect(rig.backend.listCalls == before)
    for _ in 0..<5 { rig.backend.fire([.setMode, .moved]) }
    rig.clock.advance(by: 0.1)
    #expect(rig.backend.listCalls == before)  // still settling
    rig.clock.advance(by: 0.5)
    #expect(rig.backend.listCalls == before + 1)
    #expect(rig.clock.pendingTimers == 0)
}

@MainActor
@Test func connectAndDisconnectAreLoggedNewestFirstAndCapped() {
    let rig = Rig([builtIn])
    rig.controller.start()
    #expect(rig.controller.state.events.isEmpty)  // the initial list is not an event
    rig.backend.list.append(monitor)
    rig.backend.fire(.added)
    rig.clock.advance(by: 1)
    rig.backend.list.removeAll { $0.id == 4 }
    rig.backend.fire(.removed)
    rig.clock.advance(by: 1)
    #expect(rig.controller.state.events.map(\.kind) == [.disconnected, .connected])
    #expect(rig.controller.state.events.last?.detail == "2560 × 1440 · 200 Hz")
    for _ in 0..<80 {
        rig.backend.list.append(monitor)
        rig.backend.fire(.added)
        rig.clock.advance(by: 1)
        rig.backend.list.removeAll { $0.id == 4 }
        rig.backend.fire(.removed)
        rig.clock.advance(by: 1)
    }
    #expect(rig.controller.state.events.count == DisplayController.eventLimit)
}

@MainActor
@Test func reconfigurationWhileVisibleDoesNotReadDDCAgainOrRepublishUnchangedState() {
    let rig = Rig()
    rig.ddc.transports[4] = FakeDDCTransport([0x10: VCPValue(current: 30, maximum: 100)])
    var changes = 0
    rig.controller.onChange = { changes += 1 }
    rig.controller.start()
    rig.controller.setVisible(true)
    let jobs = rig.worker.jobs
    let published = changes
    rig.backend.fire(.moved)  // a callback that changes nothing we show
    rig.clock.advance(by: 1)
    #expect(rig.worker.jobs == jobs)
    #expect(changes == published)
    rig.backend.list.append(DisplayInfo(id: 9, name: "Other", vendor: 1, model: 2, mode: DisplayMode(id: 5, width: 800, height: 600)))
    rig.backend.fire(.added)
    rig.clock.advance(by: 1)
    #expect(rig.worker.jobs > jobs)  // a new display set is probed
}

@MainActor
@Test func idleControllerHoldsNoTimerAndNoWork() {
    let rig = Rig()
    rig.ddc.transports[4] = FakeDDCTransport([0x10: VCPValue(current: 30, maximum: 100)])
    rig.controller.start()
    rig.controller.setVisible(true)
    let jobs = rig.worker.jobs
    let lists = rig.backend.listCalls
    #expect(rig.clock.pendingTimers == 0)
    rig.clock.advance(by: 3_600)
    #expect(rig.worker.jobs == jobs)
    #expect(rig.backend.listCalls == lists)
}

// MARK: Gamma

@Test func gammaIdentityAtFullBrightnessAndNoWarmthAndMonotonicRamps() {
    let identity = GammaCurve.table(dim: 1, warmth: 0)
    #expect(identity.red.count == GammaTable.size)
    #expect(identity.red.first == 0 && identity.red.last == 1 && identity.blue.last == 1)
    let night = GammaCurve.table(dim: 0.5, warmth: 1)
    #expect(night.red.last == 0.5)
    #expect(night.blue.last! < night.green.last! && night.green.last! < night.red.last!)
    for table in [identity, night] {
        for channel in [table.red, table.green, table.blue] {
            #expect(zip(channel, channel.dropFirst()).allSatisfy { $0 <= $1 })
            #expect(channel.allSatisfy { $0 >= 0 && $0 <= 1 })
        }
    }
}

@Test func dimmingNeverGoesBlackAndBadInputIsHarmless() {
    #expect(GammaCurve.table(dim: 0, warmth: 0).red.last == GammaCurve.minimumDim)
    #expect(GammaCurve.table(dim: -3, warmth: 9).blue.last! > 0)
    #expect(GammaCurve.table(dim: .nan, warmth: .infinity).red.last == 1)
}

@MainActor
@Test func softwareDimmingAppliesAndResetReturnsToColorSyncWithoutTouchingOthers() {
    let rig = Rig([builtIn, monitor])
    rig.controller.start()
    rig.controller.setDim(0.4, on: 4)
    rig.controller.setWarmth(0.5, on: 1)
    #expect(rig.gamma.applied[4]?.red.last == 0.4)
    #expect(rig.gamma.applied[1] != nil)
    let resets = rig.gamma.resets
    rig.controller.resetColor(on: 4)
    #expect(rig.gamma.resets == resets + 1)  // back to the calibrated curve, not an identity table
    #expect(rig.gamma.applied[4] == nil)
    #expect(rig.gamma.applied[1] != nil)  // the other display kept its adjustment
}

@MainActor
@Test func quittingRestoresColorAndClearsAdjustments() {
    let rig = Rig()
    rig.controller.start()
    rig.controller.setDim(0.3, on: 4)
    rig.controller.stop()
    #expect(rig.gamma.applied.isEmpty)
    #expect(rig.entry(4)?.colorIsAdjusted == false)
    #expect(rig.backend.handler == nil)
}

@MainActor
@Test func adjustmentsAreReappliedAfterReconfiguration() {
    let rig = Rig()
    rig.controller.start()
    rig.controller.setDim(0.5, on: 4)
    rig.gamma.applied = [:]  // the system dropped our table during a mode change
    rig.backend.fire(.setMode)
    rig.clock.advance(by: 1)
    #expect(rig.gamma.applied[4]?.red.last == 0.5)
}

// MARK: Mode lists

@Test func modeCatalogListsSizesLargestFirstAndRatesFastestFirst() {
    let modes = monitorModes + [DisplayMode(id: 23, width: 1280, height: 720, pixelWidth: 2560, pixelHeight: 1440, refreshRate: 60),
                                DisplayMode(id: 24, width: 2560, height: 1440, refreshRate: 60)]
    let sizes = DisplayModeCatalog.sizes(of: modes)
    #expect(sizes.map(\.width) == [2560, 1920, 1280])
    #expect(sizes.last?.isHiDPI == true)
    let rates = DisplayModeCatalog.rates(for: sizes[0], in: modes)
    #expect(rates.map(\.refreshRate) == [200, 60])  // the duplicate 60 Hz is dropped
}

@Test func changeFlagsAnnouncementIsOnlyTheBareBeginBit() {
    #expect(DisplayChangeFlags.beginConfiguration.isOnlyAnnouncement)
    #expect(!DisplayChangeFlags([.beginConfiguration, .added]).isOnlyAnnouncement)
    #expect(!DisplayChangeFlags.setMode.isOnlyAnnouncement)
}

// MARK: Live, read-only

@MainActor
@Test func liveBackendListsDisplaysWithoutChangingAnything() {
    let displays = CGDisplayBackend().displays()
    // A build machine may have no display at all; when there is one, it has a mode.
    for display in displays { #expect(display.mode != nil) }
    #expect(displays.filter(\.isMain).count <= 1)
}
