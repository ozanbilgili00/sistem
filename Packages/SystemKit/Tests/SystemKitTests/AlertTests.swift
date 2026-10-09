import Foundation
import Testing
@testable import SystemKit

private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

/// Feeds `values` one per `step` seconds and collects what fired.
private func run(_ spec: ThresholdSpec, _ values: [Double?], step: TimeInterval = 10) -> [(Int, ThresholdTransition)] {
    var machine = ThresholdMachine(spec)
    var out: [(Int, ThresholdTransition)] = []
    for (i, value) in values.enumerated() {
        if let transition = machine.feed(value, at: t0.addingTimeInterval(Double(i) * step)) { out.append((i, transition)) }
    }
    return out
}

private let cpuSpec = ThresholdSpec(direction: .above, trigger: 90, clear: 80, minDuration: 30, clearDuration: 10, cooldown: 600)

@Test func oscillationAroundTheLimitNotifiesOnce() {
    // Hovers across 90 but never below the clear level of 80: one trigger, no recovery, no repeat.
    let series: [Double?] = (0..<120).map { $0 % 2 == 0 ? 93 : 88 }
    let events = run(cpuSpec, series)
    #expect(events.map(\.1) == [.triggered])
    #expect(events.first?.0 == 4)  // first breaching reading at least 30 s after the first
}

@Test func oscillationAcrossTheWholeBandStaysInsideCooldown() {
    // Dips below 80 between bursts: it recovers, but the cooldown stops a second notification.
    var spec = cpuSpec
    spec.minDuration = 0
    spec.clearDuration = 0
    let series: [Double?] = (0..<40).map { $0 % 2 == 0 ? 97 : 60 }  // 400 s < 600 s cooldown
    let events = run(spec, series)
    #expect(events.filter { $0.1 == .triggered }.count == 1)
}

@Test func firesAgainOnlyAfterCooldownWhenItBreachesAgain() {
    var spec = cpuSpec
    spec.minDuration = 0
    spec.clearDuration = 0
    spec.cooldown = 100
    let series: [Double?] = [95, 60, 95, 60, 95, 60, 95, 60, 95, 60, 95, 60, 95, 60]  // 10 s steps
    let events = run(spec, series)
    #expect(events.filter { $0.1 == .triggered }.map(\.0) == [0, 10])  // second burst after 100 s
}

@Test func dipToTheRecoveredLevelRestartsThePendingBreach() {
    let events = run(cpuSpec, [95, 95, 70, 95, 95, 70, 95, 95, 70])
    #expect(events.isEmpty)
}

@Test func spikeShorterThanTheDurationIsIgnored() {
    let events = run(cpuSpec, [10, 99, 99, 20, 99, 99, 20, 99, 99, 20])
    #expect(events.isEmpty)
}

@Test func sustainedBreachFiresOnceAndRecoveryReArms() {
    let series: [Double?] = [95, 95, 95, 95, 95, 95, 50, 50, 50, 95, 95, 95, 95]
    let events = run(cpuSpec, series)
    #expect(events.map(\.1) == [.triggered, .recovered])
    #expect(events[0].0 == 3 && events[1].0 == 7)  // recovered once it stayed below 80 for 10 s
}

@Test func valueInsideTheHysteresisBandDoesNotRecover() {
    let events = run(cpuSpec, [95, 95, 95, 95, 85, 85, 85, 85, 85, 85])
    #expect(events.map(\.1) == [.triggered])
}

@Test func gapAfterSleepRestartsTheBreachClock() {
    var machine = ThresholdMachine(cpuSpec)
    #expect(machine.feed(95, at: t0) == nil)
    #expect(machine.feed(95, at: t0.addingTimeInterval(10)) == nil)
    // The Mac slept for an hour: the 3 s that follow must not add up to a 30 s breach.
    #expect(machine.feed(95, at: t0.addingTimeInterval(3_600)) == nil)
    #expect(machine.feed(95, at: t0.addingTimeInterval(3_610)) == nil)
    #expect(machine.feed(95, at: t0.addingTimeInterval(3_620)) == nil)
    #expect(machine.feed(95, at: t0.addingTimeInterval(3_630)) == .triggered)  // 30 s after waking, not after the first read
}

@Test func missingValueDoesNotCountTowardABreach() {
    let events = run(cpuSpec, [95, 95, nil, 95, 95, 95, 95, 95])
    #expect(events.map(\.0) == [6])
}

@Test func belowDirectionUsesItsOwnHysteresis() {
    let disk = ThresholdSpec(direction: .below, trigger: 10, clear: 12, cooldown: 3_600)
    let events = run(disk, [30, 11, 9.9, 10.5, 9, 11.9, 12.1, 9, 8], step: 60)
    // 9.9 triggers; 10.5, 9, 11.9 stay in the band; 12.1 recovers; the next dip is inside the cooldown.
    #expect(events.map(\.1) == [.triggered, .recovered])
}

@Test func deadlineTracksPendingBreachAndCooldown() {
    var machine = ThresholdMachine(ThresholdSpec(direction: .above, trigger: 1, clear: 0, minDuration: 15, cooldown: 300))
    #expect(machine.deadline == nil)
    _ = machine.feed(1, at: t0)
    #expect(machine.deadline == t0.addingTimeInterval(15))
    #expect(machine.feed(1, at: t0.addingTimeInterval(15)) == .triggered)
    #expect(machine.deadline == nil)
}

// MARK: Rules and demand

@Test func ruleChoicesSnapAndUnknownKindsAreDropped() {
    let json = #"[{"kind":"cpuLoad","enabled":true,"threshold":91,"duration":29},{"kind":"someFutureKind","enabled":true,"threshold":1,"duration":1},{"kind":"diskFree","enabled":false,"threshold":"x"}]"#
    let rules = AlertRule.decode(Data(json.utf8))
    #expect(rules.map(\.kind) == AlertKind.allCases)
    #expect(rules[0].enabled && rules[0].threshold == 90 && rules[0].duration == 30)
    #expect(rules.filter(\.enabled).count == 1)
    #expect(AlertRule.decode(nil).allSatisfy { !$0.enabled })
}

@Test func everyKindHasASaneHysteresisBand() {
    for kind in AlertKind.allCases {
        for trigger in kind.thresholdChoices {
            let clear = kind.clearLevel(for: trigger)
            switch kind.direction {
            case .above: #expect(clear < trigger, "\(kind) \(trigger)")
            case .below: #expect(clear > trigger, "\(kind) \(trigger)")
            }
        }
        #expect(kind.thresholdChoices.contains(kind.defaultThreshold))
    }
}

@Test @MainActor func periodicConsumersSlowAMetricDownButOrdinaryOnesDoNot() {
    let demand = DemandRegistry()
    demand.retain(.cpu, period: 10)
    #expect(demand.ticks(for: .cpu, interval: 2) == 5)
    #expect(demand.ticks(for: .cpu, interval: 4) == 2)
    #expect(demand.tickOverrides(interval: 2) == [.cpu: 5])
    demand.retain(.cpu, period: 30)
    #expect(demand.ticks(for: .cpu, interval: 2) == 5)  // fastest periodic consumer wins
    demand.retain(.cpu)  // a widget
    #expect(demand.ticks(for: .cpu, interval: 2) == 1)
    demand.release(.cpu)
    #expect(demand.ticks(for: .cpu, interval: 2) == 5)
    demand.release(.cpu, period: 10)
    #expect(demand.ticks(for: .cpu, interval: 2) == 15)
    demand.release(.cpu, period: 30)
    #expect(demand.active.isEmpty && demand.tickOverrides(interval: 2).isEmpty)
}

@Test func samplerStepIsTheGCDOfTheRates() {
    var config = SamplerConfig(interval: 2, metrics: [.cpu], paused: false, ticks: [.cpu: 5])
    #expect(config.stride == 5)  // a lone ten-second rule wakes every ten seconds
    config.metrics = [.cpu, .diskSpace]
    config.ticks = [.cpu: 5, .diskSpace: 30]
    #expect(config.stride == 5)
    config.metrics = [.cpu, .temperature]
    config.ticks = [:]
    #expect(config.stride == 1)
    #expect(SamplerConfig(interval: 2, metrics: [.battery, .bluetooth], paused: false).stride == 15)
}

@Test func powerProfilesMapToIntervalFactors() {
    var state = PowerPolicy.State()
    #expect(PowerProfile.automatic.multiplier(for: state, slowDownOnBattery: true) == 1)
    #expect(PowerProfile.saver.multiplier(for: state, slowDownOnBattery: true) == 2)
    #expect(PowerProfile.precise.multiplier(for: state, slowDownOnBattery: true) == 1)
    state.onBattery = true
    #expect(PowerProfile.automatic.multiplier(for: state, slowDownOnBattery: true) == 2)
    #expect(PowerProfile.automatic.multiplier(for: state, slowDownOnBattery: false) == 1)
    #expect(PowerProfile.saver.multiplier(for: state, slowDownOnBattery: false) == 4)
    #expect(PowerProfile.precise.multiplier(for: state, slowDownOnBattery: true) == 1)
    state.thermal = .serious
    #expect(PowerProfile.precise.multiplier(for: state, slowDownOnBattery: true) == 2)
}

@MainActor
private final class Harness {
    let store = MetricStore()
    let demand = DemandRegistry()
    var clock = t0
    var posted: [AlertEvent] = []
    lazy var center = AlertCenter(store: store, demand: demand, now: { [unowned self] in clock }, post: { [unowned self] in posted.append($0) })

    func cpu(_ load: Float, at seconds: TimeInterval) {
        clock = t0.addingTimeInterval(seconds)
        store.ingest(Snapshot(cpu: CPUSample(user: load, system: 0, cores: [load], loadAverage: LoadAverage(one: 0, five: 0, fifteen: 0))))
    }
}

@Test @MainActor func allRulesOffMeansNoDemandAndNoObservation() {
    let h = Harness()
    h.center.apply(AlertRule.defaults)
    #expect(h.demand.active.isEmpty)
    h.cpu(0.99, at: 0)
    h.cpu(0.99, at: 60)
    #expect(h.posted.isEmpty)
}

@Test @MainActor func cpuRuleRegistersLowFrequencyDemandAndNotifiesOnceWhileOscillating() {
    let h = Harness()
    var rules = AlertRule.defaults
    rules[0] = AlertRule(kind: .cpuLoad, enabled: true)  // > 90 % for 30 s
    h.center.apply(rules)
    #expect(h.demand.active == [.cpu])
    #expect(h.demand.ticks(for: .cpu, interval: 2) == 5)
    // 20 minutes of a CPU wobbling 85–95 % every 10 s.
    for i in 0..<120 { h.cpu(i % 2 == 0 ? 0.95 : 0.88, at: Double(i) * 10) }
    #expect(h.posted.count == 1)
    #expect(h.posted.first?.kind == .cpuLoad && h.posted.first?.transition == .triggered)
    #expect(h.center.isActive(.cpuLoad))
    // Switching it off releases the metric.
    rules[0].enabled = false
    h.center.apply(rules)
    #expect(h.demand.active.isEmpty)
}

@Test @MainActor func editingOneRuleKeepsAnotherRulesState() {
    let h = Harness()
    var rules = AlertRule.defaults
    rules[0] = AlertRule(kind: .cpuLoad, enabled: true, duration: 10)
    h.center.apply(rules)
    for i in 0..<6 { h.cpu(0.95, at: Double(i) * 10) }
    #expect(h.posted.count == 1)
    rules[3] = AlertRule(kind: .diskFree, enabled: true)
    h.center.apply(rules)
    for i in 6..<12 { h.cpu(0.95, at: Double(i) * 10) }
    #expect(h.posted.count == 1)
    #expect(h.demand.active == [.cpu, .diskSpace])
}

@Test @MainActor func networkRuleUsesTheEventSourceAndWaitsOutBlips() {
    let h = Harness()
    var rules = AlertRule.defaults
    rules[5] = AlertRule(kind: .networkDown, enabled: true, duration: 15)
    h.center.apply(rules)
    #expect(h.demand.active == [.connectivity])
    let down = PathState(status: .unsatisfied)
    let up = PathState(status: .satisfied)
    h.clock = t0
    h.store.ingest(Snapshot(path: down))
    h.clock = t0.addingTimeInterval(5)
    h.store.ingest(Snapshot(path: up))  // a 5 s blip
    h.clock = t0.addingTimeInterval(60)
    h.center.evaluate()
    #expect(h.posted.isEmpty)
    h.clock = t0.addingTimeInterval(100)
    h.store.ingest(Snapshot(path: down))
    h.clock = t0.addingTimeInterval(120)  // the timer's job: no new path event arrives
    h.center.evaluate()
    #expect(h.posted.map(\.kind) == [.networkDown])
}

@Test @MainActor func batteryRuleOnlyJudgesWhileDischarging() {
    let h = Harness()
    var rules = AlertRule.defaults
    rules[4] = AlertRule(kind: .batteryLow, enabled: true)
    h.center.apply(rules)
    func battery(_ percent: Int, _ state: BatterySample.State, at seconds: Double) {
        h.clock = t0.addingTimeInterval(seconds)
        h.store.ingest(Snapshot(battery: .present(BatterySample(percent: percent, state: state))))
    }
    battery(15, .charging, at: 0)  // low but on power
    #expect(h.posted.isEmpty)
    battery(19, .discharging, at: 60)
    battery(18, .discharging, at: 120)
    #expect(h.posted.count == 1)
    battery(30, .charging, at: 180)
    #expect(h.posted.count == 2 && h.posted.last?.transition == .recovered)
}

@Test func formFactorFollowsTheModelThenTheBattery() {
    #expect(MacFormFactor.classify(model: "MacBookPro18,3", hasInternalBattery: false) == .laptop)
    #expect(MacFormFactor.classify(model: "Macmini9,1", hasInternalBattery: false) == .mini)
    #expect(MacFormFactor.classify(model: "Mac17,8", hasInternalBattery: true) == .laptop)
    #expect(MacFormFactor.classify(model: "Mac14,13", hasInternalBattery: false) == .desktop)
    #expect(HardwareInfo.bootDate().map { $0 < Date() } == true)
    #expect(HardwareInfo.systemDescription().hasPrefix("macOS "))
}

@Test func settingsArchiveRoundTripsAndRejectsForeignFiles() throws {
    let data = try SettingsArchive.encode(["temperatureUnit": "fahrenheit", "updateInterval": 3.0])
    let back = try SettingsArchive.decode(data)
    #expect(back["temperatureUnit"] as? String == "fahrenheit")
    #expect(back["updateInterval"] as? Double == 3)
    #expect(try SettingsArchive.decode(Data(#"{"app":"Sistem","schemaVersion":1,"settings":{"future":[1,2]}}"#.utf8))["future"] != nil)

    #expect(throws: SettingsArchive.Failure.notSettingsFile) { try SettingsArchive.decode(Data("[1]".utf8)) }
    #expect(throws: SettingsArchive.Failure.notSettingsFile) { try SettingsArchive.decode(Data(#"{"app":"Other","schemaVersion":1,"settings":{}}"#.utf8)) }
    #expect(throws: SettingsArchive.Failure.missingVersion) { try SettingsArchive.decode(Data(#"{"app":"Sistem","settings":{}}"#.utf8)) }
    #expect(throws: SettingsArchive.Failure.newerVersion(99)) { try SettingsArchive.decode(Data(#"{"app":"Sistem","schemaVersion":99,"settings":{}}"#.utf8)) }
    #expect(throws: SettingsArchive.Failure.tooLarge) { try SettingsArchive.decode(Data(count: SettingsArchive.maxBytes + 1)) }
}
