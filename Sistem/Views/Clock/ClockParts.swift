import SistemUI
import SwiftUI
import SystemKit

/// Re-renders its content at the next minute, or the next second when the pattern shows seconds.
/// SwiftUI stops the timeline while the view is off screen, so a closed page or popover costs nothing.
struct ClockTimeline<Content: View>: View {
    let showsSeconds: Bool
    @ViewBuilder let content: (Date) -> Content

    var body: some View {
        if showsSeconds {
            TimelineView(.periodic(from: .now, by: 1)) { content($0.date) }
        } else {
            TimelineView(.everyMinute) { content($0.date) }
        }
    }
}

/// Local time large, the full date under it.
struct LocalTimeSummary: View {
    let settings: SettingsStore
    var compact = false

    var body: some View {
        let showsSeconds = settings.clockDisplay.showsSeconds
        ClockTimeline(showsSeconds: showsSeconds) { date in
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: date.formatted(Date.FormatStyle(date: .omitted, time: showsSeconds ? .standard : .shortened)))
                    .font(compact ? .sistemBigValue : .system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink)
                Text(verbatim: date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                    .font(.sistemBody).foregroundStyle(Palette.inkSecondary)
                Text(verbatim: TimeZone.current.localizedName(for: .standard, locale: .autoupdatingCurrent) ?? TimeZone.current.identifier)
                    .font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
            }
        }
    }
}

/// The user's extra time zones: city, time, and how far it is from here.
struct ZoneRows: View {
    let identifiers: [String]
    let showsSeconds: Bool
    var limit = ZoneRow.unlimited
    var onRemove: ((String) -> Void)?

    var body: some View {
        ClockTimeline(showsSeconds: showsSeconds) { date in
            VStack(spacing: 10) {
                ForEach(identifiers.prefix(limit), id: \.self) { identifier in
                    if let zone = TimeZone(identifier: identifier) {
                        ZoneRow(zone: zone, date: date, showsSeconds: showsSeconds, onRemove: onRemove.map { remove in { remove(identifier) } })
                    }
                }
            }
        }
    }
}

struct ZoneRow: View {
    static let unlimited = Int.max
    let zone: TimeZone
    let date: Date
    let showsSeconds: Bool
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: ZoneInfo.city(zone)).font(.sistemBody).foregroundStyle(Palette.ink)
                Text(verbatim: ZoneInfo.relation(zone, at: date)).font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
            }
            Spacer(minLength: 8)
            Text(verbatim: date.formatted(Date.FormatStyle(date: .omitted, time: showsSeconds ? .standard : .shortened, timeZone: zone)))
                .font(.sistemValue).monospacedDigit().foregroundStyle(Palette.ink)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.inkTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Kaldır"))
            }
        }
    }
}

enum ZoneInfo {
    /// "America/New_York" → "New York".
    static func city(_ zone: TimeZone) -> String {
        (zone.identifier.split(separator: "/").last.map(String.init) ?? zone.identifier).replacingOccurrences(of: "_", with: " ")
    }

    /// "Bugün · +3 sa", "Yarın · −2 sa 30 dk", "Dün · aynı saat".
    static func relation(_ zone: TimeZone, at date: Date) -> String {
        let local = TimeZone.autoupdatingCurrent
        let minutes = (zone.secondsFromGMT(for: date) - local.secondsFromGMT(for: date)) / 60
        let day = dayDifference(zone, local, at: date)
        let dayName = switch day {
        case 0: String(localized: "Bugün")
        case 1: String(localized: "Yarın")
        case -1: String(localized: "Dün")
        default: ""
        }
        let offset: String
        if minutes == 0 {
            offset = String(localized: "aynı saat")
        } else {
            let hours = abs(minutes) / 60, rest = abs(minutes) % 60
            let magnitude = rest == 0 ? String(localized: "\(hours) sa") : String(localized: "\(hours) sa \(rest) dk")
            offset = (minutes < 0 ? "−" : "+") + magnitude
        }
        return dayName.isEmpty ? offset : "\(dayName) · \(offset)"
    }

    private static func dayDifference(_ zone: TimeZone, _ local: TimeZone, at date: Date) -> Int {
        func ordinal(_ zone: TimeZone) -> Int {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = .gmt
            let days = utc.date(from: parts).map { Int($0.timeIntervalSince1970 / 86_400) }
            return days ?? 0
        }
        return ordinal(zone) - ordinal(local)
    }
}

/// A month grid, week starting where the user's calendar says it does. Today is filled.
struct MonthCalendar: View {
    @State private var month: Date = .now
    private let calendar = Calendar.autoupdatingCurrent
    var compact = false

    var body: some View {
        let metrics = days()
        VStack(spacing: compact ? 6 : 10) {
            HStack {
                Text(verbatim: month.formatted(.dateTime.month(.wide).year()))
                    .font(.sistemValue).foregroundStyle(Palette.ink)
                Spacer()
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(Palette.inkSecondary).accessibilityLabel(Text("Önceki ay"))
                Button("Bugün") { month = .now }.buttonStyle(QuietButtonStyle())
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain).foregroundStyle(Palette.inkSecondary).accessibilityLabel(Text("Sonraki ay"))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: compact ? 2 : 4) {
                ForEach(Array(weekdaySymbols().enumerated()), id: \.offset) { _, symbol in
                    Text(verbatim: symbol).font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
                }
                ForEach(Array(metrics.cells.enumerated()), id: \.offset) { _, day in
                    if let day {
                        let today = metrics.today == day
                        Text(verbatim: "\(day)")
                            .font(.sistemBody).monospacedDigit()
                            .foregroundStyle(today ? Palette.onAccent : Palette.ink)
                            .frame(width: 26, height: 22)
                            .background(today ? Palette.accent : .clear, in: .rect(cornerRadius: 6))
                    } else {
                        Color.clear.frame(height: 22)
                    }
                }
            }
        }
    }

    private func shift(_ months: Int) {
        month = calendar.date(byAdding: .month, value: months, to: month) ?? month
    }

    private func weekdaySymbols() -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// Leading blanks, then day numbers; `today` is the day of the displayed month that is today, if any.
    private func days() -> (cells: [Int?], today: Int?) {
        guard let start = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
              let range = calendar.range(of: .day, in: .month, for: start) else { return ([], nil) }
        let lead = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let isThisMonth = calendar.isDate(month, equalTo: .now, toGranularity: .month)
        return (Array(repeating: nil, count: lead) + range.map { Optional($0) }, isThisMonth ? calendar.component(.day, from: .now) : nil)
    }
}
