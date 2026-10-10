import Foundation
import Testing
@testable import SystemKit

private let t0 = Date(timeIntervalSinceReferenceDate: 2_000_000)

// MARK: Protection thresholds

private func feed(_ guardian: inout KeepAwakeGuard, _ input: GuardInput, at seconds: TimeInterval) -> KeepAwakeGuard.Change? {
    guardian.feed(input, at: t0.addingTimeInterval(seconds))
}

@Test func batteryAtFifteenPercentOnBatteryTripsAndRecoversAboveTwenty() {
    var g = KeepAwakeGuard()
    #expect(feed(&g, GuardInput(batteryPercent: 16, onBattery: true), at: 0) == nil)
    #expect(feed(&g, GuardInput(batteryPercent: 15, onBattery: true), at: 30) == .tripped(.battery))
    #expect(feed(&g, GuardInput(batteryPercent: 18, onBattery: true), at: 60) == nil)  // inside the band
    #expect(g.tripped == .battery)
    #expect(feed(&g, GuardInput(batteryPercent: 21, onBattery: true), at: 90) == .cleared)
}

@Test func lowChargeOnPowerDoesNotTrip() {
    var g = KeepAwakeGuard()
    #expect(feed(&g, GuardInput(batteryPercent: 5, onBattery: false), at: 0) == nil)
    #expect(g.tripped == nil)
    #expect(feed(&g, GuardInput(batteryPercent: nil), at: 30) == nil)  // desktop Mac
}

@Test func thermalStateSeriousTripsFairClears() {
    var g = KeepAwakeGuard()
    #expect(feed(&g, GuardInput(thermal: .fair), at: 0) == nil)
    #expect(feed(&g, GuardInput(thermal: .serious), at: 30) == .tripped(.thermalState))
    #expect(feed(&g, GuardInput(thermal: .critical), at: 60) == nil)
    #expect(feed(&g, GuardInput(thermal: .fair), at: 90) == .cleared)
}

@Test func temperatureNeedsSixtySecondsAndClearsOnlyBelowSeventyFive() {
    var g = KeepAwakeGuard()
    #expect(feed(&g, GuardInput(hottest: 91), at: 0) == nil)
    #expect(feed(&g, GuardInput(hottest: 92), at: 30) == nil)
    #expect(feed(&g, GuardInput(hottest: 91), at: 60) == .tripped(.temperature))
    #expect(feed(&g, GuardInput(hottest: 80), at: 90) == nil)  // cooler, still held back
    #expect(g.tripped == .temperature)
    #expect(feed(&g, GuardInput(hottest: 75), at: 120) == .cleared)
}

@Test func temperatureSpikeShorterThanSixtySecondsIsIgnored() {
    var g = KeepAwakeGuard()
    #expect(feed(&g, GuardInput(hottest: 95), at: 0) == nil)
    #expect(feed(&g, GuardInput(hottest: 70), at: 30) == nil)
    #expect(feed(&g, GuardInput(hottest: 95), at: 60) == nil)
    #expect(feed(&g, GuardInput(hottest: 95), at: 90) == nil)  // clock restarted at 60
    #expect(g.tripped == nil)
}

@Test func temperatureOscillationAroundNinetyTripsOnce() {
    var g = KeepAwakeGuard()
    var trips = 0
    for i in 0..<60 {
        if case .tripped? = feed(&g, GuardInput(hottest: i % 2 == 0 ? 91 : 86), at: Double(i) * 30) { trips += 1 }
    }
    #expect(trips == 1)
}

// MARK: Trigger matching

@Test func processMatchingIsExactAndCaseSensitive() {
    let wanted = AwakeTrigger.aiTools.processNames
    #expect(wanted == ["claude", "codex", "cursor-agent", "ollama"])
    #expect(AwakeTrigger.build.processNames == ["xcodebuild", "swift-build", "docker"])
    #expect(ProcessScan.toolName(inPath: "/Users/x/.local/share/claude/versions/2.1.296", among: wanted) == "claude")
    #expect(ProcessScan.toolName(inPath: "/Users/x/.local/share/cursor-agent/versions/2026.1/cursor-agent", among: wanted) == "cursor-agent")
    #expect(ProcessScan.toolName(inPath: "/Applications/Claude.app/Contents/MacOS/Claude", among: wanted) == nil)
    #expect(ProcessScan.toolName(inPath: "/opt/other/versions/1.0", among: wanted) == nil)
    #expect(ProcessScan.looksLikeVersion("2.1.296") && !ProcessScan.looksLikeVersion("claude") && !ProcessScan.looksLikeVersion("123"))
}

@Test func scanFindsThisProcessByItsOwnName() {
    let name = ProcessInfo.processInfo.processName
    #expect(ProcessScan.running(among: [name]).count <= 1)
    #expect(ProcessScan.running(among: ["no-such-process-name-xyz"]).isEmpty)
    #expect(ProcessScan.running(among: []).isEmpty)
}

@Test func assertionRowsGroupPerProcessAndSkipNoise() {
    let entries: [[String: Any]] = [
        ["AssertPID": Int32(10), "AssertType": "PreventUserIdleSystemSleep", "AssertLevel": 255, "AssertName": "caffeinate command-line tool", "Process Name": "caffeinate"],
        ["AssertPID": Int32(10), "AssertType": "PreventUserIdleDisplaySleep", "AssertLevel": 255, "AssertName": "x", "Process Name": "caffeinate"],
        ["AssertPID": Int32(11), "AssertType": "UserIsActive", "AssertLevel": 255, "AssertName": "HID", "Process Name": "bluetoothd"],
        ["AssertPID": Int32(12), "AssertType": "PreventUserIdleSystemSleep", "AssertLevel": 0, "AssertName": "off", "Process Name": "a"],
        ["AssertPID": Int32(13), "AssertType": "PreventUserIdleSystemSleep", "AssertLevel": 255, "AssertName": "display is on", "Process Name": "powerd"],
        ["AssertPID": Int32(99), "AssertType": "PreventUserIdleSystemSleep", "AssertLevel": 255, "AssertName": "me", "Process Name": "Sistem"],
    ]
    let rows = AssertionReader.holders(from: entries, ownPID: 99)
    #expect(rows.map(\.pid) == [10, 99])
    #expect(rows[0].preventsDisplaySleep && !rows[1].preventsDisplaySleep)
    #expect(rows[1].isSelf && !rows[0].isSelf)
}

// MARK: Controller

@MainActor
private final class FakeBackend: PowerAssertionBackend {
    var live: [UInt32: AssertionKind] = [:]
    var created: [AssertionKind] = []
    private var next: UInt32 = 1
    func create(_ kind: AssertionKind, name: String) -> UInt32? {
        let id = next
        next += 1
        live[id] = kind
        created.append(kind)
        return id
    }
    func release(_ id: UInt32) { live[id] = nil }
}

@MainActor
private final class Rig {
    let backend = FakeBackend()
    var clock = t0
    var processes: Set<String> = []
    var input = GuardInput(batteryPercent: 80, onBattery: false)
    var rate: Double? = 0
    var onPower: Bool? = false
    var events: [KeepAwakeEvent] = []
    var processScans = 0
    lazy var controller = KeepAwakeController(
        backend: backend,
        sources: AwakeSources(
            now: { [unowned self] in clock },
            runningProcesses: { [unowned self] wanted in processScans += 1; return processes.intersection(wanted) },
            guardInput: { [unowned self] in input },
            networkRate: { [unowned self] in rate },
            resetNetwork: {},
            isOnPower: { [unowned self] in onPower }),
        assertionName: "test")

    init() { controller.onEvent = { [unowned self] in events.append($0) } }

    func advance(_ seconds: TimeInterval, poll: Bool = true) {
        clock = clock.addingTimeInterval(seconds)
        controller.evaluate(poll: poll)
    }
}

@Test @MainActor func disabledControllerHoldsNothingAndReadsNothing() {
    let rig = Rig()
    #expect(rig.controller.startManual(duration: 60) == false)
    rig.controller.apply(KeepAwakeConfig(enabled: false, triggers: [.aiTools]))
    rig.advance(100)
    #expect(rig.backend.live.isEmpty && rig.processScans == 0)
    #expect(rig.controller.state == KeepAwakeState())
}

@Test @MainActor func manualSessionHoldsAnAssertionAndExpiresOnTime() {
    let rig = Rig()
    rig.controller.apply(KeepAwakeConfig(enabled: true))
    #expect(rig.controller.startManual(duration: 1_800))
    #expect(rig.backend.live.values.sorted { "\($0)" < "\($1)" } == [.system])  // never the display by default
    #expect(rig.controller.remaining() == 1_800)
    rig.advance(1_799, poll: false)
    #expect(rig.controller.state.isHolding && rig.controller.remaining() == 1)
    rig.advance(2, poll: false)
    #expect(!rig.controller.state.isHolding && rig.backend.live.isEmpty)
    #expect(rig.controller.state.manualActive == false)
}

@Test @MainActor func indefiniteSessionHasNoRemainingAndStopReleases() {
    let rig = Rig()
    rig.controller.apply(KeepAwakeConfig(enabled: true, keepDisplayOn: true))
    #expect(rig.controller.startManual(duration: nil))
    #expect(rig.controller.remaining() == nil && rig.controller.state.manualEndsAt == nil)
    #expect(rig.backend.live.count == 2 && rig.controller.state.holdsDisplay)
    rig.controller.stopManual()
    #expect(rig.backend.live.isEmpty)
}

@Test @MainActor func displayAssertionFollowsTheSetting() {
    let rig = Rig()
    rig.controller.apply(KeepAwakeConfig(enabled: true))
    rig.controller.startManual(duration: nil)
    #expect(rig.backend.live.count == 1)
    rig.controller.apply(KeepAwakeConfig(enabled: true, keepDisplayOn: true))
    #expect(rig.backend.live.count == 2)
    rig.controller.apply(KeepAwakeConfig(enabled: true, keepDisplayOn: false))
    #expect(rig.backend.live.values.allSatisfy { $0 == .system } && rig.backend.live.count == 1)
    rig.controller.apply(KeepAwakeConfig(enabled: false))
    #expect(rig.backend.live.isEmpty)
}

@Test @MainActor func processTriggerHoldsDuringGraceThenReleases() {
    let rig = Rig()
    rig.controller.apply(KeepAwakeConfig(enabled: true, triggers: [.aiTools]))
    #expect(rig.backend.live.isEmpty)  // nothing running, nothing held
    rig.processes = ["codex"]
    rig.advance(30)
    #expect(rig.controller.state.holdingTriggers == [.aiTools] && rig.backend.live.count == 1)
    rig.processes = []
    rig.advance(30)
    rig.advance(60)  // 90 s since last seen: still inside the 120 s grace
    #expect(rig.controller.state.isHolding)
    rig.advance(30)  // 120 s: grace edge
    #expect(rig.controller.state.isHolding)
    rig.advance(30)  // 150 s
    #expect(!rig.controller.state.isHolding && rig.backend.live.isEmpty)
}

@Test @MainActor func triggerReturningDuringGraceKeepsHolding() {
    let rig = Rig()
    rig.controller.apply(KeepAwakeConfig(enabled: true, triggers: [.build]))
    rig.processes = ["xcodebuild"]
    rig.advance(30)
    rig.processes = []
    rig.advance(100)
    rig.processes = ["docker"]
    rig.advance(30)
    rig.processes = []
    rig.advance(100)
    #expect(rig.controller.state.isHolding)
    #expect(rig.backend.created.count == 1)  // one assertion throughout
}

@Test @MainActor func onlyEnabledTriggersAreEvaluated() {
    let rig = Rig()
    rig.processes = ["xcodebuild", "claude"]
    rig.controller.apply(KeepAwakeConfig(enabled: true, triggers: [.aiTools]))
    rig.advance(30)
    #expect(rig.controller.state.presentTriggers == [.aiTools])  // the running build is ignored
    rig.controller.apply(KeepAwakeConfig(enabled: true, triggers: []))
    rig.advance(30)
    #expect(!rig.controller.state.isHolding)
}

@Test @MainActor func chargingTriggerFollowsPowerWithoutGrace() {
    let rig = Rig()
    rig.controller.apply(KeepAwakeConfig(enabled: true, triggers: [.charging]))
    #expect(rig.backend.live.isEmpty)
    rig.onPower = true
    rig.advance(30)
    #expect(rig.controller.state.holdingTriggers == [.charging])
    rig.onPower = false
    rig.advance(30)
    #expect(rig.backend.live.isEmpty)
}

@Test @MainActor func networkTriggerNeedsTheThresholdAndReleasesAfterGrace() {
    let rig = Rig()
    rig.controller.apply(KeepAwakeConfig(enabled: true, triggers: [.network], networkThreshold: 5_000_000))
    rig.rate = nil  // no baseline yet
    rig.advance(30)
    rig.rate = 4_000_000
    rig.advance(30)
    #expect(!rig.controller.state.isHolding)
    rig.rate = 6_000_000
    rig.advance(30)
    #expect(rig.controller.state.holdingTriggers == [.network])
    rig.rate = 3_000_000  // inside the hysteresis band (2.5-5 MB/s): still counts as busy
    rig.advance(30)
    #expect(rig.controller.state.presentTriggers == [.network])
    rig.rate = 100_000
    for _ in 0..<5 { rig.advance(30) }  // 150 s after the last busy read
    #expect(!rig.controller.state.isHolding)
}

@Test @MainActor func lowBatteryEndsAManualSessionNotifiesOnceAndRefusesToRestart() {
    let rig = Rig()
    rig.controller.apply(KeepAwakeConfig(enabled: true))
    #expect(rig.controller.startManual(duration: nil))
    rig.input = GuardInput(batteryPercent: 14, onBattery: true)
    rig.advance(30)
    #expect(rig.backend.live.isEmpty && rig.controller.state.blocked == .battery)
    #expect(rig.events == [.protectionTripped(.battery)])
    #expect(rig.controller.startManual(duration: nil) == false)
    rig.advance(30)
    rig.advance(30)
    #expect(rig.events == [.protectionTripped(.battery)])  // no repeat
    rig.input = GuardInput(batteryPercent: 14, onBattery: false)  // plugged in
    rig.advance(30)
    #expect(rig.events.last == .protectionCleared && rig.controller.state.blocked == nil)
    #expect(rig.controller.startManual(duration: 60))
}

@Test @MainActor func startingAtAnUnsafeMomentIsRefusedAtOnce() {
    let rig = Rig()
    rig.input = GuardInput(batteryPercent: 10, onBattery: true)
    rig.controller.apply(KeepAwakeConfig(enabled: true))
    #expect(rig.controller.startManual(duration: 3_600) == false)
    #expect(rig.backend.live.isEmpty && rig.backend.created.isEmpty || rig.backend.live.isEmpty)
    #expect(rig.controller.state.blocked == .battery)
}

@Test @MainActor func hotMacBlocksTriggersUntilItCoolsBelowSeventyFive() {
    let rig = Rig()
    rig.controller.apply(KeepAwakeConfig(enabled: true, triggers: [.aiTools]))
    rig.processes = ["claude"]
    rig.input = GuardInput(hottest: 92)
    rig.advance(30)
    rig.advance(30)
    rig.advance(30)  // 60 s of 92 C
    #expect(rig.controller.state.blocked == .temperature && rig.backend.live.isEmpty)
    rig.input = GuardInput(hottest: 80)
    rig.advance(30)
    #expect(rig.backend.live.isEmpty)  // not cool enough yet
    rig.input = GuardInput(hottest: 70)
    rig.advance(30)
    #expect(rig.controller.state.isHolding && rig.events == [.protectionTripped(.temperature), .protectionCleared])
}

@Test @MainActor func protectionReadsNothingWhileNothingIsHeld() {
    let rig = Rig()
    var reads = 0
    let controller = KeepAwakeController(backend: rig.backend, sources: AwakeSources(
        now: { rig.clock }, runningProcesses: { _ in [] }, guardInput: { reads += 1; return GuardInput() },
        networkRate: { nil }, resetNetwork: {}, isOnPower: { false }), assertionName: "t")
    controller.apply(KeepAwakeConfig(enabled: true, triggers: [.aiTools, .charging]))
    for _ in 0..<10 { rig.clock = rig.clock.addingTimeInterval(30); controller.evaluate(poll: true) }
    #expect(reads == 0)
}

@Test @MainActor func deallocatingTheControllerReleasesTheAssertion() {
    let backend = FakeBackend()
    var controller: KeepAwakeController? = KeepAwakeController(backend: backend, sources: Rig().controllerSources(), assertionName: "t")
    controller?.apply(KeepAwakeConfig(enabled: true))
    controller?.startManual(duration: nil)
    #expect(backend.live.count == 1)
    controller = nil
    #expect(backend.live.isEmpty)
}

extension Rig {
    fileprivate func controllerSources() -> AwakeSources {
        AwakeSources(now: { t0 }, runningProcesses: { _ in [] }, guardInput: { GuardInput() }, networkRate: { nil }, resetNetwork: {}, isOnPower: { nil })
    }
}
