import Foundation
import os

/// Time for the server code: the current date, and sleeping. Injectable, so a connection that hangs is
/// tested by moving a fake clock forward instead of waiting ten real seconds.
public protocol ServerClock: Sendable {
    func now() -> Date
    /// Returns after `seconds`; throws `CancellationError` when the task is cancelled first.
    func sleep(for seconds: TimeInterval) async throws
}

public struct SystemServerClock: ServerClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds), tolerance: .milliseconds(200))
    }
}

/// Runs `work` and gives up after `seconds` on `clock`, whichever comes first. Unlike a task group this
/// does not wait for `work` to finish after the deadline: a call that ignores cancellation is abandoned, not awaited.
/// nil = the deadline passed (or the calling task was cancelled).
public func withDeadline<T: Sendable>(_ seconds: TimeInterval, clock: any ServerClock,
                                      _ work: @escaping @Sendable () async -> T) async -> T? {
    let gate = DeadlineGate<T>()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            gate.install(continuation)
            let job = Task { gate.finish(await work()) }
            let timer = Task {
                do { try await clock.sleep(for: seconds) } catch { return }
                gate.finish(nil)
            }
            gate.attach(job, timer)
        }
    } onCancel: {
        gate.finish(nil)
    }
}

private final class DeadlineGate<T: Sendable>: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<T?, Never>?
        var done = false
        var pending: T??
        var tasks: [Task<Void, Never>] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func install(_ continuation: CheckedContinuation<T?, Never>) {
        let early: T?? = state.withLock { state in
            if state.done { return state.pending }
            state.continuation = continuation
            return nil
        }
        if let early { continuation.resume(returning: early) }
    }

    func attach(_ job: Task<Void, Never>, _ timer: Task<Void, Never>) {
        let cancelNow = state.withLock { state -> Bool in
            state.tasks = [job, timer]
            return state.done
        }
        if cancelNow { job.cancel(); timer.cancel() }
    }

    func finish(_ value: T?) {
        let (continuation, tasks) = state.withLock { state -> (CheckedContinuation<T?, Never>?, [Task<Void, Never>]) in
            guard !state.done else { return (nil, []) }
            state.done = true
            state.pending = .some(value)
            let continuation = state.continuation
            state.continuation = nil
            return (continuation, state.tasks)
        }
        for task in tasks { task.cancel() }
        continuation?.resume(returning: value)
    }
}
