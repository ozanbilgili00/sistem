import Foundation

/// Counts who needs each metric. A metric with no consumer is never read
/// (PLAN.md §3-A) — that rule, not a fast reader, is what keeps idle cost low.
///
/// A consumer can be *periodic*: a notification rule needs a CPU reading every
/// ten seconds, not every tick. While only periodic consumers hold a metric it is
/// read at the slowest rate that still serves the fastest of them
/// (``ticks(for:interval:)``); one ordinary consumer brings it back to its natural rate.
@MainActor
public final class DemandRegistry {
    private var counts: [Metric: Int] = [:]
    /// Periodic consumers per metric: seconds → how many hold it at that period.
    private var periodic: [Metric: [Double: Int]] = [:]
    var onChange: (() -> Void)?

    public init() {}

    public var active: Set<Metric> { Set(counts.keys) }

    public func retain(_ metric: Metric) {
        counts[metric, default: 0] += 1
        if counts[metric] == 1 { onChange?() }
    }

    public func release(_ metric: Metric) {
        guard let count = counts[metric] else {
            assertionFailure("release without retain: \(metric)")
            return
        }
        if count == 1 {
            counts[metric] = nil
            onChange?()
        } else {
            counts[metric] = count - 1
        }
    }

    public func retain(_ metrics: Set<Metric>) { metrics.forEach(retain) }
    public func release(_ metrics: Set<Metric>) { metrics.forEach(release) }

    /// A consumer that needs `metric` no more often than every `period` seconds.
    public func retain(_ metric: Metric, period: Double) {
        let was = periodic[metric]
        periodic[metric, default: [:]][period, default: 0] += 1
        counts[metric, default: 0] += 1
        if counts[metric] == 1 || was?.keys.min() != periodic[metric]?.keys.min() { onChange?() }
    }

    public func release(_ metric: Metric, period: Double) {
        guard var slots = periodic[metric], let n = slots[period] else {
            assertionFailure("release without retain: \(metric) @\(period)")
            return
        }
        let was = slots.keys.min()
        if n == 1 { slots[period] = nil } else { slots[period] = n - 1 }
        periodic[metric] = slots.isEmpty ? nil : slots
        let remaining = (counts[metric] ?? 1) - 1
        counts[metric] = remaining == 0 ? nil : remaining
        if remaining == 0 || was != slots.keys.min() { onChange?() }
    }

    /// Base ticks between reads of `metric` given the current base `interval`
    /// (seconds). Its natural rate unless every consumer is periodic.
    public func ticks(for metric: Metric, interval: Double) -> Int {
        let natural = metric.everyTicks
        guard let total = counts[metric], let slots = periodic[metric] else { return natural }
        let periodicCount = slots.values.reduce(0, +)
        guard periodicCount == total, let fastest = slots.keys.min() else { return natural }
        return max(natural, Int((fastest / max(interval, 0.1)).rounded(.down)))
    }

    /// Slower-than-natural rates for every active metric, for the sampler.
    public func tickOverrides(interval: Double) -> [Metric: Int] {
        var result: [Metric: Int] = [:]
        for metric in counts.keys {
            let ticks = ticks(for: metric, interval: interval)
            if ticks != metric.everyTicks { result[metric] = ticks }
        }
        return result
    }
}
