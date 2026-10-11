import Darwin
import Foundation

/// What is known about a running process, for deciding whether it is one of ours.
public struct LiveProcessInfo: Equatable, Sendable {
    public var path: String?
    public var startSeconds: UInt64
    public var startMicroseconds: UInt64
    public var uid: UInt32

    public init(path: String?, startSeconds: UInt64, startMicroseconds: UInt64, uid: UInt32) {
        self.path = path
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
        self.uid = uid
    }
}

/// A tunnel `ssh` this app started: its pid and the exact moment the process started. A pid alone proves nothing, because
/// numbers are reused; the start time makes the pair identify one process.
public struct TunnelRecord: Equatable, Sendable {
    public var pid: Int32
    public var startSeconds: UInt64
    public var startMicroseconds: UInt64
}

/// Tunnels outlive the app when it is killed (`kill -9`): the `ssh` child keeps running and keeps its port open on
/// 127.0.0.1. So every tunnel process is written to a small file in the app's own private directory while it runs, and at
/// the next launch each entry that still describes the very same process is ended.
///
/// A signal is sent only if ALL of these hold: the process exists, its path is `/usr/bin/ssh`, it started at the recorded
/// instant, and it belongs to this user. Anything else (reused pid, other program, edited or damaged file, a link instead
/// of a file) is left alone. The file is read as untrusted data: size limit, only numbers, few entries.
public enum TunnelReaper {
    public static let fileName = "tunnels"
    public static let sizeLimit = 4 * 1024
    public static let entryLimit = 32

    /// The decision. Pure.
    public static func shouldTerminate(_ record: TunnelRecord, live: LiveProcessInfo?, ownUID: UInt32, expectedPath: String = "/usr/bin/ssh") -> Bool {
        guard let live, record.pid > 1, live.path == expectedPath, live.uid == ownUID,
              live.startSeconds == record.startSeconds, live.startMicroseconds == record.startMicroseconds else { return false }
        return true
    }

    /// "pid seconds microseconds" per line; anything that is not exactly that is skipped.
    public static func parse(_ data: Data) -> [TunnelRecord] {
        guard data.count <= sizeLimit, let text = String(data: data, encoding: .utf8) else { return [] }
        var records: [TunnelRecord] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(entryLimit) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count == 3, fields.allSatisfy({ !$0.isEmpty && $0.count <= 12 && $0.allSatisfy { $0 >= "0" && $0 <= "9" } }),
                  let pid = Int32(fields[0]), let seconds = UInt64(fields[1]), let micro = UInt64(fields[2]), micro < 1_000_000 else { continue }
            records.append(TunnelRecord(pid: pid, startSeconds: seconds, startMicroseconds: micro))
        }
        return records
    }

    public static func serialize(_ records: [TunnelRecord]) -> Data {
        Data(records.prefix(entryLimit).map { "\($0.pid) \($0.startSeconds) \($0.startMicroseconds)\n" }.joined().utf8)
    }

    /// Reads the file only if it is a regular file (never a link) of ours inside a private directory.
    static func read(directory: String) -> [TunnelRecord] {
        let path = directory + "/" + fileName
        guard isPrivateDirectory(directory) else { return [] }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_size <= sizeLimit,
              let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: sizeLimit + 1) else { return [] }
        return parse(data)
    }

    static func write(_ records: [TunnelRecord], directory: String) {
        guard RemoteActor.prepareDirectoryKeepingContents(directory) else { return }
        let path = directory + "/" + fileName
        if records.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        // Replace through a temporary file so a crash in the middle never leaves half a file; mode 0600.
        let temporary = path + ".new"
        try? FileManager.default.removeItem(atPath: temporary)
        guard FileManager.default.createFile(atPath: temporary, contents: serialize(records), attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temporary, path) != 0 { try? FileManager.default.removeItem(atPath: temporary) }
    }

    static func isPrivateDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid() && info.st_mode & 0o077 == 0
    }

    /// Ends the leftovers of an earlier run and deletes the record. Returns how many processes got SIGTERM.
    /// `lookup` and `signal` are injectable; the defaults are the real system calls.
    @discardableResult
    public static func reapOrphans(directory: String, expectedPath: String = "/usr/bin/ssh",
                                   lookup: (Int32) -> LiveProcessInfo? = liveInfo, signal: (Int32) -> Void = { _ = kill($0, SIGTERM) }) -> Int {
        let path = directory + "/" + fileName
        // Nothing recorded (the usual case): one failed stat and no more.
        var probe = stat()
        guard lstat(path, &probe) == 0 else { return 0 }
        var ended = 0
        for record in read(directory: directory) where shouldTerminate(record, live: lookup(record.pid), ownUID: getuid(), expectedPath: expectedPath) {
            signal(record.pid)
            ended += 1
        }
        // The record is removed whatever it held: a damaged file must not be tried again at every launch.
        if isPrivateDirectory(directory), (probe.st_mode & S_IFMT) == S_IFREG || (probe.st_mode & S_IFMT) == S_IFLNK {
            try? FileManager.default.removeItem(atPath: path)
        }
        return ended
    }

    /// The process table entry of `pid`, or nil when there is none.
    public static func liveInfo(pid: Int32) -> LiveProcessInfo? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_pid == UInt32(pid) else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = length > 0 ? String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
        return LiveProcessInfo(path: path, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec, uid: info.pbi_uid)
    }
}

/// The running list: add when a tunnel starts, remove when it ends. All changes go through one lock.
public final class TunnelRecordBook: @unchecked Sendable {
    private let directory: String
    private let lock = NSLock()
    private var records: [TunnelRecord] = []
    private let lookup: @Sendable (Int32) -> LiveProcessInfo?

    public init(directory: String, lookup: @escaping @Sendable (Int32) -> LiveProcessInfo? = { TunnelReaper.liveInfo(pid: $0) }) {
        self.directory = directory
        self.lookup = lookup
    }

    /// Records the process with its start time. A process that cannot be looked up (already gone) is not recorded.
    public func add(pid: Int32) {
        guard pid > 1, let live = lookup(pid) else { return }
        lock.lock(); defer { lock.unlock() }
        records.removeAll { $0.pid == pid }
        records.append(TunnelRecord(pid: pid, startSeconds: live.startSeconds, startMicroseconds: live.startMicroseconds))
        TunnelReaper.write(records, directory: directory)
    }

    public func remove(pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        guard records.contains(where: { $0.pid == pid }) else { return }
        records.removeAll { $0.pid == pid }
        TunnelReaper.write(records, directory: directory)
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        records = []
        TunnelReaper.write([], directory: directory)
    }
}
