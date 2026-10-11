import Foundation
import os
@testable import SystemKit

/// A clock that only moves when a test says so. `sleep` returns when `advance` passes its due time.
final class ManualServerClock: ServerClock, @unchecked Sendable {
    private struct Sleeper {
        var id: Int
        var due: TimeInterval
        var continuation: CheckedContinuation<Void, Error>
    }
    private struct State {
        var offset: TimeInterval = 0
        var sleepers: [Sleeper] = []
        var cancelled: Set<Int> = []
        var nextID = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let base = Date(timeIntervalSinceReferenceDate: 5_000_000)

    func now() -> Date { base.addingTimeInterval(state.withLock { $0.offset }) }
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(for seconds: TimeInterval) async throws {
        let id = state.withLock { state -> Int in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let immediate: Bool = state.withLock { state in
                    if state.cancelled.remove(id) != nil { return true }
                    state.sleepers.append(Sleeper(id: id, due: state.offset + seconds, continuation: continuation))
                    return false
                }
                if immediate { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let found: CheckedContinuation<Void, Error>? = state.withLock { state in
                if let index = state.sleepers.firstIndex(where: { $0.id == id }) { return state.sleepers.remove(at: index).continuation }
                state.cancelled.insert(id)
                return nil
            }
            found?.resume(throwing: CancellationError())
        }
    }

    func advance(by seconds: TimeInterval) {
        let due: [Sleeper] = state.withLock { state in
            state.offset += seconds
            let ready = state.sleepers.filter { $0.due <= state.offset }
            state.sleepers.removeAll { $0.due <= state.offset }
            return ready
        }
        for sleeper in due.sorted(by: { $0.due < $1.due }) { sleeper.continuation.resume() }
    }
}

/// Waits (really) until `condition` holds; tests use it instead of fixed sleeps.
func eventually(timeout: TimeInterval = 3, _ condition: @Sendable () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@MainActor
func eventuallyOnMain(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// Scripted process runner. Nothing real is started.
final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {
    enum Behavior {
        case result(ProcessResult)
        /// Never returns by itself; returns `.cancelled` when its task is cancelled (as the live runner does).
        case hang
    }
    private struct State {
        var requests: [ProcessRequest] = []
        var cancelled = 0
        var launched: [FakeRunningProcess] = []
        var handler: @Sendable (ProcessRequest) -> Behavior = { _ in .result(ProcessResult(outcome: .exited(0))) }
        var launchHandler: @Sendable (ProcessRequest) -> Bool = { _ in true }
        var nextPID: Int32 = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var requests: [ProcessRequest] { state.withLock { $0.requests } }
    var cancelledCount: Int { state.withLock { $0.cancelled } }
    var launched: [FakeRunningProcess] { state.withLock { $0.launched } }
    func setNextPID(_ pid: Int32) { state.withLock { $0.nextPID = pid } }

    func respond(_ handler: @escaping @Sendable (ProcessRequest) -> Behavior) { state.withLock { $0.handler = handler } }
    func allowLaunch(_ handler: @escaping @Sendable (ProcessRequest) -> Bool) { state.withLock { $0.launchHandler = handler } }

    func run(_ request: ProcessRequest) async -> ProcessResult {
        let handler = state.withLock { state -> @Sendable (ProcessRequest) -> Behavior in
            state.requests.append(request)
            return state.handler
        }
        switch handler(request) {
        case .result(let result):
            return result
        case .hang:
            let box = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)
            let wasCancelled = OSAllocatedUnfairLock(initialState: false)
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let resumeNow = wasCancelled.withLock { $0 }
                    if resumeNow { continuation.resume() } else { box.withLock { $0 = continuation } }
                }
            } onCancel: {
                wasCancelled.withLock { $0 = true }
                box.withLock { $0?.resume(); $0 = nil }
            }
            state.withLock { $0.cancelled += 1 }
            return ProcessResult(outcome: .cancelled)
        }
    }

    func launch(_ request: ProcessRequest) -> RunningProcess? {
        let (allowed, process): (Bool, FakeRunningProcess) = state.withLock { state in
            state.requests.append(request)
            let process = FakeRunningProcess()
            process.processIdentifier = state.nextPID
            let allowed = state.launchHandler(request)
            if allowed { state.launched.append(process) }
            return (allowed, process)
        }
        return allowed ? process : nil
    }
}

final class FakeRunningProcess: RunningProcess, @unchecked Sendable {
    private struct State {
        var result: ProcessResult?
        var waiters: [CheckedContinuation<ProcessResult, Never>] = []
        var terminated = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var processIdentifier: Int32 = 0
    var wasTerminated: Bool { state.withLock { $0.terminated } }

    func terminate() {
        state.withLock { $0.terminated = true }
        end(ProcessResult(outcome: .exited(143)))
    }

    /// The process exits by itself with this stderr (a drop, a refusal).
    func end(_ result: ProcessResult) {
        let waiters: [CheckedContinuation<ProcessResult, Never>] = state.withLock { state in
            guard state.result == nil else { return [] }
            state.result = result
            let waiters = state.waiters
            state.waiters = []
            return waiters
        }
        for waiter in waiters { waiter.resume(returning: result) }
    }

    func finished() async -> ProcessResult {
        await withCheckedContinuation { continuation in
            let ready: ProcessResult? = state.withLock { state in
                if let result = state.result { return result }
                state.waiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

enum Samples {
    static let linux = """
    SISTEM1 linux
    cpu 1000 10 500 8000 100 0 20 0
    cores 4
    mem 8000000 2000000 1000000 900000
    load 0.50 0.40 0.30
    up 86400.55
    net 1000000 500000
    disk 100000000 40000000
    END
    """

    static let macOS = """
    SISTEM1 macos
    memsize 17179869184
    cores 12
    vm 16384 10000 200000 100000 5000 150000 50000
    load 1.50 1.20 1.00
    boot 1700000000
    now 1700003600
    cpupct 10.5 5.5 84.0
    net 5000 7000
    disk 976490576 300000000
    END
    """

    static let docker = """
    SISTEM1 docker
    ctr web|1.50%|50.1MiB / 1.9GiB
    ctr db|120.00%|1.2GiB / 4GiB
    END
    """

    static func server(_ name: String = "Sunucu", kind: ServerKind = .linux, host: String = "srv.example.invalid",
                       tunnels: [TunnelSpec] = []) -> ServerConfig {
        ServerConfig(name: name, kind: kind, host: host, user: "ozan", port: 22, tunnels: tunnels)
    }

    static func ok(_ text: String) -> ProcessResult { ProcessResult(outcome: .exited(0), output: Data(text.utf8)) }
    static func sshError(_ text: String) -> ProcessResult { ProcessResult(outcome: .exited(255), errorOutput: Data(text.utf8)) }
}
