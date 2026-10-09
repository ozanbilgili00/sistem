import AppKit
import SystemKit

/// How the clock menu bar item reads out: a `DateFormatter` pattern, plus the short date that
/// can sit above it. Everything here runs only when the displayed text is about to change
/// (once a minute, or once a second for a pattern with seconds), never per tick.
struct ClockDisplay: Equatable {
    var pattern: String

    var showsSeconds: Bool { ClockFormat.containsSeconds(pattern) }

    @MainActor func text(_ date: Date) -> String {
        Self.formatter(pattern: pattern).string(from: date)
    }

    /// "Per 8 Eki": the weekday and day, above the time.
    @MainActor func dateLabel(_ date: Date) -> String {
        Self.formatter(template: "EEEdMMM").string(from: date)
    }

    /// The widest string this pattern can produce, so the status item's width is reserved for it
    /// and never shifts: every day of a year at a morning and an evening hour (names and AM/PM vary).
    @MainActor var widestText: String { Self.widest(key: "t:" + pattern) { text($0) } }

    @MainActor var widestLabel: String { Self.widest(key: "l:EEEdMMM") { dateLabel($0) } }

    // MARK: Cache

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    @MainActor private static var formatters: [String: DateFormatter] = [:]
    @MainActor private static var widths: [String: String] = [:]
    @MainActor private static var localeObserver: NSObjectProtocol?

    @MainActor private static func formatter(pattern: String? = nil, template: String? = nil) -> DateFormatter {
        let key = pattern.map { "p:" + $0 } ?? "t:" + (template ?? "")
        if localeObserver == nil {
            localeObserver = NotificationCenter.default.addObserver(forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { formatters.removeAll(); widths.removeAll() }
            }
        }
        if let cached = formatters[key] { return cached }
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        if let pattern { formatter.dateFormat = pattern } else if let template { formatter.setLocalizedDateFormatFromTemplate(template) }
        if formatters.count > 8 { formatters.removeAll() }
        formatters[key] = formatter
        return formatter
    }

    @MainActor private static func widest(key: String, _ format: (Date) -> String) -> String {
        if let cached = widths[key] { return cached }
        let start = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 10, minute: 48, second: 48)) ?? .now
        var best = "", bestWidth: CGFloat = 0
        for day in 0..<366 {
            for hour in [0, 12] {
                guard let date = Calendar.current.date(byAdding: DateComponents(day: day, hour: hour), to: start) else { continue }
                let candidate = format(date)
                let width = (candidate as NSString).size(withAttributes: [.font: font]).width
                if width > bestWidth { best = candidate; bestWidth = width }
            }
        }
        if widths.count > 8 { widths.removeAll() }
        widths[key] = best
        return best
    }
}
