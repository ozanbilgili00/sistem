/// Latest values and history on the main actor.
///
/// Deliberately not `@Observable`: a tick would otherwise invalidate every view
/// that touched any buffer. Consumers subscribe with ``observe(_:)`` and pull what
/// they draw, on their own schedule (PLAN.md §3-C).
@MainActor
public final class MetricStore {
    public static let historyLength = 300

    public private(set) var cpu: CPUSample?
    public private(set) var cpuUser = RingBuffer(capacity: historyLength)
    public private(set) var cpuSystem = RingBuffer(capacity: historyLength)

    public private(set) var memory: MemorySample?
    /// Fractions of physical memory, stacked in this order in charts.
    public private(set) var memoryApp = RingBuffer(capacity: historyLength)
    public private(set) var memoryWired = RingBuffer(capacity: historyLength)
    public private(set) var memoryCompressed = RingBuffer(capacity: historyLength)

    public private(set) var processes: ProcessSample?

    /// Bumped once per delivered snapshot.
    public private(set) var generation = 0

    private var observers: [Int: () -> Void] = [:]
    private var nextObserverID = 0

    public init() {}

    public func ingest(_ snapshot: Snapshot) {
        if let sample = snapshot.cpu {
            cpu = sample
            cpuUser.append(sample.user)
            cpuSystem.append(sample.system)
        }
        if let sample = snapshot.memory {
            memory = sample
            memoryApp.append(sample.fraction(sample.app))
            memoryWired.append(sample.fraction(sample.wired))
            memoryCompressed.append(sample.fraction(sample.compressed))
        }
        if let sample = snapshot.processes {
            processes = sample
        }
        generation &+= 1
        for observer in observers.values { observer() }
    }

    /// Calls `handler` after every ingest until the token is cancelled or dropped.
    public func observe(_ handler: @escaping () -> Void) -> ObservationToken {
        let id = nextObserverID
        nextObserverID += 1
        observers[id] = handler
        return ObservationToken { [weak self] in self?.observers[id] = nil }
    }
}

/// Ends an observation when cancelled or deallocated.
@MainActor
public final class ObservationToken {
    private var cancellation: (() -> Void)?

    init(_ cancellation: @escaping () -> Void) { self.cancellation = cancellation }

    public func cancel() {
        cancellation?()
        cancellation = nil
    }

    isolated deinit { cancel() }
}
