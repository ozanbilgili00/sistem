import CoreBluetooth
import Foundation
import IOBluetooth
import Synchronization

/// Paired Bluetooth devices with their connection state and, where the device reports
/// it, battery levels. Device names and addresses are personal data: they live in
/// memory for the page that shows them and are never logged.
public struct BluetoothSample: Sendable, Equatable {
    public var isPoweredOn: Bool?
    public var devices: [BluetoothDevice]
    public var access: BluetoothAccess

    public init(isPoweredOn: Bool?, devices: [BluetoothDevice], access: BluetoothAccess = .notDetermined) {
        self.isPoweredOn = isPoweredOn
        self.devices = devices
        self.access = access
    }

    public var connected: [BluetoothDevice] { devices.filter(\.isConnected) }
}

public struct BluetoothDevice: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case headphones, speaker, keyboard, mouse, trackpad, gamepad, phone, other
    }

    public struct Battery: Sendable, Equatable {
        public enum Part: String, Sendable { case main, left, right, `case` }
        public var part: Part
        /// 0...100.
        public var percent: Int

        public init(part: Part, percent: Int) {
            self.part = part
            self.percent = percent
        }
    }

    /// Normalised address, `AA:BB:CC:DD:EE:FF`.
    public var id: String
    public var name: String
    public var isConnected: Bool
    public var kind: Kind
    public var batteries: [Battery]

    public init(id: String, name: String, isConnected: Bool, kind: Kind = .other, batteries: [Battery] = []) {
        self.id = id
        self.name = name
        self.isConnected = isConnected
        self.kind = kind
        self.batteries = batteries
    }

    /// The lowest level among the parts (the earbud that will die first).
    public var lowestBattery: Int? { batteries.map(\.percent).min() }
}

/// Where the Bluetooth privacy permission stands. `IOBluetooth` goes through CoreBluetooth on
/// recent macOS and blocks the calling thread until the person has decided, so it is called only
/// once access is `allowed`. Everything else comes from `system_profiler`, which needs no permission.
public enum BluetoothAccess: String, Sendable {
    case notDetermined, allowed, denied, restricted

    public static var current: BluetoothAccess {
        switch CBManager.authorization {
        case .allowedAlways: .allowed
        case .denied: .denied
        case .restricted: .restricted
        default: .notDetermined
        }
    }

    @MainActor private static var manager: CBCentralManager?

    /// Shows the system prompt (if still undecided). Only ever called from a button.
    @MainActor public static func request() {
        guard current == .notDetermined, manager == nil else { return }
        manager = CBCentralManager(delegate: nil, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }
}

/// Parses `system_profiler SPBluetoothDataType -json`.
public enum BluetoothProfile {
    static let maximumDevices = 200

    public static func parse(_ data: Data, access: BluetoothAccess = .notDetermined) -> BluetoothSample? {
        guard !data.isEmpty, data.count < 4_000_000,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]], let section = sections.first else { return nil }
        var powered: Bool?
        if let controller = section["controller_properties"] as? [String: Any],
           let state = controller["controller_state"] as? String {
            powered = state == "attrib_on"
        }
        var byName: [String: BluetoothDevice] = [:]
        var order: [String] = []
        for (key, connected) in [("device_connected", true), ("device_not_connected", false)] {
            guard let entries = section[key] as? [[String: Any]] else { continue }
            for entry in entries.prefix(maximumDevices) {
                for (rawName, value) in entry {
                    guard let properties = value as? [String: Any],
                          let device = device(named: rawName, properties: properties, connected: connected) else { continue }
                    // A headset shows up twice (classic and LE address): one row, connected if either is.
                    let identity = device.name.lowercased()
                    if var existing = byName[identity] {
                        existing.isConnected = existing.isConnected || device.isConnected
                        for battery in device.batteries where !existing.batteries.contains(where: { $0.part == battery.part }) {
                            existing.batteries.append(battery)
                        }
                        if existing.kind == .other { existing.kind = device.kind }
                        byName[identity] = existing
                    } else {
                        byName[identity] = device
                        order.append(identity)
                    }
                }
            }
        }
        return BluetoothSample(isPoweredOn: powered, devices: order.compactMap { byName[$0] }, access: access)
    }

    static func device(named rawName: String, properties: [String: Any], connected: Bool) -> BluetoothDevice? {
        let name = String(rawName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        guard !name.isEmpty else { return nil }
        let address = normalizedAddress(properties["device_address"] as? String) ?? "name:" + name.lowercased()
        var batteries: [BluetoothDevice.Battery] = []
        for (key, part) in [("device_batteryLevelMain", BluetoothDevice.Battery.Part.main), ("device_batteryLevel", .main),
                            ("device_batteryLevelLeft", .left), ("device_batteryLevelRight", .right), ("device_batteryLevelCase", .case)] {
            guard !batteries.contains(where: { $0.part == part }), let percent = percent(properties[key]) else { continue }
            batteries.append(.init(part: part, percent: percent))
        }
        return BluetoothDevice(id: address, name: name, isConnected: connected,
                               kind: kind(properties["device_minorType"] as? String), batteries: batteries)
    }

    /// "%80" or "80%" or 80 → 80; anything outside 0...100 is not a battery level.
    static func percent(_ value: Any?) -> Int? {
        let number: Int?
        switch value {
        case let text as String: number = Int(text.filter(\.isNumber))
        case let n as Int: number = n
        default: number = nil
        }
        guard let number, (0...100).contains(number) else { return nil }
        return number
    }

    static func normalizedAddress(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let hex = raw.uppercased().replacingOccurrences(of: "-", with: ":")
        let parts = hex.split(separator: ":")
        guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else { return nil }
        return parts.joined(separator: ":")
    }

    static func kind(_ minorType: String?) -> BluetoothDevice.Kind {
        guard let text = minorType?.lowercased() else { return .other }
        if text.contains("head") || text.contains("earb") || text.contains("airpod") { return .headphones }
        if text.contains("speaker") || text.contains("loud") { return .speaker }
        if text.contains("keyboard") { return .keyboard }
        if text.contains("trackpad") { return .trackpad }
        if text.contains("mouse") { return .mouse }
        if text.contains("game") || text.contains("joystick") { return .gamepad }
        if text.contains("phone") { return .phone }
        return .other
    }
}

/// Lists Bluetooth devices. Reading means running `system_profiler` (~70 ms of a short-lived
/// child process), so it happens only when asked: the sampler asks every 30th tick while a
/// Bluetooth page or popover is on screen, and never otherwise (PLAN.md §3-B).
public final class BluetoothReader: @unchecked Sendable {
    /// Every `system_profiler` launch of this process. The gate "Bluetooth closed → 0 calls".
    public static let launches = Mutex(0)
    public static var launchCount: Int { launches.withLock { $0 } }

    /// Tests replace the child process with canned output.
    var runner: @Sendable () -> Data? = BluetoothReader.runSystemProfiler
    private let inFlight = Mutex(false)
    private let ioBluetoothBroken = Mutex(false)

    public init() {}

    /// Starts a read unless one is running; `completion` is called once, on a background queue.
    /// Returns false when a read was already in flight.
    @discardableResult
    public func refresh(_ completion: @escaping @Sendable (BluetoothSample?) -> Void) -> Bool {
        guard inFlight.withLock({ if $0 { return false } else { $0 = true; return true } }) else { return false }
        DispatchQueue.global(qos: .utility).async { [self] in
            let access = BluetoothAccess.current
            var sample = runner().flatMap { BluetoothProfile.parse($0, access: access) }
            if access == .allowed, var current = sample { // live connection state, only where allowed
                merge(pairedDevices(), into: &current)
                sample = current
            }
            inFlight.withLock { $0 = false }
            completion(sample)
        }
        return true
    }

    // MARK: system_profiler

    static let executable = "/usr/sbin/system_profiler"
    static let arguments = ["SPBluetoothDataType", "-json"]
    static let timeout: TimeInterval = 10
    static let maximumOutput = 4_000_000

    /// Fixed argument array, no shell. The output is size-capped here and validated by the parser.
    static func runSystemProfiler() -> Data? {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin", "LC_ALL": "en_US.UTF-8"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        launches.withLock { $0 += 1 }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        var output = Data()
        let reader = pipe.fileHandleForReading
        while let chunk = try? reader.read(upToCount: 65_536), !chunk.isEmpty {
            output.append(chunk)
            if output.count > maximumOutput {
                process.terminate()
                break
            }
        }
        process.waitUntilExit()
        watchdog.cancel()
        try? reader.close()
        return process.terminationStatus == 0 && output.count <= maximumOutput ? output : nil
    }

    // MARK: IOBluetooth

    private struct Paired { var id: String; var name: String; var connected: Bool }

    /// `IOBluetoothDevice.pairedDevices()` on its own thread with a 3 s limit: if the coordinator
    /// does not answer, it is never called again in this session and the thread is abandoned.
    private func pairedDevices() -> [Paired]? {
        if ioBluetoothBroken.withLock({ $0 }) { return nil }
        let result = Mutex<[Paired]?>(nil)
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
            let list = devices.compactMap { device -> Paired? in
                guard let name = device.name, let id = BluetoothProfile.normalizedAddress(device.addressString) else { return nil }
                return Paired(id: id, name: String(name.prefix(64)), connected: device.isConnected())
            }
            result.withLock { $0 = list }
            done.signal()
        }
        thread.qualityOfService = .utility
        thread.start()
        if done.wait(timeout: .now() + 3) == .timedOut {
            ioBluetoothBroken.withLock { $0 = true }
            return nil
        }
        return result.withLock { $0 }
    }

    private func merge(_ paired: [Paired]?, into sample: inout BluetoothSample) {
        guard let paired else { return }
        for device in paired {
            if let index = sample.devices.firstIndex(where: { $0.id == device.id || $0.name.lowercased() == device.name.lowercased() }) {
                sample.devices[index].isConnected = device.connected
            } else if sample.devices.count < BluetoothProfile.maximumDevices {
                sample.devices.append(BluetoothDevice(id: device.id, name: device.name, isConnected: device.connected))
            }
        }
    }
}
