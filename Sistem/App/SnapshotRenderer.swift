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
        let settings = SettingsStore(defaults: defaults)
        let feed = LiveFeed(store: syntheticStore(), engine: nil)
        feed.isActive = true

        let pages: [(String, Page)] = [
            ("dashboard", .module(.dashboard)), ("cpu", .module(.cpu)), ("gpu", .module(.gpu)), ("ram", .module(.ram)),
            ("disk", .module(.disk)), ("network", .module(.network)), ("settings", .settings), ("diagnostics", .diagnostics),
        ]
        for (theme, name) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let appearance = NSAppearance(named: name)!
            func save<V: View>(_ view: V, _ label: String, _ size: CGSize) {
                render(view.environment(feed), size: size, appearance: appearance,
                       to: directory.appending(path: "\(label)-\(theme).png"))
            }
            for (label, page) in pages {
                save(MainView(settings: settings, pinnedPage: page), label, CGSize(width: 1000, height: 900))
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
            save(RAMPage(settings: settings, tab: .module).padding(24).frame(width: 760, alignment: .top)
                    .background(Palette.background), "ram-module", CGSize(width: 760, height: 360))
            save(PopoverView(openWindow: {}), "popover", CGSize(width: 300, height: 200))
            renderWidgets(feed.store, module: .cpu, appearance: appearance, to: directory.appending(path: "menubar-\(theme).png"))
            renderWidgets(feed.store, module: .gpu, appearance: appearance, to: directory.appending(path: "menubar-gpu-\(theme).png"))
            renderWidgets(feed.store, module: .disk, appearance: appearance, to: directory.appending(path: "menubar-disk-\(theme).png"))
            renderWidgets(feed.store, module: .network, appearance: appearance, to: directory.appending(path: "menubar-network-\(theme).png"))
        }
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
        store.ingest(Snapshot(cpuFrequency: CPUFrequencySample(clusters: [
            .init(name: "Super", coreCount: 6, activeFraction: 0.31, performanceLevel: 0.78, averageMHz: 3_650, maxMHz: 4_608),
            .init(name: "Performance", coreCount: 12, activeFraction: 0.12, performanceLevel: 0.34, averageMHz: 2_010, maxMHz: 4_380),
        ])))
        addDiskAndNetwork(to: store)
        let names = ["Safari", "WindowServer", "Xcode", "Google Chrome Helper (Renderer)", "kernel_task", "Finder", "mds_stores", "Music"]
        let entries = names.enumerated().map { i, name in
            ProcessEntry(pid: pid_t(900 + i), name: name, cpu: Float(names.count - i) * 0.07,
                         memory: UInt64(names.count - i) * 380 * 1_048_576, memoryIsApproximate: i == 1 || i == 4,
                         milliwatts: i == 1 || i == 4 ? nil : Float(names.count - i) * 95)
        }
        store.ingest(Snapshot(processes: ProcessSample(topCPU: entries, topMemory: entries, processCount: 1004)))
        return store
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

    /// The menu bar widget configurations side by side on a menu-bar-coloured strip.
    private static func renderWidgets(_ store: MetricStore, module: ModuleID, appearance: NSAppearance, to url: URL) {
        let configs: [WidgetConfig] = [
            .default,
            WidgetConfig(kinds: [.text], showLabel: false),
            WidgetConfig(kinds: [.chart], showLabel: false),
            WidgetConfig(kinds: [.ring], showLabel: false),
            WidgetConfig(kinds: [.text, .chart, .ring], showLabel: true),
        ]
        let height = NSStatusBar.system.thickness
        let strip = NSView(frame: .zero)
        strip.wantsLayer = true
        strip.appearance = appearance
        var x: CGFloat = 8
        for config in configs {
            let view = WidgetView(frame: NSRect(x: x, y: 0, width: 200, height: height))
            view.widestText = WidgetModel.widestText(for: module)
            view.update(.make(module, store: store), config: config)
            view.setFrameSize(NSSize(width: view.intrinsicWidth, height: height))
            strip.addSubview(view)
            x += view.intrinsicWidth + 14
        }
        strip.frame = NSRect(x: 0, y: 0, width: x, height: height)
        strip.layer?.backgroundColor = (appearance.name == .darkAqua ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).cgColor
        let window = NSWindow(contentRect: strip.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = strip
        strip.layoutSubtreeIfNeeded()
        guard let rep = strip.bitmapImageRepForCachingDisplay(in: strip.bounds) else { return }
        strip.cacheDisplay(in: strip.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
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
