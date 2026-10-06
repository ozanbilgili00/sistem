/// Fixed-capacity history of one metric, oldest sample first.
///
/// Storage is allocated once in `init`; `append` never allocates, so a tick costs
/// a store and an index bump (PLAN.md §3-D). 300 samples × 4 bytes = 1.2 KB.
public struct RingBuffer: Sendable {
    public let capacity: Int
    private var storage: ContiguousArray<Float>
    /// Index the next sample is written to.
    private var head = 0
    public private(set) var count = 0

    public init(capacity: Int = 300) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = ContiguousArray(repeating: 0, count: capacity)
    }

    public var isEmpty: Bool { count == 0 }

    public mutating func append(_ value: Float) {
        storage[head] = value
        head = head + 1 == capacity ? 0 : head + 1
        if count < capacity { count += 1 }
    }

    /// `0` is the oldest sample still held, `count - 1` the newest.
    public subscript(index: Int) -> Float {
        precondition(index >= 0 && index < count)
        let start = head - count
        let physical = start + index
        return storage[physical < 0 ? physical + capacity : physical]
    }

    public var last: Float? { isEmpty ? nil : self[count - 1] }

    /// A copy in chronological order, for drawing.
    public func values() -> [Float] { (0..<count).map { self[$0] } }

    public mutating func removeAll() {
        head = 0
        count = 0
    }
}
