import Foundation
import Testing
@testable import SystemKit

@Suite("Widget seti: destek matrisi, sıra, niceleme")
struct WidgetSetTests {
    // MARK: Destek matrisi

    @Test func everyMenuBarModuleHasAtLeastOneKind() {
        for module in ModuleID.menuBarCandidates where module != .bluetooth {
            #expect(!WidgetKind.supported(by: module).isEmpty, "\(module)")
        }
        #expect(WidgetKind.supported(by: .dashboard).isEmpty)
    }

    @Test func initialConfigIsSupported() {
        for module in ModuleID.menuBarCandidates where module != .bluetooth {
            let initial = WidgetConfig.initial(for: module)
            #expect(initial.kinds.isSubset(of: Set(WidgetKind.supported(by: module))), "\(module)")
        }
    }

    @Test func unsupportedKindsAreCutAndNeverLeaveItEmpty() {
        let everything = WidgetConfig(kinds: Set(WidgetKind.allCases), showLabel: true)
        for module in ModuleID.menuBarCandidates where module != .bluetooth {
            let clean = everything.sanitized(for: module)
            #expect(clean.kinds.isSubset(of: Set(WidgetKind.supported(by: module))), "\(module)")
            #expect(!clean.kinds.isEmpty)
        }
        // Nothing supported at all by the module: falls back to the module's initial configuration.
        let onlyBars = WidgetConfig(kinds: [.bars], showLabel: false)
        #expect(onlyBars.sanitized(for: .network).kinds == [.arrows])
        #expect(onlyBars.sanitized(for: .cpu).kinds == [.bars])
    }

    /// An old file stored a plain number for the speed modules; they now draw arrows.
    @Test func oldTextOnSpeedModulesBecomesArrows() {
        let old = WidgetConfig(kinds: [.text, .chart], showLabel: true)
        #expect(old.sanitized(for: .network).kinds == [.arrows, .chart])
        #expect(old.sanitized(for: .disk).kinds == [.arrows, .chart])
        #expect(old.sanitized(for: .cpu).kinds == [.text, .chart])
    }

    @Test func configCodingKeepsOldFormatAndSkipsUnknownKinds() throws {
        let json = #"{"cpu":{"kinds":["text","chart","hologram"],"showLabel":false},"network":{"kinds":["text"],"showLabel":true},"dashboard":{"kinds":["text"],"showLabel":true},"moon":{"kinds":["text"],"showLabel":true}}"#
        let map = try #require(WidgetConfig.decodeMap(Data(json.utf8)))
        #expect(map[.cpu] == WidgetConfig(kinds: [.text, .chart], showLabel: false))
        #expect(map[.network]?.kinds == [.arrows])
        #expect(map[.dashboard] == nil)
        #expect(map.count == 2)
        let again = try JSONEncoder().encode(["cpu": map[.cpu]!])
        #expect(try #require(WidgetConfig.decodeMap(again))[.cpu] == map[.cpu])
        #expect(WidgetConfig.decodeMap(Data("nonsense".utf8)) == nil)
    }

    @Test func orderedKindsFollowDeclarationOrder() {
        let config = WidgetConfig(kinds: [.sparkline, .ring, .text, .chart], showLabel: true)
        #expect(config.orderedKinds == [.text, .chart, .ring, .sparkline])  // text, chart, ring: the order before this phase
    }

    // MARK: Sıra

    @Test func defaultOrderIsWidgetsThenCupDisplayServers() {
        #expect(MenuBarOrder.sanitized([]) == MenuBarOrder.allSections)
        #expect(MenuBarOrder.allSections.suffix(3) == [.keepAwake, .display, .servers])
    }

    @Test func sanitizedDropsUnknownAndDuplicatesAndAddsMissing() {
        let order = MenuBarOrder.sanitized(["network", "banana", "cpu", "network", "dashboard", "cpu", "servers"])
        #expect(order.filter { [.network, .cpu, .servers].contains($0) } == [.network, .cpu, .servers])  // the given order holds; missing ones slot in beside their default neighbours
        #expect(Set(order) == Set(MenuBarOrder.allSections))
        #expect(order.count == MenuBarOrder.allSections.count)
    }

    @Test func missingSectionComesBackNextToItsDefaultNeighbour() {
        let withoutGPU = MenuBarOrder.allSections.filter { $0 != .gpu }.map(\.rawValue)
        let order = MenuBarOrder.sanitized(withoutGPU)
        #expect(order == MenuBarOrder.allSections)  // after ram, where it is by default
        let reversed = MenuBarOrder.sanitized(MenuBarOrder.allSections.reversed().filter { $0 != .gpu }.map(\.rawValue))
        #expect(reversed.count == MenuBarOrder.allSections.count)
        #expect(Set(reversed).count == reversed.count)
    }

    @Test func moveSwapsWithTheVisibleNeighbour() {
        let order = MenuBarOrder.allSections  // cpu ram gpu disk network sensors battery bluetooth clock keepAwake display servers
        let visible: [ModuleID] = [.cpu, .network, .sensors]
        let down = MenuBarOrder.moved(.cpu, up: false, in: order, visible: visible)
        #expect(MenuBarOrder.arranged(visible, by: down) == [.network, .cpu, .sensors])
        let back = MenuBarOrder.moved(.cpu, up: true, in: down, visible: visible)
        #expect(MenuBarOrder.arranged(visible, by: back) == [.cpu, .network, .sensors])
        // Edges do nothing.
        #expect(MenuBarOrder.moved(.cpu, up: true, in: order, visible: visible) == order)
        #expect(MenuBarOrder.moved(.sensors, up: false, in: order, visible: visible) == order)
        // A section that is not shown cannot be moved.
        #expect(MenuBarOrder.moved(.gpu, up: true, in: order, visible: visible) == order)
        #expect(Set(down) == Set(order))
    }

    /// Kaydet → yeni örnek (aynı depodan okuyan) → aynı sıra.
    @Test func orderSurvivesARestart() throws {
        let suite = "SistemTests-order-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(MenuBarOrder.load(from: defaults) == MenuBarOrder.allSections)
        let custom: [ModuleID] = [.servers, .network, .cpu] + MenuBarOrder.allSections.filter { ![.servers, .network, .cpu].contains($0) }
        MenuBarOrder.save(custom, to: defaults)
        let reopened = try #require(UserDefaults(suiteName: suite))
        #expect(MenuBarOrder.load(from: reopened) == custom)
    }

    @Test func corruptStoredOrderFallsBackSafely() throws {
        let suite = "SistemTests-corrupt-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(42, forKey: MenuBarOrder.defaultsKey)
        #expect(MenuBarOrder.load(from: defaults) == MenuBarOrder.allSections)
        defaults.set(["cpu", "cpu", "zzz", ""], forKey: MenuBarOrder.defaultsKey)
        let loaded = MenuBarOrder.load(from: defaults)
        #expect(loaded.first == .cpu)
        #expect(Set(loaded) == Set(MenuBarOrder.allSections))
    }

    // MARK: Niceleme

    @Test func quantizeAndResample() {
        #expect(LevelScale.levels([0, 0.5, 1, 1.4, -1], steps: 8) == [0, 4, 8, 8, 0])
        let thirty = (0..<30).map { Float($0) / 29 }
        let reduced = LevelScale.resample(thirty, to: 15)
        #expect(reduced.count == 15)
        #expect(reduced == reduced.sorted())
        #expect(LevelScale.resample([0.1, 0.2], to: 15) == [0.1, 0.2])
    }

    @Test func steadyGraphNeverRedraws() {
        var filter = LevelHysteresis()
        var changes = 0
        var last: [UInt8]?
        // ±1 level of wobble every tick for two simulated minutes: at most the patience-bound redraws.
        for tick in 0..<60 {
            let wobble: UInt8 = tick % 2 == 0 ? 3 : 4
            let shown = filter.filter(Array(repeating: wobble, count: 8))
            if let last, last != shown { changes += 1 }
            last = shown
        }
        #expect(changes <= 60 / 8, "tek seviyelik titreme en çok her 8 tikte bir çizdirir: \(changes)")
    }

    @Test func graphHonoursJumpsAndMinimumTicks() {
        var filter = LevelHysteresis()
        _ = filter.filter([1, 1, 1, 1])
        // 2 levels: held for the first two ticks, shown on the third.
        #expect(filter.filter([3, 1, 1, 1]) == [1, 1, 1, 1])
        #expect(filter.filter([3, 1, 1, 1]) == [1, 1, 1, 1])
        #expect(filter.filter([3, 1, 1, 1]) == [3, 1, 1, 1])
        // A jump of 4 levels shows at once, even right after an update.
        #expect(filter.filter([7, 1, 1, 1]) == [7, 1, 1, 1])
        // A different number of points (cores changed) shows at once.
        #expect(filter.filter([7, 1]) == [7, 1])
    }

    @Test func busyGraphIsBoundedByMinTicks() {
        var filter = LevelHysteresis()
        var changes = 0
        var last: [UInt8]?
        for tick in 0..<60 {  // 2-3 level swings every tick, never a 4-level jump
            let shown = filter.filter(Array(repeating: UInt8(3 + (tick % 3 == 0 ? 2 : 0)), count: 8))
            if let last, last != shown { changes += 1 }
            last = shown
        }
        #expect(changes <= 60 / 3 + 1, "\(changes)")
    }
}
