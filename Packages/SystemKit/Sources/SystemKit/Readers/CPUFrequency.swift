import Darwin
import Foundation
import IOKit

/// Average CPU clock per core class over one sampling interval.
public struct CPUFrequencySample: Sendable, Equatable {
    public struct Cluster: Sendable, Equatable {
        /// Hardware name ("Super", "Performance", "Efficiency").
        public var name: String
        public var coreCount: Int
        /// Share of the interval the cluster's cores spent running (not idle or
        /// powered down), averaged over cores. 0...1.
        public var activeFraction: Float
        /// Where the active time sat between the lowest (0) and highest (1)
        /// performance state. Needs no frequency table, so it survives a Mac whose
        /// table can't be found. nil when the cluster was fully idle.
        public var performanceLevel: Float?
        /// Clock averaged over active time, in MHz. nil when idle, or when no
        /// trustworthy frequency table exists for this cluster.
        public var averageMHz: Float?
        /// The cluster's top clock from the table; nil together with the table.
        public var maxMHz: Float?

        public init(name: String, coreCount: Int, activeFraction: Float, performanceLevel: Float?,
                    averageMHz: Float?, maxMHz: Float?) {
            self.name = name
            self.coreCount = coreCount
            self.activeFraction = activeFraction
            self.performanceLevel = performanceLevel
            self.averageMHz = averageMHz
            self.maxMHz = maxMHz
        }
    }

    /// Fastest class first, like `HardwareInfo.clusters`.
    public var clusters: [Cluster]

    public init(clusters: [Cluster]) { self.clusters = clusters }
}

/// Frequency tables from the device tree's power manager node. Each cluster's
/// DVFS ladder is a property `voltage-states<N>-sram`: an array of (frequency,
/// voltage) pairs, ascending, little-endian 32-bit each.
enum DVFSTables {
    /// Frequencies in MHz, one per table entry, or nil if `data` isn't a plausible
    /// CPU ladder: empty, ragged, not ascending, containing a zero (GPU ladders do),
    /// or topping out outside 0.5...8 GHz. Newer chips store kHz, older ones Hz.
    static func parse(_ data: Data) -> [Float]? {
        guard data.count >= 16, data.count % 8 == 0 else { return nil }
        let words = data.withUnsafeBytes { raw in
            (0..<data.count / 4).map { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) }
        }
        let frequencies = stride(from: 0, to: words.count, by: 2).map { Double(words[$0]) }
        guard let last = frequencies.last, frequencies.allSatisfy({ $0 > 0 }),
              zip(frequencies, frequencies.dropFirst()).allSatisfy({ $0 < $1 }) else { return nil }
        let scale = last > 100_000_000 ? 1e-6 : 1e-3  // Hz or kHz → MHz
        guard (500...8_000).contains(last * scale) else { return nil }
        return frequencies.map { Float($0 * scale) }
    }

    /// Every plausible CPU ladder in the power manager node, by property name.
    /// One registry read, done once.
    static func load() -> [String: [Float]] {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/arm-io/pmgr")
        guard entry != IO_OBJECT_NULL else { return [:] }
        defer { IOObjectRelease(entry) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any] else { return [:] }
        var tables: [String: [Float]] = [:]
        for (key, value) in dictionary where key.hasPrefix("voltage-states") && key.hasSuffix("-sram") {
            if let data = value as? Data, let table = parse(data) { tables[key] = table }
        }
        return tables
    }

    /// The ladder for a cluster with `count` performance states, if exactly one
    /// frequency list fits. Two tables with the same frequencies (the two Performance
    /// clusters differ only in voltage) count as one; two different ones are
    /// ambiguous and yield nil rather than a guess.
    static func ladder(states count: Int, in tables: [String: [Float]]) -> [Float]? {
        let candidates = tables.values.filter { $0.count == count }
        guard let first = candidates.first, candidates.allSatisfy({ $0 == first }) else { return nil }
        return first
    }
}

/// Per-cluster CPU frequency from the IOReport "CPU Core Performance States"
/// residencies: how long each core sat in each DVFS state, weighted by that
/// state's clock from the device-tree table.
///
/// The IOReport state names run `DOWN`, `IDLE`, `V0P14` … `V14P0`; the number after
/// `V` is the index into the cluster's ladder. Channels are named after the core
/// class by their first letter (`PCPU` Super, `MCPU` Performance, `ECPU`
/// Efficiency); classes are matched to ``HardwareInfo`` clusters by that ranking
/// and by core count, and a Mac where the counts disagree gets no frequency at all.
///
/// Not thread-safe: confine to one executor.
public final class CPUFrequencyReader {
    private struct Group {
        let name: String
        let coreCount: Int
    }

    private let subscription: IOReport.Subscription
    private let hardware: HardwareInfo
    private let tables: [String: [Float]]
    /// Letter of the channel prefix → hardware cluster.
    private let groups: [Character: Group]
    private var previous: IOReport.Sample?
    /// Per group: the ladder (nil if none fits) and the V index of each state position.
    private var layouts: [Character: (ladder: [Float]?, stateIndex: [Int?])] = [:]

    /// nil when libIOReport or the channels are unavailable, or when the channel
    /// layout doesn't match this Mac's core classes.
    public init?(library: IOReport? = IOReport.library, hardware: HardwareInfo = .current(),
                 tables: [String: [Float]]? = nil, subscription: IOReport.Subscription? = nil) {
        guard let subscription = subscription ?? library?.performanceSubscription() else { return nil }
        self.subscription = subscription
        self.hardware = hardware
        self.tables = tables ?? DVFSTables.load()

        // A sample against itself is an empty delta that still lists every channel:
        // enough to count the cores each channel letter stands for.
        guard let probe = subscription.sample() else { return nil }
        var counts: [Character: Int] = [:]
        for reading in subscription.readings(from: probe, to: probe) where reading.channel.group == "CPU Stats" {
            guard let letter = Self.classLetter(reading.channel.name) else { continue }
            counts[letter, default: 0] += 1
        }
        let letters = counts.keys.sorted { Self.rank($0) < Self.rank($1) }
        guard letters.count == hardware.clusters.count else { return nil }
        var groups: [Character: Group] = [:]
        for (letter, cluster) in zip(letters, hardware.clusters) {
            guard counts[letter] == cluster.count else { return nil }
            groups[letter] = Group(name: cluster.name, coreCount: cluster.count)
        }
        self.groups = groups
        previous = probe
    }

    /// The CPU frequency ladders (MHz per state) found in the device tree, by property
    /// name. For the probe tool; the reader loads them itself.
    public static func discoveredLadders() -> [String: [Float]] { DVFSTables.load() }

    /// Forget the previous reading; the next `sample()` only primes.
    public func reset() { previous = nil }

    /// nil on the first call after init or `reset()`, which only primes.
    public func sample() -> CPUFrequencySample? {
        guard let current = subscription.sample() else { return nil }
        defer { previous = current }
        guard let earlier = previous else { return nil }

        struct Totals { var all = 0.0, active = 0.0, mhz = 0.0, level = 0.0, ladderComplete = true }
        var totals: [Character: Totals] = [:]
        for reading in subscription.readings(from: earlier, to: current)
        where reading.channel.group == "CPU Stats" && !reading.states.isEmpty {
            guard let letter = Self.classLetter(reading.channel.name), groups[letter] != nil else { continue }
            let layout = layout(for: letter, states: reading.states)
            var sum = totals[letter] ?? Totals()
            let top = Double(max(1, layout.stateIndex.compactMap { $0 }.max() ?? 1))
            for (position, state) in reading.states.enumerated() {
                let residency = Double(max(0, state.residency))
                sum.all += residency
                guard position < layout.stateIndex.count, let index = layout.stateIndex[position] else { continue }
                sum.active += residency
                sum.level += Double(index) / top * residency
                if let ladder = layout.ladder, index < ladder.count {
                    sum.mhz += Double(ladder[index]) * residency
                } else {
                    sum.ladderComplete = false
                }
            }
            totals[letter] = sum
        }

        let clusters = groups.sorted { Self.rank($0.key) < Self.rank($1.key) }
            .compactMap { letter, group -> CPUFrequencySample.Cluster? in
                guard let sum = totals[letter], sum.all > 0 else { return nil }
                let ladder = layouts[letter]?.ladder
                let isActive = sum.active > 0
                return CPUFrequencySample.Cluster(
                    name: group.name,
                    coreCount: group.coreCount,
                    activeFraction: Float(sum.active / sum.all),
                    performanceLevel: isActive ? Float(sum.level / sum.active) : nil,
                    averageMHz: isActive && sum.ladderComplete && ladder != nil ? Float(sum.mhz / sum.active) : nil,
                    maxMHz: ladder?.last
                )
            }
        return clusters.count == groups.count ? CPUFrequencySample(clusters: clusters) : nil
    }

    /// Decoded once per class from the first reading's state names.
    private func layout(for letter: Character, states: [IOReport.State]) -> (ladder: [Float]?, stateIndex: [Int?]) {
        if let known = layouts[letter], known.stateIndex.count == states.count { return known }
        let indices = states.map { Self.ladderIndex(of: $0.name) }
        let count = (indices.compactMap { $0 }.max() ?? -1) + 1
        let layout = (ladder: count > 0 ? DVFSTables.ladder(states: count, in: tables) : nil, stateIndex: indices)
        layouts[letter] = layout
        return layout
    }

    /// Fastest class first: Super (`P`) before Performance (`M`) before Efficiency (`E`).
    static func rank(_ letter: Character) -> Int {
        ["P", "M", "E"].firstIndex(of: letter) ?? 9
    }

    /// `PCPU3` → `P`, `MCPU12` → `M`; nil for anything that isn't a core channel.
    static func classLetter(_ channel: String) -> Character? {
        guard let letter = channel.first, channel.dropFirst().hasPrefix("CPU"),
              channel.last?.isNumber == true else { return nil }
        return letter
    }

    /// `V3P11` → 3. `IDLE`, `DOWN`, `OFF` and anything else → nil.
    static func ladderIndex(of state: String) -> Int? {
        guard state.hasPrefix("V"), let p = state.firstIndex(of: "P") else { return nil }
        return Int(state[state.index(after: state.startIndex)..<p])
    }
}
