import AppKit
import SistemUI
import SwiftUI
import SystemKit

/// Top processes, ranked by CPU or memory. Declares `.processes` demand only for
/// as long as it is on screen — the list is the one thing that makes the sampler
/// walk every process and run `ps`.
struct ProcessList: View {
    enum Ranking { case cpu, memory }

    let ranking: Ranking
    var limit = 5
    /// Page layout: all columns. Popover layout: name and the ranked value.
    var detailed = false
    @Environment(LiveFeed.self) private var feed

    var body: some View {
        let _ = feed.frame
        let sample = feed.store.processes
        let entries = Array((ranking == .cpu ? sample?.topCPU : sample?.topMemory)?.prefix(limit) ?? [])
        VStack(spacing: 0) {
            if detailed { header }
            if entries.isEmpty {
                Text("Süreçler okunuyor…")
                    .font(.sistemCaption)
                    .foregroundStyle(Palette.inkTertiary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            ForEach(entries) { entry in
                row(entry)
            }
        }
        .liveMetric(.processes)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Süreç").frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: "CPU").frame(width: 64, alignment: .trailing)
            Text("Bellek").frame(width: 84, alignment: .trailing)
            Text("Güç").frame(width: 64, alignment: .trailing)
        }
        .font(.sistemLabel)
        .tracking(0.6)
        .textCase(.uppercase)
        .foregroundStyle(Palette.inkTertiary)
        .padding(.bottom, 6)
    }

    private func row(_ entry: ProcessEntry) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                ProcessIcon(pid: entry.pid)
                Text(verbatim: entry.name)
                    .font(.sistemBody)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if detailed {
                value(cpu(entry), width: 64, strong: ranking == .cpu)
                value(memory(entry), width: 84, strong: ranking == .memory)
                value(entry.milliwatts.map(power) ?? "—", width: 64, strong: false)
            } else {
                value(ranking == .cpu ? cpu(entry) : memory(entry), width: 84, strong: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .help(entry.memoryIsApproximate
              ? Text("Sistem süreci: bellek yerleşik boyuttur (yaklaşık), güç okunamaz.") : Text(verbatim: "PID \(entry.pid)"))
    }

    private func value(_ text: String, width: CGFloat, strong: Bool) -> some View {
        Text(verbatim: text)
            .font(.sistemValue)
            .foregroundStyle(strong ? Palette.ink : Palette.inkSecondary)
            .frame(width: width, alignment: .trailing)
    }

    private func cpu(_ entry: ProcessEntry) -> String {
        Double(entry.cpu).formatted(.percent.precision(.fractionLength(1)))
    }

    private func memory(_ entry: ProcessEntry) -> String {
        (entry.memoryIsApproximate ? "≈ " : "") + Format.bytes(entry.memory)
    }

    private func power(_ milliwatts: Float) -> String {
        milliwatts >= 1000
            ? "\(Format.decimal(Double(milliwatts) / 1000, digits: 1)) W"
            : "\(Format.decimal(Double(milliwatts), digits: 0)) mW"
    }
}

/// App icon for GUI processes, a neutral glyph for everything else. Icons are
/// cached (64 entries, PLAN.md §3-D) so a refreshing list doesn't refetch them.
private struct ProcessIcon: View {
    let pid: pid_t

    var body: some View {
        if let icon = IconCache.shared.icon(for: pid) {
            Image(nsImage: icon).resizable().frame(width: 16, height: 16).accessibilityHidden(true)
        } else {
            Image(systemName: "gearshape")
                .font(.system(size: 11))
                .foregroundStyle(Palette.inkTertiary)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
        }
    }
}

final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSNumber, NSImage>()
    /// Remembers pids without an app icon, so they aren't looked up every tick.
    private var misses = Set<pid_t>()

    private init() { cache.countLimit = 64 }

    func icon(for pid: pid_t) -> NSImage? {
        if let icon = cache.object(forKey: NSNumber(value: pid)) { return icon }
        if misses.contains(pid) { return nil }
        guard let app = NSRunningApplication(processIdentifier: pid), app.bundleURL != nil, let icon = app.icon else {
            if misses.count > 2048 { misses.removeAll() }
            misses.insert(pid)
            return nil
        }
        cache.setObject(icon, forKey: NSNumber(value: pid))
        return icon
    }
}
