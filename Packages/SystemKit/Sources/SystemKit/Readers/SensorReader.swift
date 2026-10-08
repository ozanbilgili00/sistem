import Foundation

// MARK: Catalog types

public enum SensorKind: String, Sendable, CaseIterable {
    case fan, temperature, voltage, current, power
}

/// Where a temperature sensor sits. Only meaningful for `.temperature`; the others
/// use `.other`.
public enum SensorGroup: String, Sendable, CaseIterable {
    case cpuSuper, cpuPerformance, gpu, memory, soc, ssd, battery, other
}

/// What a sensor is called, without any language: the app maps these to strings.
/// `raw` carries the SMC key for a Mac whose mapping isn't known.
public enum SensorLabel: Sendable, Hashable {
    case raw(String)
    /// "Super core sensor 3": the Nth sensor of a family, in key order. The SMC does
    /// not say which physical core a sensor belongs to, so this is an ordinal only.
    case indexed(SensorLabelBase, Int)
    case named(SensorLabelBase)
}

public enum SensorLabelBase: String, Sendable, CaseIterable {
    case superCore, performanceCore, gpuUnit
    case socCPU, socCPUHottest, socRegionA, socRegionB, socHotspot
    case battery, nand
    case dcIn, batteryPack, system, adapter, cpu
    case fan
}

public struct SensorInfo: Sendable, Hashable {
    public let key: String
    public let kind: SensorKind
    public let group: SensorGroup
    public let label: SensorLabel

    public init(key: String, kind: SensorKind, group: SensorGroup, label: SensorLabel) {
        self.key = key
        self.kind = kind
        self.group = group
        self.label = label
    }
}

public struct FanInfo: Sendable, Hashable {
    /// Zero-based, as in the SMC key names (`F0Ac`).
    public let index: Int
    public let minRPM: Float
    public let maxRPM: Float

    public init(index: Int, minRPM: Float, maxRPM: Float) {
        self.index = index
        self.minRPM = minRPM
        self.maxRPM = maxRPM
    }
}

/// Everything this Mac exposes that is worth showing, found once. Immutable, so it is
/// shared by reference between the reader and every sample.
public final class SensorCatalog: Sendable {
    public let model: String
    /// True when the model's key names were verified by hand (BULGULAR.md); otherwise
    /// every sensor is `.other` with its raw key as the name.
    public let isKnownModel: Bool
    public let sensors: [SensorInfo]
    public let fans: [FanInfo]

    public init(model: String, isKnownModel: Bool, sensors: [SensorInfo], fans: [FanInfo]) {
        self.model = model
        self.isKnownModel = isKnownModel
        self.sensors = sensors
        self.fans = fans
    }

    /// Indices into `sensors` of one kind.
    public func indices(of kind: SensorKind) -> [Int] { sensors.indices.filter { sensors[$0].kind == kind } }
}

// MARK: Samples

/// The few numbers the menu bar needs. Cheap to read.
public struct TemperatureSample: Sendable, Equatable {
    /// Hottest CPU core sensor (Super and Performance clusters), °C.
    public var cpuHottest: Float?
    public var cpuAverage: Float?
    public var gpuHottest: Float?
    /// Hottest of everything read; the fallback on a Mac whose CPU sensors are unknown.
    public var hottest: Float?

    public init(cpuHottest: Float? = nil, cpuAverage: Float? = nil, gpuHottest: Float? = nil, hottest: Float? = nil) {
        self.cpuHottest = cpuHottest
        self.cpuAverage = cpuAverage
        self.gpuHottest = gpuHottest
        self.hottest = hottest
    }

    /// What the menu bar shows.
    public var headline: Float? { cpuHottest ?? hottest }
}

public struct FanReading: Sendable, Equatable {
    public var info: FanInfo
    /// nil when the fan gave an implausible number this tick.
    public var rpm: Float?

    public init(info: FanInfo, rpm: Float?) {
        self.info = info
        self.rpm = rpm
    }
}

/// One full read. `values` lines up with `catalog.sensors`; nil = dropped by validation.
public struct SensorSample: Sendable {
    public let catalog: SensorCatalog
    public var values: [Float?]
    public var fans: [FanReading]
    public var temperature: TemperatureSample

    public init(catalog: SensorCatalog, values: [Float?], fans: [FanReading], temperature: TemperatureSample) {
        self.catalog = catalog
        self.values = values
        self.fans = fans
        self.temperature = temperature
    }

    /// Valid readings of one kind, in catalog order.
    public func readings(of kind: SensorKind, group: SensorGroup? = nil) -> [(info: SensorInfo, value: Float)] {
        catalog.sensors.indices.compactMap { index in
            let info = catalog.sensors[index]
            guard info.kind == kind, group == nil || info.group == group, let value = values[index] else { return nil }
            return (info, value)
        }
    }
}

// MARK: Validation

/// What counts as a real reading. Sentinels seen in the wild: -9200 °C from HID
/// `PMU tdev*`, 0 from SMC sensors that exist in the key list but have no thermistor
/// (`Tz1x`, `TfCB`), and garbage integers behind non-float temperature keys (`TTPD`).
public enum SensorValidity {
    public static let temperature: ClosedRange<Double> = -50...150
    public static let voltage: ClosedRange<Double> = 0...60
    public static let current: ClosedRange<Double> = -30...30
    public static let power: ClosedRange<Double> = 0...500
    public static let fanRPM: ClosedRange<Double> = 0...20_000

    /// A sensor first read below this is not a thermistor (`TVMD` reads a constant 1.0):
    /// no running Mac has a component at 5 °C. Applied once, when the catalog is built.
    public static let admissionFloor: Double = 5

    /// A temperature of exactly zero is a missing sensor, not a freezing one.
    public static func isValidTemperature(_ value: Double) -> Bool {
        value.isFinite && value != 0 && temperature.contains(value)
    }

    static func range(for kind: SensorKind) -> ClosedRange<Double> {
        switch kind {
        case .temperature: temperature
        case .voltage: voltage
        case .current: current
        case .power: power
        case .fan: fanRPM
        }
    }

    public static func isValid(_ value: Double, kind: SensorKind) -> Bool {
        kind == .temperature ? isValidTemperature(value) : value.isFinite && range(for: kind).contains(value)
    }
}

// MARK: Naming

/// Key → name rules. Verified for the Mac17,8 (M5 Pro) only (Tools/discovery); any
/// other model lists every temperature under "other" with its SMC key.
enum SensorNaming {
    static let verifiedModels: Set<String> = ["Mac17,8"]

    struct Rule {
        var kind: SensorKind
        var group: SensorGroup
        var base: SensorLabelBase
        var indexed: Bool
    }

    /// nil = not a sensor we list.
    static func rule(for key: String, model: String) -> Rule? {
        guard verifiedModels.contains(model) else { return nil }
        switch key {
        case "TPDX": return Rule(kind: .temperature, group: .soc, base: .socCPUHottest, indexed: false)
        case "TCMb": return Rule(kind: .temperature, group: .soc, base: .socHotspot, indexed: false)
        case "TB0T", "TB1T", "TB2T": return Rule(kind: .temperature, group: .battery, base: .battery, indexed: true)
        case "TH0a", "TH0b", "TH0x": return Rule(kind: .temperature, group: .ssd, base: .nand, indexed: true)
        case "VD0R": return Rule(kind: .voltage, group: .other, base: .dcIn, indexed: false)
        case "Vb0f": return Rule(kind: .voltage, group: .other, base: .batteryPack, indexed: false)
        case "ID0R": return Rule(kind: .current, group: .other, base: .dcIn, indexed: false)
        case "Ib0f": return Rule(kind: .current, group: .other, base: .batteryPack, indexed: false)
        case "PSTR": return Rule(kind: .power, group: .other, base: .system, indexed: false)
        case "PDTR": return Rule(kind: .power, group: .other, base: .adapter, indexed: false)
        case "PPMC": return Rule(kind: .power, group: .other, base: .cpu, indexed: false)
        default: break
        }
        // Families: `Tp` Super, `Tm` Performance, `Tg` GPU cores; `TPD?`, `TRD?`, `TUD?` SoC
        // regions. The aggregate `…X` of a family is the hottest member.
        if key.hasPrefix("Tp") { return Rule(kind: .temperature, group: .cpuSuper, base: .superCore, indexed: true) }
        if key.hasPrefix("Tm") { return Rule(kind: .temperature, group: .cpuPerformance, base: .performanceCore, indexed: true) }
        if key.hasPrefix("Tg") { return Rule(kind: .temperature, group: .gpu, base: .gpuUnit, indexed: true) }
        if key.hasPrefix("TPD") { return Rule(kind: .temperature, group: .soc, base: .socCPU, indexed: true) }
        if key.hasPrefix("TRD") { return Rule(kind: .temperature, group: .soc, base: .socRegionA, indexed: true) }
        if key.hasPrefix("TUD") { return Rule(kind: .temperature, group: .soc, base: .socRegionB, indexed: true) }
        return nil
    }

    /// Key prefixes the enumeration visits (binary-searched ranges of the SMC index).
    static let prefixes = ["T", "F"]
}

// MARK: Reader

/// Temperatures, fans, voltages, currents and power from the SMC. Read-only: this
/// type has no code path that writes an SMC key.
///
/// The key list is built on first use (a few hundred index calls, ~tens of ms) and
/// cached with each key's type, so a read is one IOKit round trip per key (~16 µs of
/// CPU). The menu bar asks only for the CPU core sensors (`sampleTemperature()`); the
/// full list (`sample()`) is read while the Sensors page or popover is on screen.
///
/// Not thread-safe: confine to one executor.
public final class SensorReader {
    private struct Entry {
        var key: SMC.Key
        var kind: SensorKind
    }

    private struct Fan {
        var info: FanInfo
        var actual: SMC.Key
    }

    private let smc: SMC
    private let model: String
    private var catalogStorage: SensorCatalog?
    private var entries: [Entry] = []
    private var fans: [Fan] = []
    /// Indices into `entries` the menu bar reads.
    private var headlineIndices: [Int] = []
    private var cpuIndices: [Int] = []
    private var gpuIndices: [Int] = []
    /// Stuck-value detection for the unnamed temperatures (see ``stuckAfter``).
    private var lastValues: [Float?] = []
    private var sameCount: [UInt16] = []
    private var stuck: [Bool] = []

    /// A sensor in the "other" group whose value stays bit-identical for this many full
    /// reads (~2 minutes at the default interval) is a limit or a fixed code, not a
    /// temperature, and is hidden for the rest of the run. Named groups are exempt:
    /// a battery or SSD sensor really can sit at one value for a long time.
    static let stuckAfter: UInt16 = 60

    public init?(smc: SMC? = SMC(), model: String = HardwareInfo.current().modelIdentifier) {
        guard let smc else { return nil }
        self.smc = smc
        self.model = model
    }

    /// Builds the catalog on first call.
    public var catalog: SensorCatalog {
        if let catalogStorage { return catalogStorage }
        build()
        return catalogStorage!
    }

    /// Number of SMC reads one full `sample()` makes.
    public var fullReadCount: Int { entries.count + fans.count }
    /// Number of SMC reads one `sampleTemperature()` makes.
    public var headlineReadCount: Int { headlineIndices.count }
    /// Number of SMC reads `sampleTemperature(includeGPU: true)` makes.
    public var headlineWithGPUReadCount: Int { headlineIndices.count + gpuIndices.count }

    // MARK: Enumeration

    private func build() {
        let known = SensorNaming.verifiedModels.contains(model)
        var infos: [SensorInfo] = []
        var entries: [Entry] = []
        var ordinals: [SensorLabelBase: Int] = [:]

        func add(_ key: SMC.Key, kind: SensorKind, group: SensorGroup, label: SensorLabel) {
            guard let raw = smc.readNumber(key), SensorValidity.isValid(raw, kind: kind) else { return }
            infos.append(SensorInfo(key: key.name, kind: kind, group: group, label: label))
            entries.append(Entry(key: key, kind: kind))
        }

        // Temperatures: every `T…` float key (the integer-typed ones are not degrees).
        for name in smc.keys(withPrefix: "T") {
            guard let key = smc.key(name), key.type == "flt ",
                  let first = smc.readNumber(key), SensorValidity.isValid(first, kind: .temperature),
                  first >= SensorValidity.admissionFloor else { continue }
            if known, let rule = SensorNaming.rule(for: name, model: model) {
                let label: SensorLabel
                if rule.indexed {
                    let next = (ordinals[rule.base] ?? 0) + 1
                    ordinals[rule.base] = next
                    label = .indexed(rule.base, next)
                } else {
                    label = .named(rule.base)
                }
                add(key, kind: .temperature, group: rule.group, label: label)
            } else {
                add(key, kind: .temperature, group: .other, label: .raw(name))
            }
        }

        // Voltage, current and power: a curated list on a verified model, the three
        // power totals on any model. Rail names (`VP1b`, `IS7l`, …) are not documented,
        // so they are not listed.
        let curated = known
            ? ["VD0R", "Vb0f", "ID0R", "Ib0f", "PSTR", "PDTR", "PPMC"]
            : ["PSTR", "PDTR", "PPMC"]
        for name in curated {
            guard let key = smc.key(name), key.type == "flt " else { continue }
            if known, let rule = SensorNaming.rule(for: name, model: model) {
                add(key, kind: rule.kind, group: .other, label: .named(rule.base))
            } else {
                let kind: SensorKind = name.hasPrefix("V") ? .voltage : name.hasPrefix("I") ? .current : .power
                add(key, kind: kind, group: .other, label: .raw(name))
            }
        }

        // Fans: count, then min/max once and the live key per fan.
        var fanList: [Fan] = []
        if let count = smc.read("FNum")?.number, count >= 1, count <= 8 {
            for index in 0..<Int(count) {
                guard let actual = smc.key("F\(index)Ac"), actual.type == "flt ",
                      let minKey = smc.key("F\(index)Mn"), let maxKey = smc.key("F\(index)Mx"),
                      let low = smc.readNumber(minKey), let high = smc.readNumber(maxKey),
                      SensorValidity.isValid(low, kind: .fan), SensorValidity.isValid(high, kind: .fan),
                      high > 0, high >= low else { continue }
                fanList.append(Fan(info: FanInfo(index: index, minRPM: Float(low), maxRPM: Float(high)), actual: actual))
            }
        }

        self.entries = entries
        lastValues = [Float?](repeating: nil, count: entries.count)
        sameCount = [UInt16](repeating: 0, count: entries.count)
        stuck = [Bool](repeating: false, count: entries.count)
        fans = fanList
        catalogStorage = SensorCatalog(model: model, isKnownModel: known, sensors: infos, fans: fanList.map(\.info))
        cpuIndices = infos.indices.filter { infos[$0].group == .cpuSuper || infos[$0].group == .cpuPerformance }
        gpuIndices = infos.indices.filter { infos[$0].group == .gpu }
        // On a model whose CPU sensors aren't known, the headline falls back to the
        // hottest of every temperature.
        headlineIndices = known && !cpuIndices.isEmpty ? cpuIndices : infos.indices.filter { infos[$0].kind == .temperature }
    }

    // MARK: Reading

    /// Full list: every sensor, fan, voltage, current and power value.
    public func sample() -> SensorSample {
        let catalog = self.catalog
        let infos = catalog.sensors
        var values = [Float?](repeating: nil, count: entries.count)
        for index in entries.indices {
            let value = read(entries[index])
            if infos[index].kind == .temperature, infos[index].group == .other, let value {
                if lastValues[index] == value {
                    sameCount[index] = min(sameCount[index] &+ 1, Self.stuckAfter)
                    if sameCount[index] >= Self.stuckAfter { stuck[index] = true }
                } else {
                    sameCount[index] = 0
                }
                lastValues[index] = value
            }
            values[index] = stuck[index] ? nil : value
        }
        let fanReadings = fans.map { fan in
            FanReading(info: fan.info, rpm: smc.readNumber(fan.actual).flatMap {
                SensorValidity.isValid($0, kind: .fan) ? Float($0) : nil
            })
        }
        return SensorSample(catalog: catalog, values: values, fans: fanReadings,
                            temperature: derive(values))
    }

    /// Just the CPU core sensors, for the menu bar; with `includeGPU` also the GPU's.
    public func sampleTemperature(includeGPU: Bool = false) -> TemperatureSample {
        _ = catalog
        var hottest: Float?
        var total: Float = 0
        var count = 0
        var cpuHottest: Float?
        let isKnown = catalogStorage?.isKnownModel ?? false
        for index in headlineIndices {
            guard let value = read(entries[index]) else { continue }
            hottest = max(hottest ?? value, value)
            if isKnown {
                cpuHottest = max(cpuHottest ?? value, value)
                total += value
                count += 1
            }
        }
        var gpuHottest: Float?
        if includeGPU {
            for index in gpuIndices {
                if let value = read(entries[index]) { gpuHottest = max(gpuHottest ?? value, value) }
            }
        }
        return TemperatureSample(cpuHottest: cpuHottest, cpuAverage: count > 0 ? total / Float(count) : nil,
                                 gpuHottest: gpuHottest, hottest: hottest)
    }

    private func read(_ entry: Entry) -> Float? {
        guard let raw = smc.readNumber(entry.key), SensorValidity.isValid(raw, kind: entry.kind) else { return nil }
        return Float(raw)
    }

    private func derive(_ values: [Float?]) -> TemperatureSample {
        var sample = TemperatureSample()
        let cpu = cpuIndices.compactMap { values[$0] }
        if !cpu.isEmpty {
            sample.cpuHottest = cpu.max()
            sample.cpuAverage = cpu.reduce(0, +) / Float(cpu.count)
        }
        sample.gpuHottest = gpuIndices.compactMap { values[$0] }.max()
        let temperatures = entries.indices.compactMap { entries[$0].kind == .temperature ? values[$0] : nil }
        sample.hottest = temperatures.max()
        return sample
    }
}
