import Darwin
import Foundation

/// Everything the user types ends up in an argument list of `ssh` or `ping`, so every value passes
/// through here first: a small allowed alphabet, a length limit, and nothing that starts with `-`
/// (an option in disguise: `-oProxyCommand=…`). A value that fails comes back nil; there is no
/// "repair". The argument lists put `--` before the host on top of this, so the two defenses are independent.
public enum ServerInput {
    public static let maxHostLength = 253
    public static let maxUserLength = 32
    public static let maxNameLength = 40

    private static let hostCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
    private static let userCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    /// A host name, an IPv4 / IPv6 literal, or an alias from `~/.ssh/config`. No wildcards, no `@`, no brackets, no zone ids.
    public static func host(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.utf8.count <= maxHostLength, text.allSatisfy(\.isASCII), !text.hasPrefix("-") else { return nil }
        if text.contains(":") { return isIPv6(text) ? text : nil }
        guard text.allSatisfy(hostCharacters.contains) else { return nil }
        for label in text.split(separator: ".", omittingEmptySubsequences: false) {
            guard (1...63).contains(label.utf8.count), !label.hasPrefix("-"), !label.hasSuffix("-") else { return nil }
        }
        return text
    }

    /// An alias as written after `Host` in `~/.ssh/config`: the host rule, and it must not look like a pattern (already excluded by the alphabet).
    public static func alias(_ raw: String) -> String? {
        guard let value = host(raw), !value.contains(":"), value.utf8.count <= 64 else { return nil }
        return value
    }

    public static func user(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.utf8.count <= maxUserLength, !text.hasPrefix("-"), text.allSatisfy(userCharacters.contains) else { return nil }
        return text
    }

    /// 1...65535, digits only (no sign, no space, no hex).
    public static func port(_ raw: String) -> Int? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard (1...5).contains(text.utf8.count), text.allSatisfy({ $0 >= "0" && $0 <= "9" }), let value = Int(text), (1...65_535).contains(value) else { return nil }
        return value
    }

    /// A label the user chooses: printable, one line.
    public static func displayName(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxNameLength else { return nil }
        for scalar in text.unicodeScalars where scalar.properties.generalCategory == .control
            || scalar.properties.generalCategory == .format || scalar.properties.generalCategory == .lineSeparator
            || scalar.properties.generalCategory == .paragraphSeparator || scalar.properties.generalCategory == .unassigned {
            return nil
        }
        return text
    }

    /// The text must parse as an IPv6 address and contain nothing but hex digits, colons and dots.
    static func isIPv6(_ text: String) -> Bool {
        guard text.utf8.count <= 45, text.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) else { return false }
        var address = in6_addr()
        return inet_pton(AF_INET6, text, &address) == 1
    }

    /// Loopback only: a forward listens on this Mac, and nothing in the module should open it to the network.
    public static func loopbackBind(_ raw: String) -> String? {
        switch raw.trimmingCharacters(in: .whitespaces) {
        case "127.0.0.1", "localhost": return "127.0.0.1"
        case "::1": return "::1"
        default: return nil
        }
    }

    /// An IPv6 literal goes into a forward specification in brackets.
    static func bracketed(_ host: String) -> String { host.contains(":") ? "[\(host)]" : host }
}
