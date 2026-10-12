#if DEBUG
import AppKit
import SistemUI
import SwiftUI
import SystemKit

/// `Sistem --snapshot <dir>` renders key screens offscreen to PNGs, in both themes,
/// then exits. Lets the UI be checked without opening a window or taking focus.
/// Live views get a store filled with synthetic history; nothing is sampled.
enum SnapshotRenderer {
    static func run(into directory: URL) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "SistemSnapshot")!
        defaults.removePersistentDomain(forName: "SistemSnapshot")
        UserDefaults(suiteName: "SistemSnapshot-six")?.removePersistentDomain(forName: "SistemSnapshot-six")
        let settings = SettingsStore(defaults: defaults)
        let feed = LiveFeed(store: syntheticStore(), engine: nil)
        feed.isActive = true
        let notifier = AlertNotifier(previewing: .notDetermined)
        // Keep Awake in three states, plus the module switched off.
        let triggers: Set<AwakeTrigger> = [.aiTools, .charging, .network]
        var holdingState = KeepAwakeState()
        holdingState.isHolding = true
        holdingState.manualActive = true
        holdingState.manualEndsAt = Date().addingTimeInterval(47 * 60)
        holdingState.holdingTriggers = [.aiTools]
        holdingState.presentTriggers = [.aiTools]
        var blockedState = KeepAwakeState()
        blockedState.blocked = .temperature
        let awakeModels: [(String, KeepAwakeModel)] = [
            ("on", KeepAwakeModel(previewing: holdingState, config: KeepAwakeConfig(enabled: true, triggers: triggers))),
            ("idle", KeepAwakeModel(previewing: KeepAwakeState(), config: KeepAwakeConfig(enabled: true, triggers: []))),
            ("blocked", KeepAwakeModel(previewing: blockedState, config: KeepAwakeConfig(enabled: true, triggers: triggers))),
            ("off", KeepAwakeModel(previewing: KeepAwakeState(), config: KeepAwakeConfig())),
        ]
        let awake = awakeModels[0].1
        let displayModels = displayPreviews()
        let display = displayModels[0].1
        let serverModels = serversPreviews()
        let servers = serverModels[0].1

        // Notification rules in their three permission states, and the empty state above.
        func variant(_ name: String, permission: AlertNotifier.Permission, rules: [AlertKind]) -> (SettingsStore, AlertNotifier) {
            let defaults = UserDefaults(suiteName: "SistemSnapshot-\(name)")!
            defaults.removePersistentDomain(forName: "SistemSnapshot-\(name)")
            let store = SettingsStore(defaults: defaults)
            store.alertRules = AlertRule.defaults.map { AlertRule(kind: $0.kind, enabled: rules.contains($0.kind)) }
            store.powerProfile = .saver
            return (store, AlertNotifier(previewing: permission))
        }
        let specs: [(String, AlertNotifier.Permission, [AlertKind])] = [
            ("allowed", .allowed, [.cpuLoad, .cpuTemperature, .diskFree, .networkDown]),
            ("denied", .denied, [.batteryLow]),
            ("waiting", .notDetermined, [.memoryPressure]),
        ]
        let ruleVariants: [(String, SettingsStore, AlertNotifier)] = specs.map { name, permission, rules in
            let made = variant(name, permission: permission, rules: rules)
            return (name, made.0, made.1)
        }

        let pages: [(String, Page)] = [
            ("dashboard", .module(.dashboard)), ("cpu", .module(.cpu)), ("gpu", .module(.gpu)), ("ram", .module(.ram)),
            ("disk", .module(.disk)), ("network", .module(.network)), ("sensors", .module(.sensors)), ("battery", .module(.battery)), ("bluetooth", .module(.bluetooth)), ("clock", .module(.clock)), ("keepawake", .module(.keepAwake)), ("display", .module(.display)), ("servers", .module(.servers)), ("settings", .settings), ("diagnostics", .diagnostics),
        ]
        for (theme, name) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let appearance = NSAppearance(named: name)!
            func save<V: View>(_ view: V, _ label: String, _ size: CGSize) {
                render(view.environment(feed).environment(notifier).environment(awake).environment(display).environment(servers), size: size, appearance: appearance,
                       to: directory.appending(path: "\(label)-\(theme).png"))
            }
            for (label, page) in pages {
                save(MainView(settings: settings, pinnedPage: page), label, CGSize(width: 1000, height: page == .settings ? 1560 : 900))
            }
            for (name, store, notifier) in ruleVariants {
                render(MainView(settings: store, pinnedPage: .settings).environment(feed).environment(notifier).environment(awake), size: CGSize(width: 1000, height: 1700),
                       appearance: appearance, to: directory.appending(path: "settings-\(name)-\(theme).png"))
            }
            for (label, tab) in [("cpu-module", ModuleTab.module), ("cpu-widgets", .widgets)] {
                save(CPUPage(settings: settings, tab: tab).padding(24).frame(width: 760, alignment: .top)
                        .background(Palette.background), label, CGSize(width: 760, height: 520))
            }
            save(CPUPopover(settings: settings, openWindow: {}, close: {}), "popover-cpu", CGSize(width: 300, height: 640))
            save(RAMPopover(settings: settings, openWindow: {}), "popover-ram", CGSize(width: 300, height: 640))
            save(GPUPopover(settings: settings, openWindow: {}), "popover-gpu", CGSize(width: 300, height: 640))
            for (label, tab) in [("gpu-module", ModuleTab.module), ("gpu-widgets", .widgets)] {
                save(GPUPage(settings: settings, tab: tab).padding(24).frame(width: 760, alignment: .top)
                        .background(Palette.background), label, CGSize(width: 760, height: 520))
            }
            save(RAMPage(settings: settings, tab: .widgets).padding(24).frame(width: 760, alignment: .top)
                    .background(Palette.background), "ram-widgets", CGSize(width: 760, height: 620))
            let sixSettings = SettingsStore(defaults: UserDefaults(suiteName: "SistemSnapshot-six")!)
            sixSettings.menuBarModules = sixWidgets.map(\.module)
            sixSettings.menuBarOrder = MenuBarOrder.sanitized(["network", "battery", "cpu"])
            save(StripOrderCard(settings: sixSettings).padding(24).frame(width: 760, alignment: .top)
                    .background(Palette.background), "settings-order", CGSize(width: 760, height: 520))
            save(DiskPopover(settings: settings, openWindow: {}), "popover-disk", CGSize(width: 300, height: 640))
            save(NetworkPopover(settings: settings, openWindow: {}), "popover-network", CGSize(width: 300, height: 640))
            for (label, tab) in [("disk-module", ModuleTab.module), ("disk-widgets", .widgets)] {
                save(DiskPage(settings: settings, tab: tab).padding(24).frame(width: 760, alignment: .top)
                        .background(Palette.background), label, CGSize(width: 760, height: 520))
            }
            for (label, tab) in [("network-module", ModuleTab.module), ("network-widgets", .widgets)] {
                save(NetworkPage(settings: settings, tab: tab).padding(24).frame(width: 760, alignment: .top)
                        .background(Palette.background), label, CGSize(width: 760, height: 520))
            }
            save(SensorsPopover(settings: settings, openWindow: {}), "popover-sensors", CGSize(width: 300, height: 640))
            for (label, tab) in [("sensors-module", ModuleTab.module), ("sensors-widgets", .widgets)] {
                save(SensorsPage(settings: settings, tab: tab).padding(24).frame(width: 760, alignment: .top)
                        .background(Palette.background), label, CGSize(width: 760, height: 520))
            }
            save(BatteryPopover(settings: settings, openWindow: {}), "popover-battery", CGSize(width: 300, height: 560))
            save(BluetoothPopover(openWindow: {}), "popover-bluetooth", CGSize(width: 300, height: 420))
            save(ClockPopover(settings: settings, openWindow: {}), "popover-clock", CGSize(width: 300, height: 640))
            for (label, tab) in [("battery-module", ModuleTab.module), ("battery-widgets", .widgets)] {
                save(BatteryPage(settings: settings, tab: tab).padding(24).frame(width: 760, alignment: .top)
                        .background(Palette.background), label, CGSize(width: 760, height: 420))
            }
            save(BluetoothPage(settings: settings, tab: .module).padding(24).frame(width: 760, alignment: .top)
                    .background(Palette.background), "bluetooth-module", CGSize(width: 760, height: 360))
            for (label, tab) in [("clock-module", ModuleTab.module), ("clock-widgets", .widgets)] {
                save(ClockPage(settings: settings, tab: tab).padding(24).frame(width: 760, alignment: .top)
                        .background(Palette.background), label, CGSize(width: 760, height: 620))
            }
            save(KeepAwakePage(settings: settings, tab: .module).padding(24).frame(width: 760, alignment: .top)
                    .background(Palette.background), "keepawake-module", CGSize(width: 760, height: 760))
            for (name, model) in awakeModels {
                let shown = SettingsStore(defaults: UserDefaults(suiteName: "SistemSnapshot")!)
                shown.keepAwakeEnabled = model.config.enabled
                render(KeepAwakePopover(settings: shown, openWindow: {}).environment(feed).environment(model), size: CGSize(width: 440, height: 520),
                       appearance: appearance, to: directory.appending(path: "popover-keepawake-\(name)-\(theme).png"))
                render(MainView(settings: shown, pinnedPage: .module(.keepAwake)).environment(feed).environment(notifier).environment(model),
                       size: CGSize(width: 1000, height: 640), appearance: appearance,
                       to: directory.appending(path: "keepawake-\(name)-\(theme).png"))
            }
            save(DisplayPage(settings: settings, tab: .module).padding(24).frame(width: 760, alignment: .top)
                    .background(Palette.background), "display-module", CGSize(width: 760, height: 460))
            for (name, preview) in displayModels {
                // The trial's deadline is relative to now; rebuild it right before drawing so it reads about 12 s.
                let model = name == "pending" ? displayPreviews()[1].1 : preview
                let shown = SettingsStore(defaults: UserDefaults(suiteName: "SistemSnapshot")!)
                shown.displayEnabled = name != "off"
                render(DisplayPopover(openWindow: {}).environment(model), size: CGSize(width: 440, height: 640),
                       appearance: appearance, to: directory.appending(path: "popover-display-\(name)-\(theme).png"))
                render(MainView(settings: shown, pinnedPage: .module(.display)).environment(feed).environment(notifier).environment(awake).environment(model),
                       size: CGSize(width: 1000, height: name == "empty" || name == "off" ? 480 : 1500), appearance: appearance,
                       to: directory.appending(path: "display-\(name)-\(theme).png"))
            }
            let serverSettings = SettingsStore(defaults: UserDefaults(suiteName: "SistemSnapshot")!)
            serverSettings.serversEnabled = true
            serverSettings.servers = serversPreviewConfigs().0
            save(ServersPage(settings: serverSettings, tab: .module).environment(servers).padding(24).frame(width: 760, alignment: .top)
                    .background(Palette.background), "servers-module", CGSize(width: 760, height: 1000))
            for (name, preview) in serverModels {
                let shown = SettingsStore(defaults: UserDefaults(suiteName: "SistemSnapshot")!)
                shown.serversEnabled = name != "off"
                render(ServersPopover(openWindow: {}).environment(preview), size: CGSize(width: 440, height: 640),
                       appearance: appearance, to: directory.appending(path: "popover-servers-\(name)-\(theme).png"))
                render(MainView(settings: shown, pinnedPage: .module(.servers)).environment(feed).environment(notifier).environment(awake).environment(display).environment(preview),
                       size: CGSize(width: 1000, height: name == "empty" || name == "off" ? 480 : 1700), appearance: appearance,
                       to: directory.appending(path: "servers-\(name)-\(theme).png"))
            }
            let diagnostics: [(String, DiagnosticsModel.Phase)] = [
                ("idle", .idle), ("ping", .done(.ping(PingResult(sent: 4, received: 4, minimum: 0.09, average: 0.11, maximum: 0.13)))),
                ("dns", .done(.dns(DNSResult(addresses: ["127.0.0.1", "::1"])))),
                ("port", .done(.port(PortResult(state: .refused, milliseconds: nil)))),
                ("trace", .done(.traceroute(TraceResult(hops: [TraceHop(index: 1, address: "192.168.1.1", milliseconds: 1.4), TraceHop(index: 2, address: nil, milliseconds: nil), TraceHop(index: 3, address: "10.0.0.1", milliseconds: 11.8)])))),
                ("error", .done(.failed(.invalidInput))), ("running", .running),
            ]
            for (name, phase) in diagnostics {
                save(DiagnosticsCard(model: DiagnosticsModel(previewing: phase)).padding(24).frame(width: 760, alignment: .top)
                        .background(Palette.background), "diagnostics-\(name)", CGSize(width: 760, height: name == "trace" ? 360 : 240))
            }
            do {
                // Input switch waiting for its confirmation.
                let entry = displayModels[0].1.state.entries[1]
                render(Card { DisplayHardwareControls(entry: entry, model: display, pendingInput: 17) }.padding(16).frame(width: 640).background(Palette.background),
                       size: CGSize(width: 640, height: 330), appearance: appearance,
                       to: directory.appending(path: "display-input-confirm-\(theme).png"))
            }
            renderStrips(feed.store, appearance: appearance, theme: theme, into: directory)
            save(RAMPage(settings: settings, tab: .module).padding(24).frame(width: 760, alignment: .top)
                    .background(Palette.background), "ram-module", CGSize(width: 760, height: 360))
            save(PopoverView(openWindow: {}), "popover", CGSize(width: 300, height: 200))
            renderWidgets(feed.store, module: .cpu, appearance: appearance, to: directory.appending(path: "menubar-\(theme).png"))
            renderWidgets(feed.store, module: .gpu, appearance: appearance, to: directory.appending(path: "menubar-gpu-\(theme).png"))
            renderWidgets(feed.store, module: .disk, appearance: appearance, to: directory.appending(path: "menubar-disk-\(theme).png"))
            renderWidgets(feed.store, module: .network, appearance: appearance, to: directory.appending(path: "menubar-network-\(theme).png"))
            renderWidgets(feed.store, module: .battery, appearance: appearance, to: directory.appending(path: "menubar-battery-\(theme).png"))
            renderWidgets(feed.store, module: .clock, clock: ClockDisplay(pattern: "EEE HH:mm"), appearance: appearance, to: directory.appending(path: "menubar-clock-\(theme).png"))
            renderWidgets(feed.store, module: .sensors, appearance: appearance, to: directory.appending(path: "menubar-sensors-\(theme).png"))
            renderWidgets(feed.store, module: .sensors, sensors: SensorsDisplay(unit: .fahrenheit, stacked: true), appearance: appearance,
                          to: directory.appending(path: "menubar-sensors-stack-\(theme).png"))
        }
    }

    /// The display module in four states: three displays (one with DDC, one without, the built-in
    /// panel), a mode trial waiting for its yes, the module switched off, and no display at all.
    private static func serversPreviewConfigs() -> ([ServerConfig], [UUID: ServerMetrics]) {
        let tunnels = [TunnelSpec(kind: .local, listenPort: 8080, targetHost: "db.internal", targetPort: 5432), TunnelSpec(kind: .dynamic, listenPort: 1080)]
        let configs = [
            ServerConfig(name: "Ev sunucusu", kind: .linux, host: "home.example.invalid", user: "ozan", tunnels: tunnels),
            ServerConfig(name: "Mac mini", kind: .macOS, host: "mini.example.invalid"),
            ServerConfig(name: "Konteynerler", kind: .docker, host: "docker.example.invalid"),
        ]
        return (configs, [:])
    }

    private static func serversPreviews() -> [(String, ServersModel)] {
        let configs = serversPreviewConfigs().0
        let now = Date()
        func make(_ config: ServerConfig, _ phase: ServerPhase, metrics: ServerMetrics? = nil) -> ServerRuntime {
            var runtime = ServerRuntime(config: config)
            runtime.phase = phase
            runtime.metrics = metrics
            return runtime
        }
        let linux = ServerMetrics(cpu: 0.37, cores: 4, memoryUsed: 5_100_000_000, memoryTotal: 8_000_000_000, swapUsed: 200_000_000, swapTotal: 1_000_000_000,
                                  load: [0.52, 0.41, 0.30], uptime: 12 * 86_400 + 5 * 3_600, diskUsed: 41_000_000_000, diskTotal: 100_000_000_000,
                                  receiveRate: 125_000, sendRate: 48_000, containers: [], date: now)
        let mac = ServerMetrics(cpu: 0.12, cores: 12, memoryUsed: 9_000_000_000, memoryTotal: 17_179_869_184, load: [1.5, 1.2, 1.0], uptime: 3 * 86_400,
                                diskUsed: 300_000_000_000, diskTotal: 500_000_000_000, receiveRate: 2_000, sendRate: 900, containers: [], date: now)
        let docker = ServerMetrics(containers: [ContainerReading(name: "web", cpuPercent: 1.5, memoryUsed: 52_000_000, memoryLimit: 2_000_000_000),
                                                ContainerReading(name: "db", cpuPercent: 38, memoryUsed: 1_200_000_000, memoryLimit: 4_000_000_000)], date: now)
        var first = make(configs[0], .online, metrics: linux)
        first.tunnels = [configs[0].tunnels[0].id: TunnelStatus(phase: .running), configs[0].tunnels[1].id: TunnelStatus(phase: .waiting(now.addingTimeInterval(8)), attempt: 2)]
        var online = ServersState()
        online.enabled = true
        online.servers = [first, make(configs[1], .online, metrics: mac), make(configs[2], .online, metrics: docker)]
        func broken(_ failures: [RemoteFailure], connecting: Bool = false) -> ServersState {
            var state = ServersState()
            state.enabled = true
            // The same names and kinds as in the online fixture, so one server looks the same in every image.
            let fleet: [(String, ServerKind)] = [("Ev sunucusu", .linux), ("Mac mini", .macOS), ("Konteynerler", .docker),
                                                 ("Yedek", .linux), ("Test", .linux), ("Ofis", .linux)]
            state.servers = failures.enumerated().map { index, failure in
                make(ServerConfig(name: fleet[index].0, kind: fleet[index].1, host: "h\(index).example.invalid"), .failed(failure))
            }
            if connecting { state.servers.append(make(ServerConfig(name: "Yeni", kind: .linux, host: "new.example.invalid"), .connecting)) }
            return state
        }
        var empty = ServersState()
        empty.enabled = true
        return [
            ("online", ServersModel(previewing: online, aliases: ["prod-web", "staging", "nas"])),
            ("failures", ServersModel(previewing: broken([.hostKeyUnknown, .authRejected, .timedOut, .hostKeyChanged, .unreachable, .badOutput], connecting: true))),
            ("empty", ServersModel(previewing: empty)),
            ("off", ServersModel(previewing: ServersState())),
        ]
    }

    private static func displayPreviews() -> [(String, DisplayModel)] {
        let builtMode = DisplayMode(id: 1, width: 1728, height: 1117, pixelWidth: 3456, pixelHeight: 2234, refreshRate: 120)
        let monitorMode = DisplayMode(id: 20, width: 2560, height: 1440, refreshRate: 200)
        let builtModes = [builtMode, DisplayMode(id: 2, width: 1728, height: 1117, pixelWidth: 3456, pixelHeight: 2234, refreshRate: 60),
                          DisplayMode(id: 3, width: 1512, height: 982, pixelWidth: 3024, pixelHeight: 1964, refreshRate: 120)]
        let monitorModes = [monitorMode, DisplayMode(id: 21, width: 2560, height: 1440, refreshRate: 144), DisplayMode(id: 22, width: 2560, height: 1440, refreshRate: 60),
                            DisplayMode(id: 23, width: 1920, height: 1080, refreshRate: 120)]
        var builtIn = DisplayEntry(info: DisplayInfo(id: 1, name: "Built-in Liquid Retina XDR Display", isBuiltIn: true, isMain: true, mode: builtMode,
                                                     edrCurrent: 1.2, edrPotential: 16, brightness: 0.62))
        builtIn.modes = builtModes
        builtIn.ddc = .unsupported(.builtIn)
        var monitor = DisplayEntry(info: DisplayInfo(id: 4, name: "LS27FG53x", vendor: 0x4C2D, model: 0x79CF, mode: monitorMode))
        monitor.modes = monitorModes
        monitor.ddc = .supported
        monitor.controls = [.brightness: VCPValue(current: 70, maximum: 100), .contrast: VCPValue(current: 79, maximum: 100),
                            .volume: VCPValue(current: 63, maximum: 100), .inputSource: VCPValue(current: 15, maximum: 14)]
        monitor.dim = 0.8
        monitor.warmth = 0.25
        var sidecar = DisplayEntry(info: DisplayInfo(id: 6, name: "iPad", isMirrored: true,
                                                     mode: DisplayMode(id: 30, width: 1180, height: 820, pixelWidth: 2360, pixelHeight: 1640, refreshRate: 60)))
        sidecar.modes = [sidecar.info.mode!]
        sidecar.ddc = .unsupported(.noChannel)
        let now = Date()
        var state = DisplayState()
        state.entries = [builtIn, monitor, sidecar]
        state.events = [
            DisplayEvent(id: 3, date: now.addingTimeInterval(-120), kind: .modeChanged, name: "LS27FG53x", detail: "2560 × 1440 · 200 Hz"),
            DisplayEvent(id: 2, date: now.addingTimeInterval(-3_000), kind: .connected, name: "iPad", detail: "1180 × 820 · 60 Hz"),
            DisplayEvent(id: 1, date: now.addingTimeInterval(-3_100), kind: .disconnected, name: "iPad"),
        ]
        var trial = state
        trial.pending = PendingModeChange(display: 4, from: monitorMode, to: monitorModes[2], deadline: now.addingTimeInterval(12))
        trial.entries[1].info.mode = monitorModes[2]
        return [("on", DisplayModel(previewing: state)), ("pending", DisplayModel(previewing: trial)),
                ("off", DisplayModel(previewing: DisplayState())), ("empty", DisplayModel(previewing: DisplayState()))]
    }

    /// Ten minutes of plausible-looking load: a slow wave with bursts.
    private static func syntheticStore() -> MetricStore {
        let store = MetricStore()
        let cores = Int(Sysctl.integer("hw.logicalcpu") ?? 8)
        for i in 0..<MetricStore.historyLength {
            let t = Float(i) / 18
            let user = 0.12 + 0.08 * sin(t) + (i % 47 < 5 ? 0.35 : 0)
            let system = 0.05 + 0.02 * cos(t * 1.7)
            let perCore = (0..<cores).map { c in min(1, max(0, user + system + 0.25 * sin(t + Float(c)))) }
            store.ingest(Snapshot(cpu: CPUSample(
                user: user, system: system, cores: perCore,
                loadAverage: LoadAverage(one: 3.42, five: 2.87, fifteen: 2.51))))
        }
        let gb: UInt64 = 1 << 30
        for i in 0..<MetricStore.historyLength {
            let t = Double(i) / 25
            let app = UInt64((13.5 + 1.5 * sin(t)) * Double(gb))
            store.ingest(Snapshot(memory: MemorySample(
                total: 48 * gb, app: app, wired: 4 * gb, compressed: UInt64((4 + 0.5 * cos(t)) * Double(gb)),
                cached: 13 * gb, swapUsed: 0, swapTotal: gb, pressure: .normal)))
        }
        let mb: UInt64 = 1 << 20
        for i in 0..<MetricStore.historyLength {
            let t = Float(i) / 20
            let device = min(1, max(0, 0.18 + 0.12 * sin(t) + (i % 61 < 9 ? 0.55 : 0)))
            store.ingest(Snapshot(gpu: GPUSample(
                device: device, renderer: device * 0.92, tiler: device * 0.35,
                memoryInUse: 1_240 * mb, memoryAllocated: 3_980 * mb)))
            store.ingest(Snapshot(power: PowerSample(
                cpu: 5.4 + 3 * sin(t), gpu: 0.4 + device * 28, ane: 0, system: 17.2 + device * 30)))
        }
        store.ingest(Snapshot(assertions: AssertionSample(holders: [
            AwakeHolder(pid: 4_101, processName: "caffeinate", preventsDisplaySleep: false, reason: "caffeinate command-line tool"),
            AwakeHolder(pid: 4_212, processName: "Safari", preventsDisplaySleep: true, reason: "Video playback"),
            AwakeHolder(pid: 4_390, processName: "Sistem", preventsDisplaySleep: false, reason: "", isSelf: true),
        ])))
        store.ingest(Snapshot(cpuFrequency: CPUFrequencySample(clusters: [
            .init(name: "Super", coreCount: 6, activeFraction: 0.31, performanceLevel: 0.78, averageMHz: 3_650, maxMHz: 4_608),
            .init(name: "Performance", coreCount: 12, activeFraction: 0.12, performanceLevel: 0.34, averageMHz: 2_010, maxMHz: 4_380),
        ])))
        addDiskAndNetwork(to: store)
        addSensors(to: store)
        addBatteryAndBluetooth(to: store)
        let names = ["Safari", "WindowServer", "Xcode", "Google Chrome Helper (Renderer)", "kernel_task", "Finder", "mds_stores", "Music"]
        let entries = names.enumerated().map { i, name in
            ProcessEntry(pid: pid_t(900 + i), name: name, cpu: Float(names.count - i) * 0.07,
                         memory: UInt64(names.count - i) * 380 * 1_048_576, memoryIsApproximate: i == 1 || i == 4,
                         milliwatts: i == 1 || i == 4 ? nil : Float(names.count - i) * 95)
        }
        store.ingest(Snapshot(processes: ProcessSample(topCPU: entries, topMemory: entries, processCount: 1004)))
        return store
    }

    /// A Mac17,8-shaped sensor list with a load wave in the temperatures, two fans, and the
    /// handful of voltage, current and power rows.
    private static func addSensors(to store: MetricStore) {
        var sensors: [SensorInfo] = []
        func add(_ prefix: String, _ count: Int, _ kind: SensorKind, _ group: SensorGroup, _ base: SensorLabelBase?) {
            for i in 0..<count {
                let key = "\(prefix)\(String(format: "%02d", i))"
                sensors.append(SensorInfo(key: key, kind: kind, group: group, label: base.map { .indexed($0, i + 1) } ?? .raw(key)))
            }
        }
        add("Tp", 23, .temperature, .cpuSuper, .superCore)
        add("Tm", 40, .temperature, .cpuPerformance, .performanceCore)
        add("Tg", 42, .temperature, .gpu, .gpuUnit)
        sensors.append(SensorInfo(key: "TCMb", kind: .temperature, group: .soc, label: .named(.socHotspot)))
        add("TPD", 16, .temperature, .soc, .socCPU)
        add("TH", 3, .temperature, .ssd, .nand)
        add("TB", 3, .temperature, .battery, .battery)
        add("Ts", 6, .temperature, .other, nil)
        sensors.append(SensorInfo(key: "VD0R", kind: .voltage, group: .other, label: .named(.dcIn)))
        sensors.append(SensorInfo(key: "Vb0f", kind: .voltage, group: .other, label: .named(.batteryPack)))
        sensors.append(SensorInfo(key: "ID0R", kind: .current, group: .other, label: .named(.dcIn)))
        sensors.append(SensorInfo(key: "Ib0f", kind: .current, group: .other, label: .named(.batteryPack)))
        sensors.append(SensorInfo(key: "PSTR", kind: .power, group: .other, label: .named(.system)))
        sensors.append(SensorInfo(key: "PDTR", kind: .power, group: .other, label: .named(.adapter)))
        sensors.append(SensorInfo(key: "PPMC", kind: .power, group: .other, label: .named(.cpu)))
        let fans = [FanInfo(index: 0, minRPM: 1_350, maxRPM: 5_349), FanInfo(index: 1, minRPM: 1_350, maxRPM: 5_777)]
        let catalog = SensorCatalog(model: "Mac17,8", isKnownModel: true, sensors: sensors, fans: fans)
        for i in 0..<MetricStore.historyLength {
            let t = Float(i) / 14
            let load = max(0, 0.35 + 0.25 * sin(t) + (i % 53 < 9 ? 0.3 : 0))
            let cpu = 44 + 38 * load
            let gpu = 40 + 12 * load
            var values: [Float?] = []
            for (n, info) in sensors.enumerated() {
                let wobble = Float(n % 7) * 0.45
                let value: Float? = switch (info.kind, info.group) {
                case (.temperature, .cpuSuper): cpu - wobble
                case (.temperature, .cpuPerformance): cpu - 7 - wobble
                case (.temperature, .gpu): gpu - wobble * 0.3
                case (.temperature, .soc): cpu - 8 - wobble
                case (.temperature, .ssd): 36 + load * 4
                case (.temperature, .battery): 29.5
                case (.temperature, _): 27 + Float(n % 5) * 3 + load * 4
                case (.voltage, _): info.key == "VD0R" ? 27.4 : 12.53
                case (.current, _): info.key == "ID0R" ? 0.4 + load * 2 : 0.03
                case (.power, _): info.key == "PPMC" ? 3 + load * 30 : 9 + load * 55
                default: nil
                }
                values.append(value)
            }
            let hottest = values.enumerated().compactMap { catalog.sensors[$0.offset].group == .cpuSuper || catalog.sensors[$0.offset].group == .cpuPerformance ? $0.element : nil }
            let temperature = TemperatureSample(cpuHottest: hottest.max(), cpuAverage: hottest.reduce(0, +) / Float(hottest.count),
                                                gpuHottest: gpu, hottest: hottest.max())
            let rpm: Float = 1_350 + load * 900
            store.ingest(Snapshot(
                temperature: temperature,
                sensors: SensorSample(catalog: catalog, values: values,
                                      fans: fans.map { FanReading(info: $0, rpm: rpm + Float($0.index) * 40) },
                                      temperature: temperature)))
        }
    }

    /// A discharging battery with health figures, and a handful of made-up Bluetooth devices.
    private static func addBatteryAndBluetooth(to store: MetricStore) {
        store.ingest(Snapshot(battery: .present(BatterySample(
            percent: 64, state: .charging, minutesRemaining: 85,
            health: BatteryHealth(maximumCapacityPercent: 97, designCapacity: 8_579, nominalCapacity: 8_320, cycleCount: 212, designCycleCount: 1_000,
                                  temperatureCelsius: 31.4, volts: 12.62, amps: 1.84, systemWatts: 9.6),
            adapter: AdapterInfo(watts: 140, name: "140W USB-C Power Adapter")))))
        store.ingest(Snapshot(bluetooth: BluetoothSample(isPoweredOn: true, devices: [
            BluetoothDevice(id: "AA:BB:CC:00:00:01", name: "Kulaklık", isConnected: true, kind: .headphones,
                            batteries: [.init(part: .left, percent: 100), .init(part: .right, percent: 90), .init(part: .case, percent: 45)]),
            BluetoothDevice(id: "AA:BB:CC:00:00:02", name: "Klavye", isConnected: true, kind: .keyboard, batteries: [.init(part: .main, percent: 67)]),
            BluetoothDevice(id: "AA:BB:CC:00:00:03", name: "Fare", isConnected: true, kind: .mouse, batteries: [.init(part: .main, percent: 14)]),
            BluetoothDevice(id: "AA:BB:CC:00:00:04", name: "Hoparlör", isConnected: false, kind: .speaker),
        ], access: .allowed)))
    }

    /// Bursty drive and network traffic, two volumes, SMART figures, a Wi-Fi link and a short connection history.
    private static func addDiskAndNetwork(to store: MetricStore) {
        let gb: UInt64 = 1_000_000_000
        let volumes = [
            DiskVolume(name: "Macintosh HD", mountPoint: "/", total: 1_000 * gb, available: 412 * gb, kind: .internalDisk, format: "APFS", isBoot: true),
            DiskVolume(name: "Yedek", mountPoint: "/Volumes/Yedek", total: 2_000 * gb, available: 1_830 * gb, kind: .external, format: "exFAT"),
        ]
        for i in 0..<MetricStore.historyLength {
            let t = Double(i) / 22
            let burst = i % 53 < 7 ? 1.0 : 0.0
            let read = max(0, 180_000 + 120_000 * sin(t) + burst * 640_000_000)
            let write = max(0, 90_000 + 60_000 * cos(t * 1.3) + (i % 71 < 5 ? 210_000_000 : 0))
            let device = DiskDeviceRate(id: 1, name: "APPLE SSD AP1024Z", bsdName: "disk0", isInternal: true, readRate: read, writeRate: write)
            store.ingest(Snapshot(disk: DiskSample(readRate: read, writeRate: write, readOps: read / 60_000, writeOps: write / 50_000,
                                                   devices: [device], interval: 2, volumes: i == 0 ? volumes : nil)))
            let down = max(0, 420_000 + 300_000 * sin(t * 0.8) + (i % 89 < 12 ? 38_000_000 : 0))
            let up = max(0, 60_000 + 40_000 * cos(t) + (i % 97 < 6 ? 4_500_000 : 0))
            store.ingest(Snapshot(network: NetworkSample(
                down: down, up: up, totalDown: 18 * gb, totalUp: 2 * gb,
                interfaces: [
                    NetworkInterfaceRate(name: "en0", down: down, up: up, totalDown: 18 * gb, totalUp: 2 * gb),
                    NetworkInterfaceRate(name: "en5", down: 0, up: 0, totalDown: 12_000_000, totalUp: 3_000_000),
                ], primary: "en0")))
        }
        store.ingest(Snapshot(diskHealth: DiskHealth(
            criticalWarning: 0, temperatureCelsius: 38, availableSpare: 100, availableSpareThreshold: 99, percentageUsed: 2,
            bytesRead: 64_300 * gb, bytesWritten: 41_800 * gb, powerCycles: 212, powerOnHours: 1_536, unsafeShutdowns: 9, mediaErrors: 0)))
        let wifi = PathState.Interface(name: "en0", type: .wifi)
        let path = PathState(status: .satisfied, interfaces: [wifi, .init(name: "en5", type: .wired)], primary: wifi)
        let now = Date()
        store.ingest(Snapshot(
            networkInfo: NetworkInfoSample(
                wifi: WiFiSample(interfaceName: "en0", isAssociated: true, rssi: -52, noise: -92, channel: 36, band: .ghz5, transmitRate: 866),
                addresses: [LocalAddress(interface: "en0", address: "192.168.1.24", isIPv6: false),
                            LocalAddress(interface: "en0", address: "fe80::1c2a:5bff:fe3e:91a2", isIPv6: true),
                            LocalAddress(interface: "en5", address: "10.0.0.8", isIPv6: false)]),
            path: path,
            connectionEvents: [
                ConnectionEvent(id: 0, date: now.addingTimeInterval(-5_400), kind: .connected, interface: wifi),
                ConnectionEvent(id: 1, date: now.addingTimeInterval(-3_100), kind: .disconnected, interface: nil),
                ConnectionEvent(id: 2, date: now.addingTimeInterval(-3_060), kind: .connected, interface: wifi),
            ]))
    }

    /// Sections joined into the single menu bar strip, drawn on a menu-bar-coloured background with margins.
    /// The six-widget set of the idle measurement, as arguments: `-menuBarModules` and `-menuBarWidgets` (see the report).
    static let sixWidgets: [(module: ModuleID, config: WidgetConfig)] = [
        (.cpu, WidgetConfig(kinds: [.text, .bars], showLabel: true)),
        (.ram, WidgetConfig(kinds: [.text, .sparkline], showLabel: true)),
        (.gpu, WidgetConfig(kinds: [.text, .ring], showLabel: true)),
        (.network, WidgetConfig(kinds: [.arrows, .sparkline], showLabel: false)),
        (.sensors, WidgetConfig(kinds: [.text, .chart], showLabel: true)),
        (.battery, WidgetConfig(kinds: [.battery, .text], showLabel: false)),
    ]

    private static func renderStrip(_ sections: [any StripSection], appearance: NSAppearance, to url: URL) {
        let height = NSStatusBar.system.thickness
        let margin: CGFloat = 8
        let strip = StripView(frame: NSRect(x: margin, y: 0, width: 10, height: height))
        strip.setSections(sections)
        strip.setFrameSize(NSSize(width: strip.layoutModel.totalWidth, height: height))
        let background = NSView(frame: NSRect(x: 0, y: 0, width: strip.layoutModel.totalWidth + 2 * margin, height: height))
        background.wantsLayer = true
        background.appearance = appearance
        background.layer?.backgroundColor = (appearance.name == .darkAqua ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).cgColor
        background.addSubview(strip)
        let window = NSWindow(contentRect: background.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = background
        background.layoutSubtreeIfNeeded()
        guard let rep = background.bitmapImageRepForCachingDisplay(in: background.bounds) else { return }
        background.cacheDisplay(in: background.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        sections.forEach { $0.remove() }
    }

    private static func widget(_ module: ModuleID, _ store: MetricStore, config: WidgetConfig = .default, sensors: SensorsDisplay = SensorsDisplay(),
                               clock: ClockDisplay = ClockDisplay(pattern: "EEE HH:mm")) -> any StripSection {
        if module == .bluetooth { return IconSection(kind: .module(.bluetooth), symbol: ModuleID.bluetooth.symbol, title: "Bluetooth") }
        return WidgetSection(module: module, config: config, sensors: sensors, clock: clock, source: .fixed(store))
    }

    /// One module's widget configurations side by side in a strip.
    private static func renderWidgets(_ store: MetricStore, module: ModuleID, sensors: SensorsDisplay = SensorsDisplay(), clock: ClockDisplay? = nil, appearance: NSAppearance, to url: URL) {
        // The module's own default, each kind it supports alone, and all of them together.
        let supported = WidgetKind.supported(by: module)
        var configs: [WidgetConfig] = [.initial(for: module)]
        configs += supported.map { WidgetConfig(kinds: [$0], showLabel: false) }
        if module != .clock { configs.append(WidgetConfig(kinds: Set(supported), showLabel: true)) }
        renderStrip(configs.map { widget(module, store, config: $0, sensors: sensors, clock: clock ?? ClockDisplay(pattern: "EEE HH:mm")) },
                    appearance: appearance, to: url)
    }

    /// The whole strip in its typical shapes: the default three, everything on, a single section, and the cup in its three looks.
    private static func renderStrips(_ store: MetricStore, appearance: NSAppearance, theme: String, into directory: URL) {
        func cup(holding: Bool, blocked: Bool) -> any StripSection {
            IconSection(kind: .keepAwake, symbol: IconSection.cupSymbol(holding: holding, blocked: blocked), title: "Uyanık Tut")
        }
        func icon(_ kind: StripKind, _ symbol: String) -> any StripSection { IconSection(kind: kind, symbol: symbol, title: symbol) }
        renderStrip([widget(.cpu, store), widget(.ram, store), widget(.sensors, store)], appearance: appearance,
                    to: directory.appending(path: "menubar-strip-default-\(theme).png"))
        var everything: [any StripSection] = ModuleID.menuBarCandidates.map { widget($0, store, config: .initial(for: $0)) }
        everything += [cup(holding: true, blocked: false), icon(.display, "display"), icon(.servers, "server.rack")]
        renderStrip(everything, appearance: appearance, to: directory.appending(path: "menubar-strip-all-\(theme).png"))
        renderStrip([widget(.cpu, store)], appearance: appearance, to: directory.appending(path: "menubar-strip-single-\(theme).png"))
        // Six widgets, each in a different new kind: the strip the idle measurement runs with.
        renderStrip(sixWidgets.map { widget($0.module, store, config: $0.config) }, appearance: appearance,
                    to: directory.appending(path: "menubar-strip-six-\(theme).png"))
        // One section per kind a module can draw, on a single strip.
        let kindSections: [any StripSection] = ModuleID.menuBarCandidates.flatMap { module in
            WidgetKind.supported(by: module).map { widget(module, store, config: WidgetConfig(kinds: [$0], showLabel: false)) }
        }
        renderStrip(kindSections, appearance: appearance, to: directory.appending(path: "menubar-strip-kinds-\(theme).png"))
        // The same sections in the user's order: network first, the cup last.
        renderStrip([widget(.network, store, config: .initial(for: .network)), widget(.cpu, store), widget(.ram, store), cup(holding: true, blocked: false)],
                    appearance: appearance, to: directory.appending(path: "menubar-strip-reordered-\(theme).png"))
        renderStrip([widget(.cpu, store), widget(.ram, store), cup(holding: false, blocked: false)], appearance: appearance,
                    to: directory.appending(path: "menubar-strip-cup-off-\(theme).png"))
        renderStrip([widget(.cpu, store), widget(.ram, store), cup(holding: true, blocked: false)], appearance: appearance,
                    to: directory.appending(path: "menubar-strip-cup-on-\(theme).png"))
        renderStrip([widget(.cpu, store), widget(.ram, store), cup(holding: false, blocked: true)], appearance: appearance,
                    to: directory.appending(path: "menubar-strip-cup-warning-\(theme).png"))
    }

    private static func render<V: View>(_ view: V, size: CGSize, appearance: NSAppearance, to url: URL) {
        let host = NSHostingView(rootView: view)
        host.appearance = appearance
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: .now + 0.4)  // let SwiftUI commit a frame
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
