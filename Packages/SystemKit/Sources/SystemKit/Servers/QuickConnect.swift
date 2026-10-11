import Foundation

/// Host aliases from `~/.ssh/config`, read-only. The file is never written, and nothing but the alias names is
/// taken from it: no host names, users, key paths or options, and none of it is logged.
public enum SSHConfigReader {
    public static let sizeLimit = 256 * 1024
    public static let aliasLimit = 200

    public static var defaultPath: String { NSHomeDirectory() + "/.ssh/config" }

    /// The aliases in `path`, sorted. A file that is missing, too large or unreadable gives an empty list.
    public static func aliases(at path: String = defaultPath) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: sizeLimit + 1), data.count <= sizeLimit else { return [] }
        return aliases(in: String(decoding: data, as: UTF8.self))
    }

    /// `Host a b c` lines. A name with a wildcard, a negation or any character outside the alias alphabet is skipped.
    public static func aliases(in text: String) -> [String] {
        var found = Set<String>()
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.count >= 2, parts[0].lowercased() == "host" else { continue }
            for name in parts.dropFirst() {
                if name.hasPrefix("#") { break }
                if let alias = ServerInput.alias(String(name)) { found.insert(alias) }
                if found.count >= aliasLimit { return found.sorted() }
            }
        }
        return found.sorted()
    }
}

/// What "Quick connect" hands to Terminal.app.
///
/// **Why a `.command` file.** Terminal runs a `.command` file without interpreting anything we pass it: the file holds
/// one fixed line, `exec /usr/bin/ssh [-l user] [-p port] -- host`, and every value in it has already passed
/// ``ServerInput`` (letters, digits and `._-:` only, never a leading `-`), so none of it can end a quote, start an option
/// or open a second command. The alternatives were worse: AppleScript `do script` means building a command *string* from
/// user input and asks for Automation permission, and an `ssh://` URL leaves the command line to whichever app is the
/// registered handler. The file lives in the app's own 0700 directory and is removed when the app quits.
public enum QuickConnect {
    /// The file's text, or nil if a value is not acceptable. Pure: nothing is written here.
    public static func script(host: String, user: String? = nil, port: Int? = nil) -> String? {
        guard let host = ServerInput.host(host) else { return nil }
        var arguments = ["/usr/bin/ssh"]
        if let user {
            guard let valid = ServerInput.user(user) else { return nil }
            arguments += ["-l", valid]
        }
        if let port {
            guard (1...65_535).contains(port) else { return nil }
            arguments += ["-p", String(port)]
        }
        arguments += ["--", host]
        return "#!/bin/sh\nexec " + arguments.map(quoted).joined(separator: " ") + "\n"
    }

    /// Single quotes around each word. The words cannot hold a quote (validated), but a word that does is refused, not escaped.
    static func quoted(_ word: String) -> String { "'" + word + "'" }

    /// File name for a host: only the validated alphabet, no path separator.
    public static func fileName(host: String, user: String?, port: Int?) -> String? {
        guard let host = ServerInput.host(host) else { return nil }
        let safe = host.replacingOccurrences(of: ":", with: "_")
        return "ssh-\(safe)-\(user ?? "")-\(port.map(String.init) ?? "").command"
    }

    /// Writes the file into `directory` (made 0700 if needed) with mode 0700 and returns its path. nil on any problem.
    public static func writeCommandFile(host: String, user: String? = nil, port: Int? = nil, in directory: String) -> String? {
        guard let text = script(host: host, user: user, port: port), let name = fileName(host: host, user: user, port: port),
              RemoteActor.prepareDirectoryKeepingContents(directory) else { return nil }
        let path = directory + "/" + name
        guard FileManager.default.createFile(atPath: path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o700]) else { return nil }
        return path
    }

    public static func removeFiles(in directory: String) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] where name.hasSuffix(".command") {
            try? FileManager.default.removeItem(atPath: directory + "/" + name)
        }
    }
}

extension RemoteActor {
    /// Like `prepareDirectory`, but leaves what is inside alone.
    static func prepareDirectoryKeepingContents(_ path: String) -> Bool {
        let manager = FileManager.default
        if !manager.fileExists(atPath: path) {
            guard (try? manager.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil else { return false }
        }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { return false }
        if info.st_mode & 0o077 != 0 { guard chmod(path, 0o700) == 0 else { return false } }
        return true
    }
}
