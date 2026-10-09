import Foundation

/// Rules for the clock menu bar item that must not live in the view layer so they can be tested.
public enum ClockFormat {
    /// True when a `DateFormatter` pattern shows seconds: an `s` outside quoted text.
    /// "HH:mm" → false, "HH:mm:ss" → true, "HH 'saat' mm 'sn'" → false.
    public static func containsSeconds(_ pattern: String) -> Bool {
        var quoted = false
        for character in pattern {
            if character == "'" { quoted.toggle(); continue }
            if !quoted && character == "s" { return true }
        }
        return false
    }

    /// The next instant the displayed text can change: the start of the next minute, or of the
    /// next second when the pattern shows seconds. A hair past the boundary, so the formatter
    /// never sees the old value again.
    public static func nextUpdate(after date: Date, pattern: String) -> Date {
        let step: Double = containsSeconds(pattern) ? 1 : 60
        let t = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (t / step).rounded(.down) * step + step + 0.02)
    }

    /// Patterns offered as one-tap presets. Plain `DateFormatter` syntax.
    public static let presets = ["HH:mm", "HH:mm:ss", "EEE HH:mm", "d MMM HH:mm", "h:mm a"]

    /// The default: the user's own time style (24-hour or 12-hour as their region sets it).
    public static func defaultPattern(locale: Locale = .current) -> String {
        DateFormatter.dateFormat(fromTemplate: "jm", options: 0, locale: locale) ?? "HH:mm"
    }

    /// A pattern a text field can hold: plain length limit, no control characters.
    public static func sanitized(_ pattern: String) -> String {
        String(pattern.filter { !$0.isNewline && $0.asciiValue.map { $0 >= 32 } ?? true }.prefix(40))
    }
}
