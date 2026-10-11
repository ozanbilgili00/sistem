import Darwin
import Foundation
import os

/// One external program call: absolute path, fixed argument list, no shell. Standard input is optional.
public struct ProcessRequest: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var input: Data?
    /// Seconds before the process is killed, whatever it is doing.
    public var timeout: TimeInterval
    /// Bytes of standard output (and, separately, of standard error) that are kept; more than that ends the process.
    public var outputLimit: Int

    public init(executable: String, arguments: [String], environment: [String: String] = [:], input: Data? = nil,
                timeout: TimeInterval, outputLimit: Int = 64 * 1024) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.input = input
        self.timeout = timeout
        self.outputLimit = outputLimit
    }
}

public struct ProcessResult: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case exited(Int32)
        case timedOut
        case launchFailed
        case outputTooLarge
        case cancelled
    }

    public var outcome: Outcome
    public var output: Data
    public var errorOutput: Data

    public init(outcome: Outcome, output: Data = Data(), errorOutput: Data = Data()) {
        self.outcome = outcome
        self.output = output
        self.errorOutput = errorOutput
    }

    public var exitStatus: Int32? {
        if case .exited(let status) = outcome { status } else { nil }
    }
}

/// A process that keeps running (a tunnel). `finished` returns once, when it has ended.
public protocol RunningProcess: Sendable {
    var processIdentifier: Int32 { get }
    func terminate()
    func finished() async -> ProcessResult
}

/// Runs external programs. The live version is ``SystemProcessRunner``; tests bring a fake that can hang or lie.
public protocol ProcessRunning: Sendable {
    /// Runs to the end (or the timeout). Cancelling the calling task kills the process.
    func run(_ request: ProcessRequest) async -> ProcessResult
    /// Starts a long-lived process. nil = it could not be started.
    func launch(_ request: ProcessRequest) -> RunningProcess?
}

/// Every child this app started and has not seen end, so a quit can end them all (and a tunnel never outlives the app).
public final class ProcessRegistry: @unchecked Sendable {
    public static let shared = ProcessRegistry()
    private let lock = OSAllocatedUnfairLock(initialState: Set<pid_t>())
    init() {}

    func add(_ pid: pid_t) { lock.withLock { _ = $0.insert(pid) } }
    func remove(_ pid: pid_t) { lock.withLock { _ = $0.remove(pid) } }
    public var count: Int { lock.withLock { $0.count } }

    /// SIGTERM to every registered child, then SIGKILL for what is still there after `grace` seconds. Only pids this app started.
    public func terminateAll(grace: TimeInterval = 0.5) {
        let pids = lock.withLock { Array($0) }
        for pid in pids { kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, count > 0 { usleep(20_000) }
        for pid in lock.withLock({ Array($0) }) { kill(pid, SIGKILL) }
    }
}

/// `Process` with pipes, bounded output, a hard timeout and cancellation. Nothing here is logged.
public struct SystemProcessRunner: ProcessRunning {
    private let registry: ProcessRegistry

    public init(registry: ProcessRegistry = .shared) {
        self.registry = registry
        // A write to a pipe whose reader is gone must be an error, not a signal that ends the app.
        signal(SIGPIPE, SIG_IGN)
    }

    public func run(_ request: ProcessRequest) async -> ProcessResult {
        guard let job = LiveJob(request, registry: registry) else { return ProcessResult(outcome: .launchFailed) }
        return await withTaskCancellationHandler {
            await job.finished()
        } onCancel: {
            job.cancel()
        }
    }

    public func launch(_ request: ProcessRequest) -> RunningProcess? {
        LiveJob(request, registry: registry)
    }
}

/// One started process. Reads both pipes without blocking a thread, ends the process on timeout, over-long
/// output or `cancel()`, and reports exactly once.
final class LiveJob: RunningProcess, @unchecked Sendable {
    private struct State {
        var output = Data()
        var errorOutput = Data()
        var forced: ProcessResult.Outcome?
        var result: ProcessResult?
        var waiters: [CheckedContinuation<ProcessResult, Never>] = []
        var exitStatus: Int32?
        var exited = false
        var drained = 0
        var pid: pid_t = 0
    }

    private let process = Process()
    private let limit: Int
    private let registry: ProcessRegistry
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var pid: pid_t = 0
    var processIdentifier: Int32 { pid }
    private var timer: DispatchSourceTimer?
    private let standardOutput = Pipe()
    private let standardError = Pipe()

    init?(_ request: ProcessRequest, registry: ProcessRegistry) {
        self.registry = registry
        guard request.executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: request.executable) else { return nil }
        limit = request.outputLimit
        process.executableURL = URL(filePath: request.executable)
        process.arguments = request.arguments
        process.environment = request.environment
        process.standardOutput = standardOutput
        process.standardError = standardError
        let input = Pipe()
        process.standardInput = request.input == nil ? FileHandle.nullDevice : input
        process.terminationHandler = { [weak self] process in self?.exited(status: process.terminationStatus, reason: process.terminationReason) }
        do { try process.run() } catch { return nil }
        pid = process.processIdentifier
        // The exit callback may already have run (a very short process): then there is nothing to register.
        state.withLock { state in
            if !state.exited {
                state.pid = pid
                registry.add(pid)
            }
        }

        read(standardOutput.fileHandleForReading, isOutput: true)
        read(standardError.fileHandleForReading, isOutput: false)
        if let data = request.input {
            // The script is small; a process that stops reading early only costs a failed write.
            DispatchQueue.global(qos: .utility).async {
                try? input.fileHandleForWriting.write(contentsOf: data)
                try? input.fileHandleForWriting.close()
            }
        }
        let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        source.schedule(deadline: .now() + max(0.1, request.timeout), leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in self?.force(.timedOut) }
        source.activate()
        timer = source
    }

    private func read(_ handle: FileHandle, isOutput: Bool) {
        handle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                drainedOne()
                return
            }
            let overflow = state.withLock { state -> Bool in
                if isOutput {
                    state.output.append(chunk.prefix(max(0, limit + 1 - state.output.count)))
                    return state.output.count > limit
                }
                state.errorOutput.append(chunk.prefix(max(0, 8 * 1024 - state.errorOutput.count)))
                return false
            }
            if overflow { force(.outputTooLarge) }
        }
    }

    /// A pipe reached its end. A background ssh (a ControlMaster) may hold the pipes open after the client is gone:
    /// the result is reported when the process has exited and either both pipes are at their end or a short grace has passed.
    private func drainedOne() {
        state.withLock { $0.drained += 1 }
        finishIfReady()
    }

    private func exited(status: Int32, reason: Process.TerminationReason) {
        state.withLock { state in
            state.exited = true
            state.exitStatus = status
            if state.pid > 0 { registry.remove(state.pid) }
        }
        timer?.cancel()
        // Pipes that stay open (a forked master holds them) must not hold the answer back.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            // What is still in the pipe (a handler that never got its turn) is taken without waiting for an end that may never come.
            drain(standardOutput.fileHandleForReading, isOutput: true)
            drain(standardError.fileHandleForReading, isOutput: false)
            state.withLock { $0.drained = 2 }
            finishIfReady()
        }
        finishIfReady()
    }

    /// Reads what is available right now and stops at the first empty read (the descriptor is switched to non-blocking).
    private func drain(_ handle: FileHandle, isOutput: Bool) {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count > 0 else { return }
            let chunk = Data(buffer.prefix(count))
            state.withLock { state in
                if isOutput {
                    state.output.append(chunk.prefix(max(0, limit + 1 - state.output.count)))
                } else {
                    state.errorOutput.append(chunk.prefix(max(0, 8 * 1024 - state.errorOutput.count)))
                }
            }
        }
    }

    private func finishIfReady() {
        let ready: (ProcessResult, [CheckedContinuation<ProcessResult, Never>])? = state.withLock { state in
            guard state.result == nil, state.exited, state.drained >= 2 else { return nil }
            let outcome = state.forced ?? .exited(state.exitStatus ?? -1)
            let made = ProcessResult(outcome: outcome, output: Data(state.output.prefix(limit)), errorOutput: state.errorOutput)
            state.result = made
            let waiters = state.waiters
            state.waiters = []
            return (made, waiters)
        }
        if let (result, waiters) = ready { for waiter in waiters { waiter.resume(returning: result) } }
    }

    private func force(_ outcome: ProcessResult.Outcome) {
        let shouldKill = state.withLock { state -> Bool in
            guard state.forced == nil, !state.exited else { return false }
            state.forced = outcome
            return true
        }
        guard shouldKill else { return }
        terminate()
    }

    func cancel() { force(.cancelled) }

    func terminate() {
        guard pid > 0 else { return }
        if process.isRunning { process.terminate() }
        // A process that ignores SIGTERM does not get to keep a tunnel or a connection alive.
        let pid = pid
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self] in
            if let self, self.process.isRunning { kill(pid, SIGKILL) }
        }
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
