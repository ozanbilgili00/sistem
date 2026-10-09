import Darwin
import DiskArbitration
import Foundation
import IOKit
import Synchronization

/// One mounted, user-visible volume (what Finder lists).
public struct DiskVolume: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case internalDisk, external, removable, network
    }

    public var name: String
    public var mountPoint: String
    public var total: UInt64
    /// `volumeAvailableCapacityForImportantUsage`: free space plus what macOS would
    /// purge on demand, i.e. the number Finder shows.
    public var available: UInt64
    public var kind: Kind
    /// "APFS", "Mac OS Extended"… as the system words it.
    public var format: String?
    public var isBoot: Bool

    public var id: String { mountPoint }
    public var used: UInt64 { total - min(available, total) }
    public var usedFraction: Float { total == 0 ? 0 : Float(Double(used) / Double(total)) }

    public init(name: String, mountPoint: String, total: UInt64, available: UInt64, kind: Kind,
                format: String? = nil, isBoot: Bool = false) {
        self.name = name
        self.mountPoint = mountPoint
        self.total = total
        self.available = available
        self.kind = kind
        self.format = format
        self.isBoot = isBoot
    }
}

/// Throughput of one physical drive over the last interval, bytes per second.
public struct DiskDeviceRate: Sendable, Equatable, Identifiable {
    public var id: UInt64
    /// "APPLE SSD AP1024Z"
    public var name: String
    public var bsdName: String?
    public var isInternal: Bool
    public var readRate: Double
    public var writeRate: Double

    public init(id: UInt64, name: String, bsdName: String?, isInternal: Bool, readRate: Double, writeRate: Double) {
        self.id = id
        self.name = name
        self.bsdName = bsdName
        self.isInternal = isInternal
        self.readRate = readRate
        self.writeRate = writeRate
    }
}

public struct DiskSample: Sendable, Equatable {
    /// Bytes per second summed over every physical drive.
    public var readRate: Double
    public var writeRate: Double
    /// Operations per second.
    public var readOps: Double
    public var writeOps: Double
    public var devices: [DiskDeviceRate]
    /// Seconds the rates cover; 0 for the first sample after a reset.
    public var interval: Double
    /// nil on ticks that did not refresh capacity (every 15th tick, or after a
    /// mount/unmount event); consumers keep the last list.
    public var volumes: [DiskVolume]?

    public init(readRate: Double, writeRate: Double, readOps: Double, writeOps: Double,
                devices: [DiskDeviceRate], interval: Double = 0, volumes: [DiskVolume]?) {
        self.interval = interval
        self.readRate = readRate
        self.writeRate = writeRate
        self.readOps = readOps
        self.writeOps = writeOps
        self.devices = devices
        self.volumes = volumes
    }
}

/// Cumulative counters of one `IOBlockStorageDriver`, as the driver publishes them.
struct DiskCounters: Equatable {
    var readBytes: UInt64
    var writeBytes: UInt64
    var readOps: UInt64
    var writeOps: UInt64

    init(readBytes: UInt64, writeBytes: UInt64, readOps: UInt64, writeOps: UInt64) {
        self.readBytes = readBytes
        self.writeBytes = writeBytes
        self.readOps = readOps
        self.writeOps = writeOps
    }

    /// `Statistics` of an IOBlockStorageDriver. nil without the two byte counters.
    init?(statistics: CFDictionary) {
        guard let read = CFReading.int64(statistics, "Bytes (Read)"),
              let write = CFReading.int64(statistics, "Bytes (Write)") else { return nil }
        readBytes = UInt64(max(0, read))
        writeBytes = UInt64(max(0, write))
        readOps = UInt64(max(0, CFReading.int64(statistics, "Operations (Read)") ?? 0))
        writeOps = UInt64(max(0, CFReading.int64(statistics, "Operations (Write)") ?? 0))
    }
}

/// Reads read/write throughput from the storage drivers and the volume list.
///
/// The drivers are matched once and their registry entries kept; a tick is one
/// property fetch per physical drive (~20 µs). Disk images ("Virtual Interface") are
/// left out so a mounted .dmg doesn't double-count the traffic that reaches the SSD.
/// Plug and unplug arrive as `IOServiceAddMatchingNotification` events and
/// DiskArbitration callbacks that only flip a flag; nothing is re-enumerated unless
/// one fired. Capacity is read every ``volumeRefreshInterval``th sample.
///
/// Not thread-safe: confine to one executor (the flags are, the rest is not).
public final class DiskReader {
    public static let volumeRefreshInterval = 15
    private let volumeInterval: Int

    private struct Device {
        var id: UInt64
        var service: io_service_t
        var name: String
        var bsdName: String?
        var isInternal: Bool
        var last: DiskCounters?
    }

    private var devices: [Device] = []
    private var lastSampleAt: ContinuousClock.Instant?
    private var samples = 0
    private var volumes: [DiskVolume] = []
    private var mountCount: Int32 = -1
    private let watcher: Watcher?

    /// `queue` receives hot-plug callbacks. nil disables them (the list is then
    /// built once and refreshed with the capacity cadence).
    public init(queue: DispatchQueue? = nil, volumeInterval: Int = DiskReader.volumeRefreshInterval) {
        self.volumeInterval = max(1, volumeInterval)
        watcher = queue.map(Watcher.init)
        devices = Self.discover()
    }

    deinit { devices.forEach { IOObjectRelease($0.service) } }

    /// Forgets the previous counters, so the next sample covers one interval
    /// instead of the whole time nobody was looking.
    public func reset() {
        for index in devices.indices { devices[index].last = nil }
        lastSampleAt = nil
    }

    /// ``reset()`` plus one counter read, so the next sample is a full interval. Unlike
    /// a throwaway ``sample()`` it leaves the volume list for the first real sample.
    public func prime() {
        reset()
        for index in devices.indices { devices[index].last = Self.counters(of: devices[index].service) }
        lastSampleAt = .now
    }

    public var deviceCount: Int { devices.count }

    public func sample() -> DiskSample {
        let flags = watcher?.takeFlags() ?? (devices: false, volumes: false)
        if flags.devices { rebuildDevices() }

        let now = ContinuousClock.now
        let elapsed = lastSampleAt.map { Self.seconds(now - $0) } ?? 0
        lastSampleAt = now

        var rates: [DiskDeviceRate] = []
        var totals = (read: 0.0, write: 0.0, readOps: 0.0, writeOps: 0.0)
        for index in devices.indices {
            guard let current = Self.counters(of: devices[index].service) else { continue }
            defer { devices[index].last = current }
            var read = 0.0, write = 0.0
            if let last = devices[index].last, elapsed > 0 {
                read = Self.rate(from: last.readBytes, to: current.readBytes, seconds: elapsed)
                write = Self.rate(from: last.writeBytes, to: current.writeBytes, seconds: elapsed)
                totals.readOps += Self.rate(from: last.readOps, to: current.readOps, seconds: elapsed)
                totals.writeOps += Self.rate(from: last.writeOps, to: current.writeOps, seconds: elapsed)
            }
            totals.read += read
            totals.write += write
            rates.append(DiskDeviceRate(id: devices[index].id, name: devices[index].name, bsdName: devices[index].bsdName,
                                        isInternal: devices[index].isInternal, readRate: read, writeRate: write))
        }

        var refreshed: [DiskVolume]?
        if volumes.isEmpty || flags.volumes || samples % volumeInterval == 0 {
            refreshVolumes(forceList: volumes.isEmpty || flags.volumes)
            refreshed = volumes
        }
        samples &+= 1
        return DiskSample(readRate: totals.read, writeRate: totals.write, readOps: totals.readOps,
                          writeOps: totals.writeOps, devices: rates, interval: elapsed, volumes: refreshed)
    }

    // MARK: Rates

    /// Counters only grow; a smaller value means the device was replaced or reset,
    /// which counts as no traffic rather than a negative or enormous rate.
    static func rate(from old: UInt64, to new: UInt64, seconds: Double) -> Double {
        guard seconds > 0, new >= old else { return 0 }
        return Double(new - old) / seconds
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    // MARK: Devices

    private static func counters(of service: io_service_t) -> DiskCounters? {
        guard let property = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue(), CFGetTypeID(property) == CFDictionaryGetTypeID() else { return nil }
        return DiskCounters(statistics: unsafeDowncast(property, to: CFDictionary.self))
    }

    private func rebuildDevices() {
        let found = Self.discover()
        let previous = Dictionary(devices.map { ($0.id, $0.last) }, uniquingKeysWith: { first, _ in first })
        devices.forEach { IOObjectRelease($0.service) }
        devices = found.map { device in
            var device = device
            device.last = previous[device.id] ?? nil
            return device
        }
    }

    /// Physical drives that currently hold a medium. Properties of the driver's
    /// provider (`Protocol Characteristics`, `Device Characteristics`) describe the
    /// hardware; a "Virtual Interface" provider is a disk image.
    private static func discover() -> [Device] {
        var iterator: io_iterator_t = IO_OBJECT_NULL
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [Device] = []
        while case let driver = IOIteratorNext(iterator), driver != IO_OBJECT_NULL {
            guard let device = describe(driver) else {
                IOObjectRelease(driver)
                continue
            }
            result.append(device)
        }
        return result
    }

    private static func describe(_ driver: io_service_t) -> Device? {
        var provider: io_registry_entry_t = IO_OBJECT_NULL
        guard IORegistryEntryGetParentEntry(driver, kIOServicePlane, &provider) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(provider) }
        func property(_ key: String) -> CFDictionary? {
            guard let value = IORegistryEntryCreateCFProperty(provider, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue(), CFGetTypeID(value) == CFDictionaryGetTypeID() else { return nil }
            return unsafeDowncast(value, to: CFDictionary.self)
        }
        let characteristics = property("Protocol Characteristics")
        let interconnect = characteristics.flatMap { CFReading.string($0, "Physical Interconnect") }
        if interconnect == "Virtual Interface" { return nil }
        guard let bsd = wholeMediaName(of: driver) else { return nil }
        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(driver, &entryID)
        let name = property("Device Characteristics").flatMap { CFReading.string($0, "Product Name") } ?? bsd
        let location = characteristics.flatMap { CFReading.string($0, "Physical Interconnect Location") }
        return Device(id: entryID, service: driver, name: name, bsdName: bsd,
                      isInternal: location == "Internal", last: nil)
    }

    /// "disk0": the whole-disk IOMedia under the driver; none while a card slot is empty.
    private static func wholeMediaName(of driver: io_service_t) -> String? {
        var children: io_iterator_t = IO_OBJECT_NULL
        guard IORegistryEntryGetChildIterator(driver, kIOServicePlane, &children) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(children) }
        var name: String?
        while case let child = IOIteratorNext(children), child != IO_OBJECT_NULL {
            defer { IOObjectRelease(child) }
            guard name == nil,
                  let bsd = IORegistryEntryCreateCFProperty(child, "BSD Name" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue(), CFGetTypeID(bsd) == CFStringGetTypeID() else { continue }
            name = unsafeDowncast(bsd, to: CFString.self) as String
        }
        return name
    }

    // MARK: Volumes

    private static let resourceKeys: [URLResourceKey] = [
        .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsLocalKey,
        .volumeIsRootFileSystemKey, .volumeLocalizedFormatDescriptionKey,
    ]

    /// `forceList` re-enumerates the mounted volumes; otherwise only the capacity of
    /// the known ones is read, plus one `getfsstat` count to notice a mount we
    /// weren't told about (network shares don't go through DiskArbitration).
    private func refreshVolumes(forceList: Bool) {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        let changed = forceList || count != mountCount
        mountCount = count
        let paths: [String] = changed
            ? (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes])?
                .map(\.path) ?? [])
            : volumes.map(\.mountPoint)
        volumes = paths.compactMap(Self.volume(at:))
    }

    /// The startup volume alone: one resource-value read, no device or list work.
    public static func bootVolume() -> DiskVolume? {
        guard var volume = volume(at: "/") else { return nil }
        volume.isBoot = true
        return volume
    }

    /// A fresh URL each time: `URL` caches resource values, which would freeze the
    /// free-space figure at its first reading.
    private static func volume(at path: String) -> DiskVolume? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)),
              let total = values.volumeTotalCapacity, total > 0 else { return nil }
        // The "important usage" figure is what Finder shows; some volumes (FUSE-style
        // mounts) report 0 for it, so fall back to the plain free space.
        var available = values.volumeAvailableCapacityForImportantUsage ?? 0
        if available <= 0 { available = Int64(values.volumeAvailableCapacity ?? 0) }
        let kind: DiskVolume.Kind
        if values.volumeIsLocal == false {
            kind = .network
        } else if values.volumeIsInternal == true {
            kind = .internalDisk
        } else if values.volumeIsRemovable == true || values.volumeIsEjectable == true {
            kind = .removable
        } else {
            kind = .external
        }
        return DiskVolume(name: values.volumeName ?? url.lastPathComponent, mountPoint: path,
                          total: UInt64(total), available: UInt64(max(0, available)), kind: kind,
                          format: values.volumeLocalizedFormatDescription, isBoot: values.volumeIsRootFileSystem ?? false)
    }

    // MARK: Hot plug

    /// Flips flags from IOKit and DiskArbitration callbacks. The callbacks run on the
    /// sampler queue but outside the reader's isolation, so they touch nothing else.
    private final class Watcher: @unchecked Sendable {
        private let flags = Mutex((devices: false, volumes: false))
        private var port: IONotificationPortRef?
        private var iterators: [io_iterator_t] = []
        private var session: DASession?

        init(queue: DispatchQueue) {
            let context = Unmanaged.passUnretained(self).toOpaque()
            port = IONotificationPortCreate(kIOMainPortDefault)
            if let port {
                IONotificationPortSetDispatchQueue(port, queue)
                for topic in [kIOMatchedNotification, kIOTerminatedNotification] {
                    var iterator: io_iterator_t = IO_OBJECT_NULL
                    let status = IOServiceAddMatchingNotification(
                        port, topic, IOServiceMatching("IOBlockStorageDriver"),
                        { refcon, iterator in
                            // Draining re-arms the notification.
                            while case let object = IOIteratorNext(iterator), object != IO_OBJECT_NULL { IOObjectRelease(object) }
                            guard let refcon else { return }
                            Unmanaged<Watcher>.fromOpaque(refcon).takeUnretainedValue().mark(devices: true, volumes: true)
                        }, context, &iterator)
                    guard status == KERN_SUCCESS else { continue }
                    while case let object = IOIteratorNext(iterator), object != IO_OBJECT_NULL { IOObjectRelease(object) }
                    iterators.append(iterator)
                }
            }
            if let session = DASessionCreate(kCFAllocatorDefault) {
                let callback: DADiskAppearedCallback = { _, context in
                    guard let context else { return }
                    Unmanaged<Watcher>.fromOpaque(context).takeUnretainedValue().mark(devices: true, volumes: true)
                }
                DARegisterDiskAppearedCallback(session, nil, callback, context)
                DARegisterDiskDisappearedCallback(session, nil, callback, context)
                // A mount or unmount of an existing disk only changes its volume path.
                DARegisterDiskDescriptionChangedCallback(
                    session, nil, [kDADiskDescriptionVolumePathKey] as CFArray,
                    { _, _, context in
                        guard let context else { return }
                        Unmanaged<Watcher>.fromOpaque(context).takeUnretainedValue().mark(devices: false, volumes: true)
                    }, context)
                DASessionSetDispatchQueue(session, queue)
                self.session = session
            }
        }

        deinit {
            // Detach callbacks before the object they point at goes away.
            if let session { DASessionSetDispatchQueue(session, nil) }
            iterators.forEach { IOObjectRelease($0) }
            if let port { IONotificationPortDestroy(port) }
        }

        func mark(devices: Bool, volumes: Bool) {
            flags.withLock {
                $0.devices = $0.devices || devices
                $0.volumes = $0.volumes || volumes
            }
        }

        func takeFlags() -> (devices: Bool, volumes: Bool) {
            flags.withLock {
                defer { $0 = (false, false) }
                return $0
            }
        }
    }
}
