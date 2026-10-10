import Foundation
import IOKit.pwr_mgt

public enum AssertionKind: Sendable, Equatable {
    /// `PreventUserIdleSystemSleep`: the display may turn off, the system keeps running.
    case system
    /// `PreventUserIdleDisplaySleep`.
    case display
}

/// Creates and releases power assertions. The system removes them with the process.
@MainActor
public protocol PowerAssertionBackend {
    func create(_ kind: AssertionKind, name: String) -> UInt32?
    func release(_ id: UInt32)
}

@MainActor
public struct IOPMBackend: PowerAssertionBackend {
    public init() {}

    public func create(_ kind: AssertionKind, name: String) -> UInt32? {
        let type = kind == .system ? kIOPMAssertionTypePreventUserIdleSystemSleep : kIOPMAssertionTypePreventUserIdleDisplaySleep
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id)
        return result == kIOReturnSuccess ? id : nil
    }

    public func release(_ id: UInt32) { IOPMAssertionRelease(id) }
}

/// Who is keeping the Mac awake: one process and the sleep-preventing assertions it holds.
public struct AwakeHolder: Sendable, Equatable, Identifiable {
    public var pid: Int32
    public var processName: String
    public var preventsDisplaySleep: Bool
    /// The assertion's own description, shortened.
    public var reason: String
    public var since: Date?
    public var isSelf: Bool

    public var id: Int32 { pid }

    public init(pid: Int32, processName: String, preventsDisplaySleep: Bool, reason: String, since: Date? = nil, isSelf: Bool = false) {
        self.pid = pid
        self.processName = processName
        self.preventsDisplaySleep = preventsDisplaySleep
        self.reason = reason
        self.since = since
        self.isSelf = isSelf
    }
}

public struct AssertionSample: Sendable, Equatable {
    public var holders: [AwakeHolder]
    public init(holders: [AwakeHolder]) { self.holders = holders }
}

/// `pmset -g assertions` without the fork: `IOPMCopyAssertionsByProcess`.
public enum AssertionReader {
    private static let systemTypes: Set<String> = [
        "PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion",
    ]
    private static let displayTypes: Set<String> = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]

    public static func read(ownPID: Int32 = getpid()) -> AssertionSample {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess, let dictionary = raw?.takeRetainedValue() as? [AnyHashable: Any] else {
            return AssertionSample(holders: [])
        }
        var entries: [[String: Any]] = []
        for (key, value) in dictionary {
            guard let pid = (key as? NSNumber)?.int32Value, let list = value as? [[String: Any]] else { continue }
            for var entry in list {
                entry["AssertPID"] = pid
                entries.append(entry)
            }
        }
        return AssertionSample(holders: holders(from: entries, ownPID: ownPID))
    }

    /// Pure: turns assertion dictionaries into one row per process. Tested with fixtures.
    static func holders(from entries: [[String: Any]], ownPID: Int32) -> [AwakeHolder] {
        var byPID: [Int32: AwakeHolder] = [:]
        for entry in entries {
            guard let pid = (entry["AssertPID"] as? NSNumber)?.int32Value ?? (entry["AssertPID"] as? Int32),
                  let type = entry["AssertType"] as? String,
                  systemTypes.contains(type) || displayTypes.contains(type),
                  ((entry["AssertLevel"] as? NSNumber)?.intValue ?? 255) != 0 else { continue }
            // powerd holds one while the display is on; it is a consequence, not a cause.
            if entry["Process Name"] as? String == "powerd" { continue }
            let isDisplay = displayTypes.contains(type)
            let name = String((entry["AssertName"] as? String ?? "").prefix(80))
            var holder = byPID[pid] ?? AwakeHolder(
                pid: pid, processName: entry["Process Name"] as? String ?? "?",
                preventsDisplaySleep: false, reason: name, since: entry["AssertStartWhen"] as? Date, isSelf: pid == ownPID)
            if isDisplay { holder.preventsDisplaySleep = true }
            if holder.reason.isEmpty { holder.reason = name }
            byPID[pid] = holder
        }
        return byPID.values.sorted { ($0.preventsDisplaySleep ? 0 : 1, $0.processName, $0.pid) < ($1.preventsDisplaySleep ? 0 : 1, $1.processName, $1.pid) }
    }
}
