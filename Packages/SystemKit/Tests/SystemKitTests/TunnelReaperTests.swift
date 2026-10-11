import Foundation
import Testing
@testable import SystemKit

@Suite("Artık tünel süreçleri")
struct TunnelReaperTests {
    let record = TunnelRecord(pid: 4242, startSeconds: 1_700_000_000, startMicroseconds: 123_456)
    func live(path: String? = "/usr/bin/ssh", sec: UInt64 = 1_700_000_000, micro: UInt64 = 123_456, uid: UInt32 = 501) -> LiveProcessInfo {
        LiveProcessInfo(path: path, startSeconds: sec, startMicroseconds: micro, uid: uid)
    }

    @Test func decisionTable() {
        #expect(TunnelReaper.shouldTerminate(record, live: live(), ownUID: 501))
        #expect(!TunnelReaper.shouldTerminate(record, live: nil, ownUID: 501), "süreç yok")
        #expect(!TunnelReaper.shouldTerminate(record, live: live(path: "/bin/sleep"), ownUID: 501), "farklı program")
        #expect(!TunnelReaper.shouldTerminate(record, live: live(path: nil), ownUID: 501), "yol okunamadı")
        #expect(!TunnelReaper.shouldTerminate(record, live: live(path: "/usr/local/bin/ssh"), ownUID: 501))
        #expect(!TunnelReaper.shouldTerminate(record, live: live(sec: 1_700_000_001), ownUID: 501), "pid yeniden kullanılmış")
        #expect(!TunnelReaper.shouldTerminate(record, live: live(micro: 123_457), ownUID: 501), "mikrosaniye farkı")
        #expect(!TunnelReaper.shouldTerminate(record, live: live(uid: 0), ownUID: 501), "sahibi başkası")
        for pid: Int32 in [0, 1, -1] {
            #expect(!TunnelReaper.shouldTerminate(TunnelRecord(pid: pid, startSeconds: 1_700_000_000, startMicroseconds: 123_456), live: live(), ownUID: 501))
        }
    }

    @Test func parsingIsStrict() {
        #expect(TunnelReaper.parse(Data("4242 1700000000 123456\n77 5 6\n".utf8)).count == 2)
        let bad = ["", "abc", "1 2", "1 2 3 4", "-5 1 1", "+5 1 1", "5 1 1000000", "0x10 1 1", "5  1 1", " 5 1 1", "99999999999 1 1", "5 1 1;rm", "\u{0}\u{1}"]
        for line in bad { #expect(TunnelReaper.parse(Data((line + "\n").utf8)).isEmpty, "\(line.debugDescription)") }
        #expect(TunnelReaper.parse(Data(repeating: 0x31, count: TunnelReaper.sizeLimit + 1)).isEmpty)
        #expect(TunnelReaper.parse(Data([0xFF, 0xFE, 0x00])).isEmpty)
        let many = (0..<100).map { "\($0 + 10) 1 1" }.joined(separator: "\n")
        #expect(TunnelReaper.parse(Data(many.utf8)).count == TunnelReaper.entryLimit)
        #expect(TunnelReaper.parse(TunnelReaper.serialize([record])) == [record])
    }

    func directory() throws -> String {
        let path = NSTemporaryDirectory() + "sistem-tr-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return path
    }

    @Test func matchingRecordIsSignalledAndFileRemoved() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        TunnelReaper.write([record], directory: dir)
        var signalled: [Int32] = []
        let ended = TunnelReaper.reapOrphans(directory: dir, lookup: { _ in live(uid: getuid()) }, signal: { signalled.append($0) })
        #expect(ended == 1 && signalled == [4242])
        #expect(!FileManager.default.fileExists(atPath: dir + "/" + TunnelReaper.fileName))
    }

    @Test func mismatchingRecordsAreNeverSignalled() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let cases: [LiveProcessInfo?] = [live(path: "/bin/sleep", uid: getuid()), live(sec: 5, uid: getuid()), live(uid: getuid() + 1), nil]
        for other in cases {
            TunnelReaper.write([record], directory: dir)
            var signalled = 0
            _ = TunnelReaper.reapOrphans(directory: dir, lookup: { _ in other }, signal: { _ in signalled += 1 })
            #expect(signalled == 0)
            #expect(!FileManager.default.fileExists(atPath: dir + "/" + TunnelReaper.fileName), "kayıt her durumda silinir")
        }
    }

    @Test func damagedOversizedAndLinkedFilesAreIgnored() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/" + TunnelReaper.fileName
        var signalled = 0
        let always: (Int32) -> LiveProcessInfo? = { _ in live(uid: getuid()) }
        // damaged
        try Data("garbage\n\u{0}\u{1}1 2 3 4\n".utf8).write(to: URL(filePath: path))
        _ = TunnelReaper.reapOrphans(directory: dir, lookup: always, signal: { _ in signalled += 1 })
        // oversized, but starting with a valid line
        try Data(("4242 1700000000 123456\n" + String(repeating: "x", count: 10_000)).utf8).write(to: URL(filePath: path))
        _ = TunnelReaper.reapOrphans(directory: dir, lookup: always, signal: { _ in signalled += 1 })
        // a link to a valid file elsewhere
        let target = dir + "-target"
        defer { try? FileManager.default.removeItem(atPath: target) }
        try TunnelReaper.serialize([record]).write(to: URL(filePath: target))
        try? FileManager.default.removeItem(atPath: path)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
        _ = TunnelReaper.reapOrphans(directory: dir, lookup: always, signal: { _ in signalled += 1 })
        #expect(signalled == 0)
        #expect(FileManager.default.fileExists(atPath: target), "bağın gösterdiği dosyaya dokunulmaz")
    }

    @Test func looseDirectoryIsNotTrusted() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        TunnelReaper.write([record], directory: dir)
        chmod(dir, 0o755)
        var signalled = 0
        _ = TunnelReaper.reapOrphans(directory: dir, lookup: { _ in live(uid: getuid()) }, signal: { _ in signalled += 1 })
        #expect(signalled == 0)
        #expect(TunnelReaper.reapOrphans(directory: "/nonexistent/dir") == 0)
    }

    @Test func bookWritesAndForgetsRecords() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let book = TunnelRecordBook(directory: dir, lookup: { pid in pid == 7 ? nil : LiveProcessInfo(path: "/usr/bin/ssh", startSeconds: 9, startMicroseconds: 8, uid: getuid()) })
        let file = dir + "/" + TunnelReaper.fileName
        book.add(pid: 100)
        book.add(pid: 200)
        book.add(pid: 7)  // not found: not recorded
        book.add(pid: 1)
        #expect(TunnelReaper.parse(try Data(contentsOf: URL(filePath: file))).map(\.pid) == [100, 200])
        #expect((try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int) == 0o600)
        book.remove(pid: 100)
        #expect(TunnelReaper.parse(try Data(contentsOf: URL(filePath: file))).map(\.pid) == [200])
        book.removeAll()
        #expect(!FileManager.default.fileExists(atPath: file))
    }

    /// Real process table: a real child is recognised by its path and start time, and a wrong start time protects it.
    @Test func realProcessLookupAndTermination() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let child = Process()
        child.executableURL = URL(filePath: "/bin/sleep")
        child.arguments = ["60"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let pid = child.processIdentifier
        let info = try #require(TunnelReaper.liveInfo(pid: pid))
        #expect(info.path?.hasSuffix("/sleep") == true && info.uid == getuid())
        // Wrong start time: untouched.
        TunnelReaper.write([TunnelRecord(pid: pid, startSeconds: info.startSeconds &+ 1, startMicroseconds: info.startMicroseconds)], directory: dir)
        #expect(TunnelReaper.reapOrphans(directory: dir, expectedPath: info.path ?? "") == 0)
        #expect(child.isRunning)
        // Exact record: SIGTERM.
        TunnelReaper.write([TunnelRecord(pid: pid, startSeconds: info.startSeconds, startMicroseconds: info.startMicroseconds)], directory: dir)
        #expect(TunnelReaper.reapOrphans(directory: dir, expectedPath: info.path ?? "") == 1)
        child.waitUntilExit()
        #expect(child.terminationReason == .uncaughtSignal)
        #expect(TunnelReaper.liveInfo(pid: 0) == nil)
    }

    /// The remote actor writes the record when it launches a tunnel and forgets it when the process has ended.
    @Test func remoteActorRecordsTunnelsWhileTheyRun() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let child = Process()
        child.executableURL = URL(filePath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let runner = FakeProcessRunner()
        runner.setNextPID(child.processIdentifier)
        let remote = RemoteActor(runner: runner, clock: ManualServerClock(), environment: SSHEnvironment(), tunnelRecordDirectory: dir)
        let tunnel = TunnelSpec(kind: .dynamic, listenPort: 1080)
        let server = ServerConfig(name: "x", kind: .linux, host: "srv", tunnels: [tunnel])
        let process = try #require(await remote.launchTunnel(server: server, tunnel: tunnel))
        #expect(TunnelReaper.read(directory: dir).map(\.pid) == [child.processIdentifier])
        runner.launched[0].end(ProcessResult(outcome: .exited(255)))
        _ = await process.finished()
        #expect(TunnelReaper.read(directory: dir).isEmpty, "süreç bitince kayıt silinir")
        // And clearing at quit.
        let second = try #require(await remote.launchTunnel(server: server, tunnel: tunnel))
        #expect(!TunnelReaper.read(directory: dir).isEmpty)
        await remote.clearTunnelRecords()
        #expect(TunnelReaper.read(directory: dir).isEmpty)
        _ = second
    }
}
