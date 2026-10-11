import Foundation
import os

/// Watches the displays and acts on them on request. Nothing here runs on a timer.
///
/// - **Watching** is event driven: the system's reconfiguration callback is the only trigger,
///   and a burst of callbacks is folded into one reload after ``settleDelay``.
/// - **DDC** is read only while a page or popover is visible (``setVisible(_:)``), on a worker
///   queue; a monitor without DDC ends in a plain "unsupported" state. Writes are limited to
///   ``minWriteInterval`` per control, the last value always wins.
/// - **Mode changes** are trials: the new mode is applied for this app only, and unless
///   ``confirmModeChange()`` comes within ``revertDelay`` the old mode returns by itself. An
///   app-only mode also falls back on its own if the process dies, so a crash during the
///   trial cannot leave the screen in a mode nobody confirmed.
/// - **Software dimming and the night tone** are transfer tables. The system takes them back
///   when the process ends; a clean quit also calls ``stop()``, which restores them at once.
@MainActor
public final class DisplayController {
    public static let eventLimit = 50
    public static let revertDelay: TimeInterval = 15
    public static let minWriteInterval: TimeInterval = 0.1
    public static let settleDelay: TimeInterval = 0.3

    public private(set) var state = DisplayState()
    /// Counts only (no names, no numbers of a display), at debug level: `log stream --level debug --predicate 'category == "display"'`.
    private let log = Logger(subsystem: "com.ozan.sistem", category: "display")
    private var lastPublished: DisplayState?
    private var counts = (reload: 0, probe: 0, publish: 0)
    /// Called after every change of `state`.
    public var onChange: (() -> Void)?

    private let backend: DisplayBackend
    private let gamma: GammaBackend
    private let ddc: DDCProvider
    private let worker: DisplayWorker
    private let clock: DisplayClock

    private var running = false
    private var visible = false
    private var nextEventID = 0
    private var transports: [DisplayID: DDCTransport] = [:]
    private var cancelSettle: (() -> Void)?
    private var cancelRevert: (() -> Void)?

    private struct WriteKey: Hashable {
        var display: DisplayID
        var code: UInt8
    }
    private var pendingWrites: [WriteKey: UInt16] = [:]
    private var lastWrite: [WriteKey: Date] = [:]
    private var writeTimers: [WriteKey: () -> Void] = [:]

    public init(backend: DisplayBackend, gamma: GammaBackend, ddc: DDCProvider, worker: DisplayWorker, clock: DisplayClock) {
        self.backend = backend
        self.gamma = gamma
        self.ddc = ddc
        self.worker = worker
        self.clock = clock
    }

    // MARK: Lifecycle

    public func start() {
        guard !running else { return }
        running = true
        backend.startObserving { [weak self] flags in self?.reconfigured(flags) }
        reload(initial: true)
    }

    /// Gives everything back: a pending trial is reverted, tables and callbacks are released.
    public func stop() {
        guard running else { return }
        running = false
        cancelSettle?()
        cancelSettle = nil
        if state.pending != nil { revertModeChange() }
        for cancel in writeTimers.values { cancel() }
        writeTimers = [:]
        pendingWrites = [:]
        gamma.resetAll()
        for index in state.entries.indices {
            state.entries[index].dim = 1
            state.entries[index].warmth = 0
        }
        backend.stopObserving()
        publish()
    }

    /// The page or popover is on screen (true) or not (false). Modes and DDC values are read
    /// when it becomes visible and dropped when it goes away; no read happens in between.
    public func setVisible(_ shown: Bool) {
        guard running, shown != visible else { return }
        visible = shown
        if shown {
            reload(initial: false, probe: true)
        } else {
            for index in state.entries.indices { state.entries[index].modes = [] }
            publish()
        }
    }

    // MARK: Reconfiguration

    private func reconfigured(_ flags: DisplayChangeFlags) {
        guard running, !flags.isOnlyAnnouncement else { return }
        log.debug("callback flags=\(flags.rawValue)")
        cancelSettle?()
        cancelSettle = clock.schedule(after: Self.settleDelay) { [weak self] in
            guard let self else { return }
            cancelSettle = nil
            reload(initial: false)
        }
    }

    /// `probe`: read DDC again even if the set of displays is unchanged (the page just became visible).
    private func reload(initial: Bool, probe: Bool = false) {
        counts.reload += 1
        log.debug("reload #\(self.counts.reload) visible=\(self.visible)")
        let infos = backend.displays()
        let old = Dictionary(uniqueKeysWithValues: state.entries.map { ($0.id, $0) })
        var entries: [DisplayEntry] = []
        for info in infos {
            var entry = old[info.id] ?? DisplayEntry(info: info)
            entry.info = info
            if visible { entry.modes = backend.modes(for: info.id) }
            entries.append(entry)
        }
        if !initial { recordEvents(old: old, new: entries) }
        let setChanged = Set(old.keys) != Set(infos.map(\.id))
        let gone = Set(old.keys).subtracting(infos.map(\.id))
        for id in gone {
            transports[id] = nil
            for key in writeTimers.keys where key.display == id {
                writeTimers[key]?()
                writeTimers[key] = nil
                pendingWrites[key] = nil
            }
        }
        state.entries = entries
        if let pending = state.pending, !entries.contains(where: { $0.id == pending.display }) {
            cancelRevert?()
            cancelRevert = nil
            state.pending = nil
        }
        // A reconfiguration can reset the tables; putting ours back is one cheap call per adjusted display.
        for entry in entries where entry.colorIsAdjusted { applyColor(entry) }
        publish()
        // A mode change or a moved window does not change what a monitor answers: read DDC again only when the
        // set of displays changed or the page just appeared.
        if visible, probe || setChanged { probeDDC() }
    }

    private func recordEvents(old: [DisplayID: DisplayEntry], new: [DisplayEntry]) {
        let newIDs = Set(new.map(\.id))
        for entry in old.values.sorted(by: { $0.id < $1.id }) where !newIDs.contains(entry.id) {
            add(.disconnected, entry.info.name)
        }
        for entry in new {
            guard let before = old[entry.id]?.info else {
                add(.connected, entry.info.name, Self.describe(entry.info.mode))
                continue
            }
            if before.mode?.id != entry.info.mode?.id || before.mode?.pixelWidth != entry.info.mode?.pixelWidth
                || before.mode?.refreshRate != entry.info.mode?.refreshRate {
                add(.modeChanged, entry.info.name, Self.describe(entry.info.mode))
            } else if before.isMain != entry.info.isMain || before.isMirrored != entry.info.isMirrored || before.rotation != entry.info.rotation {
                add(.layoutChanged, entry.info.name)
            }
        }
    }

    private func add(_ kind: DisplayEventKind, _ name: String, _ detail: String = "") {
        nextEventID += 1
        state.events.insert(DisplayEvent(id: nextEventID, date: clock.now(), kind: kind, name: name, detail: detail), at: 0)
        if state.events.count > Self.eventLimit { state.events.removeLast(state.events.count - Self.eventLimit) }
    }

    /// "2560 × 1440 · 200 Hz".
    public static func describe(_ mode: DisplayMode?) -> String {
        guard let mode else { return "" }
        let size = "\(mode.width) × \(mode.height)"
        return mode.refreshRate > 0 ? "\(size) · \(Int(mode.refreshRate.rounded())) Hz" : size
    }

    // MARK: DDC

    /// Finds out which displays answer DDC and reads their controls.
    private func probeDDC() {
        counts.probe += 1
        log.debug("probe #\(self.counts.probe)")
        let infos = state.entries.map(\.info)
        for entry in state.entries {
            let id = entry.id
            if entry.info.isBuiltIn {
                update(id) { $0.ddc = .unsupported(.builtIn) }
                continue
            }
            guard let transport = ddc.transport(for: entry.info, among: infos) else {
                transports[id] = nil
                update(id) { $0.ddc = .unsupported(.noChannel) }
                continue
            }
            transports[id] = transport
            worker.run({ () -> [VCPControl: VCPValue] in
                var values: [VCPControl: VCPValue] = [:]
                for control in VCPControl.allCases {
                    if let value = transport.read(control.code) { values[control] = value }
                }
                return values
            }, then: { [weak self] values in
                guard let self else { return }
                update(id) { entry in
                    if values.isEmpty {
                        entry.ddc = .unsupported(.noAnswer)
                        entry.controls = [:]
                    } else {
                        entry.ddc = .supported
                        entry.controls = values
                    }
                }
                publish()
            })
        }
        publish()
    }

    /// Sets a control. The slider shows the new value at once; the monitor gets it at most
    /// ``minWriteInterval`` after the previous write, and only the latest value is sent.
    public func setControl(_ control: VCPControl, to requested: UInt16, on id: DisplayID) {
        guard let entry = entry(id), entry.ddc == .supported, let current = entry.controls[control], transports[id] != nil else { return }
        let value: UInt16
        if control == .inputSource {
            // Input numbers are not a range (a monitor may report a maximum of 14 and still take 17): only
            // the known ones are ever written, and never clamped.
            guard DDCInput.known.contains(requested) else { return }
            value = requested
        } else {
            value = current.maximum > 0 ? min(requested, current.maximum) : requested
        }
        update(id) { $0.controls[control]?.current = value }
        let key = WriteKey(display: id, code: control.code)
        pendingWrites[key] = value
        if writeTimers[key] == nil {
            let wait = lastWrite[key].map { Self.minWriteInterval - clock.now().timeIntervalSince($0) } ?? 0
            if wait <= 0 {
                flush(key)
            } else {
                writeTimers[key] = clock.schedule(after: wait) { [weak self] in
                    self?.writeTimers[key] = nil
                    self?.flush(key)
                }
            }
        }
        publish()
    }

    private func flush(_ key: WriteKey) {
        guard let value = pendingWrites.removeValue(forKey: key), let transport = transports[key.display] else { return }
        lastWrite[key] = clock.now()
        worker.run({ transport.write(key.code, value: value) }, then: { [weak self] accepted in
            guard let self else { return }
            update(key.display) { $0.ddcWriteFailed = !accepted }
            publish()
        })
    }

    // MARK: Software dimming and night tone

    public func setDim(_ value: Float, on id: DisplayID) {
        guard entry(id) != nil else { return }
        update(id) { $0.dim = min(1, max(GammaCurve.minimumDim, value.isFinite ? value : 1)) }
        colorChanged(id)
    }

    public func setWarmth(_ value: Float, on id: DisplayID) {
        guard entry(id) != nil else { return }
        update(id) { $0.warmth = min(1, max(0, value.isFinite ? value : 0)) }
        colorChanged(id)
    }

    public func resetColor(on id: DisplayID) {
        guard entry(id) != nil else { return }
        update(id) {
            $0.dim = 1
            $0.warmth = 0
        }
        colorChanged(id)
    }

    private func colorChanged(_ id: DisplayID) {
        guard let entry = entry(id) else { return }
        if entry.colorIsAdjusted {
            applyColor(entry)
        } else {
            // An identity table is not the display's calibrated curve: give the display back to ColorSync instead.
            gamma.resetAll()
            for other in state.entries where other.colorIsAdjusted { applyColor(other) }
        }
        publish()
    }

    private func applyColor(_ entry: DisplayEntry) {
        _ = gamma.apply(GammaCurve.table(dim: entry.dim, warmth: entry.warmth), to: entry.id)
    }

    // MARK: Mode changes

    /// Applies `mode` as a trial. false when another trial is open or the system refuses.
    @discardableResult
    public func requestMode(_ mode: DisplayMode, on id: DisplayID) -> Bool {
        guard state.pending == nil, let entry = entry(id), let from = entry.info.mode, from.id != mode.id else { return false }
        state.modeChangeFailed = false
        guard backend.setMode(mode, on: id, scope: .appOnly) else {
            state.modeChangeFailed = true
            publish()
            return false
        }
        state.pending = PendingModeChange(display: id, from: from, to: mode, deadline: clock.now().addingTimeInterval(Self.revertDelay))
        cancelRevert = clock.schedule(after: Self.revertDelay) { [weak self] in
            self?.cancelRevert = nil
            self?.revertModeChange()
        }
        publish()
        return true
    }

    /// Keeps the trial mode for the rest of the login session.
    public func confirmModeChange() {
        guard let pending = state.pending else { return }
        cancelRevert?()
        cancelRevert = nil
        state.pending = nil
        _ = backend.setMode(pending.to, on: pending.display, scope: .session)
        publish()
    }

    /// Puts the old mode back: the Revert button, the 15 s timeout, or shutting down.
    public func revertModeChange() {
        guard let pending = state.pending else { return }
        cancelRevert?()
        cancelRevert = nil
        state.pending = nil
        _ = backend.setMode(pending.from, on: pending.display, scope: .session)
        add(.modeReverted, entry(pending.display)?.info.name ?? "", Self.describe(pending.from))
        publish()
    }

    // MARK: Helpers

    private func entry(_ id: DisplayID) -> DisplayEntry? { state.entries.first { $0.id == id } }

    private func update(_ id: DisplayID, _ change: (inout DisplayEntry) -> Void) {
        guard let index = state.entries.firstIndex(where: { $0.id == id }) else { return }
        change(&state.entries[index])
    }

    private func publish() {
        // Observers redraw on every call, so a call that changes nothing is dropped here.
        guard state != lastPublished else { return }
        lastPublished = state
        counts.publish += 1
        log.debug("publish #\(self.counts.publish)")
        onChange?()
    }
}

/// Which modes the pickers offer: the sizes, and the refresh rates of one size.
public enum DisplayModeCatalog {
    public struct Size: Hashable, Sendable, Identifiable {
        public var width: Int
        public var height: Int
        public var isHiDPI: Bool
        public var id: String { "\(width)x\(height)\(isHiDPI ? "@2x" : "")" }

        public init(width: Int, height: Int, isHiDPI: Bool) {
            self.width = width
            self.height = height
            self.isHiDPI = isHiDPI
        }
    }

    /// Distinct sizes, largest first.
    public static func sizes(of modes: [DisplayMode]) -> [Size] {
        var seen = Set<Size>()
        var result: [Size] = []
        for mode in modes {
            let size = Size(width: mode.width, height: mode.height, isHiDPI: mode.isHiDPI)
            if seen.insert(size).inserted { result.append(size) }
        }
        return result.sorted { ($0.width, $0.height, $0.isHiDPI ? 1 : 0) > ($1.width, $1.height, $1.isHiDPI ? 1 : 0) }
    }

    /// The modes of one size, fastest first, one per refresh rate.
    public static func rates(for size: Size, in modes: [DisplayMode]) -> [DisplayMode] {
        var seen = Set<Int>()
        return modes
            .filter { $0.width == size.width && $0.height == size.height && $0.isHiDPI == size.isHiDPI }
            .sorted { $0.refreshRate > $1.refreshRate }
            .filter { seen.insert(Int($0.refreshRate.rounded())).inserted }
    }
}
