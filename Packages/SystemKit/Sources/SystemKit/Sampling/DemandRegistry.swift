/// Counts who needs each metric. A metric with no consumer is never read
/// (PLAN.md §3-A) — that rule, not a fast reader, is what keeps idle cost low.
@MainActor
public final class DemandRegistry {
    private var counts: [Metric: Int] = [:]
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
}
