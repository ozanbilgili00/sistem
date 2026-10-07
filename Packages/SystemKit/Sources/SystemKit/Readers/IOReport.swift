import Darwin
import Foundation

/// Bridge to the undocumented libIOReport, loaded at runtime with `dlopen` so that
/// a macOS update removing a symbol hides some metrics instead of crashing the app
/// at launch. `IOReport.library` is nil when unavailable.
public final class IOReport: @unchecked Sendable {
    // Immutable after init; the function pointers are safe to share.
    public static let library = IOReport()

    private typealias CopyAll = @convention(c) (UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias CopyGroup = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias Merge = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Void
    private typealias Subscribe = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> Unmanaged<AnyObject>?
    private typealias Samples = @convention(c) (AnyObject, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias Delta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias ChannelFormat = @convention(c) (CFDictionary) -> UInt8
    private typealias SimpleInteger = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias StateCount = @convention(c) (CFDictionary) -> Int32
    private typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateResidency = @convention(c) (CFDictionary, Int32) -> Int64

    private let copyAll: CopyAll
    private let copyGroup: CopyGroup
    private let merge: Merge
    private let subscribe: Subscribe
    private let samples: Samples
    private let delta: Delta
    private let group: ChannelString
    private let subgroup: ChannelString
    private let name: ChannelString
    private let unit: ChannelString
    private let format: ChannelFormat
    private let simpleInteger: SimpleInteger
    private let stateCount: StateCount
    private let stateName: StateName
    private let stateResidency: StateResidency

    private init?() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY) else { return nil }
        func load<T>(_ symbol: String, as _: T.Type) -> T? {
            dlsym(handle, symbol).map { unsafeBitCast($0, to: T.self) }
        }
        guard let copyAll = load("IOReportCopyAllChannels", as: CopyAll.self),
              let copyGroup = load("IOReportCopyChannelsInGroup", as: CopyGroup.self),
              let merge = load("IOReportMergeChannels", as: Merge.self),
              let subscribe = load("IOReportCreateSubscription", as: Subscribe.self),
              let samples = load("IOReportCreateSamples", as: Samples.self),
              let delta = load("IOReportCreateSamplesDelta", as: Delta.self),
              let group = load("IOReportChannelGetGroup", as: ChannelString.self),
              let subgroup = load("IOReportChannelGetSubGroup", as: ChannelString.self),
              let name = load("IOReportChannelGetChannelName", as: ChannelString.self),
              let unit = load("IOReportChannelGetUnitLabel", as: ChannelString.self),
              let format = load("IOReportChannelGetFormat", as: ChannelFormat.self),
              let simpleInteger = load("IOReportSimpleGetIntegerValue", as: SimpleInteger.self),
              let stateCount = load("IOReportStateGetCount", as: StateCount.self),
              let stateName = load("IOReportStateGetNameForIndex", as: StateName.self),
              let stateResidency = load("IOReportStateGetResidency", as: StateResidency.self)
        else { return nil }
        (self.copyAll, self.copyGroup, self.merge, self.subscribe, self.samples, self.delta) =
            (copyAll, copyGroup, merge, subscribe, samples, delta)
        (self.group, self.subgroup, self.name, self.unit, self.format) = (group, subgroup, name, unit, format)
        (self.simpleInteger, self.stateCount, self.stateName, self.stateResidency) =
            (simpleInteger, stateCount, stateName, stateResidency)
    }

    // MARK: Channels

    public enum Format: UInt8, Sendable, Codable {
        case unknown = 0, simple = 1, state = 2, histogram = 3, simpleArray = 4
    }

    public struct Channel: Sendable, Hashable {
        public let group: String
        public let subgroup: String
        public let name: String
        public let unit: String
        public let format: Format
    }

    /// Every channel the system publishes. Discovery only — thousands of entries.
    public func allChannels() -> [Channel] {
        guard let all = copyAll(0, 0)?.takeRetainedValue() else { return [] }
        return channelDictionaries(in: all).map(describe)
    }

    func describe(_ channel: CFDictionary) -> Channel {
        Channel(
            group: group(channel)?.takeUnretainedValue() as String? ?? "",
            subgroup: subgroup(channel)?.takeUnretainedValue() as String? ?? "",
            name: name(channel)?.takeUnretainedValue() as String? ?? "",
            unit: (unit(channel)?.takeUnretainedValue() as String? ?? "").trimmingCharacters(in: .whitespaces),
            format: Format(rawValue: format(channel)) ?? .unknown
        )
    }

    func channelDictionaries(in report: CFDictionary) -> [CFDictionary] {
        ((report as NSDictionary)["IOReportChannels"] as? [NSDictionary])?.map { $0 as CFDictionary } ?? []
    }

    // MARK: Subscriptions

    /// A live subscription to some channel groups. Create once, then sample.
    public final class Subscription {
        private let library: IOReport
        private let subscription: AnyObject
        private let subscribed: CFMutableDictionary

        init?(library: IOReport, groups: [(group: String, subgroup: String?)], keeping keep: ((Channel) -> Bool)?) {
            var merged: CFMutableDictionary?
            for entry in groups {
                guard var channels = library.copyGroup(entry.group as CFString, entry.subgroup as CFString?, 0, 0, 0)?
                    .takeRetainedValue() else { continue }
                if let keep {
                    // Subscribing to a handful of channels, not the whole group, keeps
                    // every later delta (and its string decoding) proportionally small.
                    guard let filtered = library.filter(channels, keeping: keep) else { continue }
                    channels = filtered
                }
                if let merged {
                    library.merge(merged, channels, nil)
                } else {
                    merged = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, channels)
                }
            }
            guard let merged else { return nil }
            var subscribed: Unmanaged<CFMutableDictionary>?
            guard let subscription = library.subscribe(nil, merged, &subscribed, 0, nil)?.takeRetainedValue(),
                  let subscribed = subscribed?.takeRetainedValue() else { return nil }
            self.library = library
            self.subscription = subscription
            self.subscribed = subscribed
        }

        /// Last sample taken, so several readers sharing one subscription in the same
        /// tick pay for one `IOReportCreateSamples` (about 4 ms of CPU for the CPU and
        /// energy groups, whatever the channel count).
        private var latest: Sample?

        /// Seconds a sample stays "this tick's" for further callers. 0 (the default)
        /// means every call takes a fresh one.
        public var reuseWindow = 0.0

        /// A fresh sample, or the previous one if it is younger than ``reuseWindow``.
        public func sample() -> Sample? {
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            if reuseWindow > 0, let latest, Double(now &- latest.time) < reuseWindow * 1e9 { return latest }
            guard let raw = library.samples(subscription, subscribed, nil)?.takeRetainedValue() else { return nil }
            let sample = Sample(raw: raw, time: now)
            latest = sample
            return sample
        }

        /// What happened between two samples.
        public func readings(from earlier: Sample, to later: Sample) -> [Reading] {
            guard let delta = library.delta(earlier.raw, later.raw, nil)?.takeRetainedValue() else { return [] }
            return library.channelDictionaries(in: delta).map { channel in
                let info = library.describe(channel)
                switch info.format {
                case .state:
                    let states = (0..<library.stateCount(channel)).map { index in
                        State(
                            name: library.stateName(channel, index)?.takeUnretainedValue() as String? ?? "",
                            residency: library.stateResidency(channel, index)
                        )
                    }
                    return Reading(channel: info, value: nil, states: states)
                case .simple:
                    return Reading(channel: info, value: library.simpleInteger(channel, 0), states: [])
                default:
                    return Reading(channel: info, value: nil, states: [])
                }
            }
        }
    }

    /// Subscribes to `groups`; with `keeping`, only to the channels it accepts.
    public func subscribe(to groups: [(group: String, subgroup: String?)],
                          keeping keep: ((Channel) -> Bool)? = nil) -> Subscription? {
        Subscription(library: self, groups: groups, keeping: keep)
    }

    /// A copy of `report` whose channel list holds only the accepted channels; nil if none.
    func filter(_ report: CFDictionary, keeping keep: (Channel) -> Bool) -> CFDictionary? {
        guard let items = (report as NSDictionary)["IOReportChannels"] as? [NSDictionary] else { return nil }
        let kept = items.filter { keep(describe($0 as CFDictionary)) }
        guard !kept.isEmpty,
              let copy = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, report) else { return nil }
        // A mutable array: IOReportMergeChannels appends to the first group's list.
        (copy as NSMutableDictionary)["IOReportChannels"] = NSMutableArray(array: kept)
        return copy
    }

    public struct Sample {
        let raw: CFDictionary
        /// `CLOCK_UPTIME_RAW` nanoseconds when it was taken.
        public let time: UInt64
    }

    public struct State: Sendable, Hashable {
        public let name: String
        public let residency: Int64
    }

    public struct Reading: Sendable {
        public let channel: Channel
        /// For simple channels: the counter delta (energy, in `channel.unit`).
        public let value: Int64?
        /// For state channels: time spent in each state during the interval.
        public let states: [State]
    }
}
