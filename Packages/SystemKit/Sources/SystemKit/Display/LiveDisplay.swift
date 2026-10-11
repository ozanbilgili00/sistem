import AppKit
import CPrivate
import CoreGraphics
import Foundation

// The system-backed versions of the protocols in DisplayBackends.swift. Reading is always safe;
// `setMode`, `CGSetDisplayTransferByTable` and the DDC write change a real screen and are only
// reached through DisplayController (and never from the probe).

// MARK: Displays

@MainActor
public final class CGDisplayBackend: DisplayBackend {
    private var handler: (@MainActor (DisplayChangeFlags) -> Void)?
    private var registered = false

    public init() {}

    isolated deinit { stopObserving() }

    public func displays() -> [DisplayInfo] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        let screens = Dictionary(NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, NSScreen)? in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { ($0.uint32Value, screen) }
        }, uniquingKeysWith: { first, _ in first })
        return ids.prefix(Int(count)).map { id in
            let screen = screens[id]
            let builtIn = CGDisplayIsBuiltin(id) != 0
            var level: Float = 0
            let hasBrightness = builtIn && SistemInternalBrightness(id, &level) == 0
            return DisplayInfo(
                id: id, name: screen?.localizedName ?? "", vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                isBuiltIn: builtIn, isMain: CGDisplayIsMain(id) != 0, isMirrored: CGDisplayIsInMirrorSet(id) != 0,
                mode: CGDisplayCopyDisplayMode(id).map(Self.convert), rotation: Int(CGDisplayRotation(id)),
                edrCurrent: Float(screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1),
                edrPotential: Float(screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1),
                brightness: hasBrightness ? level : nil)
        }
    }

    public func modes(for id: DisplayID) -> [DisplayMode] {
        let all = CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode] ?? []
        return all.filter { $0.isUsableForDesktopGUI() }.map(Self.convert)
    }

    public func setMode(_ mode: DisplayMode, on id: DisplayID, scope: ModeScope) -> Bool {
        let all = CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode] ?? []
        guard let target = all.first(where: { $0.ioDisplayModeID == mode.id }) else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard CGConfigureDisplayWithDisplayMode(config, id, target, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, scope == .appOnly ? .forAppOnly : .forSession) == .success
    }

    public func startObserving(_ handler: @escaping @MainActor (DisplayChangeFlags) -> Void) {
        self.handler = handler
        guard !registered else { return }
        registered = true
        CGDisplayRegisterReconfigurationCallback({ _, flags, info in
            guard let info else { return }
            let backend = Unmanaged<CGDisplayBackend>.fromOpaque(info)
            let bits = DisplayChangeFlags(rawValue: flags.rawValue)
            // The callback arrives on the main run loop; hopping keeps the actor rules explicit.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { backend.takeUnretainedValue().handler?(bits) }
            }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    public func stopObserving() {
        handler = nil
        guard registered else { return }
        registered = false
        CGDisplayRemoveReconfigurationCallback({ _, _, _ in }, Unmanaged.passUnretained(self).toOpaque())
    }

    private nonisolated static func convert(_ mode: CGDisplayMode) -> DisplayMode {
        DisplayMode(id: mode.ioDisplayModeID, width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth,
                    pixelHeight: mode.pixelHeight, refreshRate: mode.refreshRate)
    }
}

// MARK: Gamma

@MainActor
public final class CGGammaBackend: GammaBackend {
    public init() {}

    public func apply(_ table: GammaTable, to id: DisplayID) -> Bool {
        CGSetDisplayTransferByTable(id, UInt32(table.red.count), table.red, table.green, table.blue) == .success
    }

    public func resetAll() { CGDisplayRestoreColorSyncSettings() }
}

// MARK: DDC

/// DDC/CI over the Apple Silicon `IOAVService` of one external display. The handle is used
/// only from the worker queue.
final class AVTransport: DDCTransport, @unchecked Sendable {
    private let handle: UnsafeMutableRawPointer

    init?(registryID: UInt64) {
        guard let handle = SistemAVOpen(registryID) else { return nil }
        self.handle = handle
    }

    deinit { SistemAVClose(handle) }

    func read(_ code: UInt8) -> VCPValue? {
        let request = DDCPacket.getRequest(code: code)
        for attempt in 0..<3 {
            if attempt > 0 { usleep(20_000) }
            guard SistemAVWrite(handle, DDCPacket.chip, DDCPacket.dataAddress, request, UInt32(request.count)) == 0 else { continue }
            usleep(50_000)  // the monitor needs this long before it can answer
            var reply = [UInt8](repeating: 0, count: DDCPacket.replyLength)
            guard SistemAVRead(handle, DDCPacket.chip, DDCPacket.dataAddress, &reply, UInt32(reply.count)) == 0 else { continue }
            if let value = DDCPacket.parseReply(reply, code: code) { return value }
        }
        return nil
    }

    func write(_ code: UInt8, value: UInt16) -> Bool {
        let request = DDCPacket.setRequest(code: code, value: value)
        let accepted = SistemAVWrite(handle, DDCPacket.chip, DDCPacket.dataAddress, request, UInt32(request.count)) == 0
        usleep(10_000)
        return accepted
    }
}

@MainActor
public final class AVDDCProvider: DDCProvider {
    public init() {}

    /// Ties a display to its channel by the manufacturer and product numbers of its EDID, and
    /// only when that pair is unique among the connected displays and among the channels. Two
    /// identical monitors can not be told apart this way, so neither gets DDC rather than the wrong one.
    public func transport(for display: DisplayInfo, among all: [DisplayInfo]) -> DDCTransport? {
        guard !display.isBuiltIn,
              all.filter({ !$0.isBuiltIn && $0.vendor == display.vendor && $0.model == display.model }).count == 1 else { return nil }
        var hints = [SistemAVHint](repeating: SistemAVHint(), count: 16)
        let hintCount = Int(SistemAVHints(&hints, Int32(hints.count)))
        let matching = hints.prefix(hintCount).filter { UInt32($0.vendor) == display.vendor && UInt32($0.product) == display.model }
        guard matching.count == 1, let port = Self.string(matching[0].port) else { return nil }
        var proxies = [SistemAVProxy](repeating: SistemAVProxy(), count: 16)
        let proxyCount = Int(SistemAVProxies(&proxies, Int32(proxies.count)))
        let onPort = proxies.prefix(proxyCount).filter { Self.string($0.port) == port }
        guard onPort.count == 1 else { return nil }
        return AVTransport(registryID: onPort[0].registryID)
    }

    private static func string(_ tuple: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar)) -> String? {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
        }
    }
}

// MARK: Worker and clock

@MainActor
public final class QueueWorker: DisplayWorker {
    private let queue = DispatchQueue(label: "sistem.display.ddc", qos: .utility)

    public init() {}

    public func run<T: Sendable>(_ work: @escaping @Sendable () -> T, then: @escaping @MainActor (T) -> Void) {
        queue.async {
            let result = work()
            DispatchQueue.main.async { MainActor.assumeIsolated { then(result) } }
        }
    }
}

@MainActor
public final class SystemDisplayClock: DisplayClock {
    public init() {}

    public func now() -> Date { Date() }

    public func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void {
        let item = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }
}
