import SistemUI
import SwiftUI
import SystemKit

/// Status line: what the Mac is doing and for how long.
struct KeepAwakeStatusSummary: View {
    let state: KeepAwakeState
    let enabled: Bool
    let remaining: TimeInterval?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(state.blocked != nil ? Palette.warning : (state.isHolding ? Palette.accent : Palette.inkTertiary))
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    title.font(.sistemHeading).foregroundStyle(Palette.ink)
                    if state.isHolding { Pill(Text("Açık"), tone: .good) }
                }
                detail.font(.sistemCaption).foregroundStyle(Palette.inkSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var icon: String {
        state.blocked != nil ? "exclamationmark.triangle" : (state.isHolding ? "cup.and.saucer.fill" : "cup.and.saucer")
    }

    private var title: Text {
        if state.blocked != nil { return Text("Koruma devrede") }
        if state.isHolding { return Text("Mac uyanık tutuluyor") }
        return Text(enabled ? "Mac uyuyabilir" : "Uyanık Tut kapalı")
    }

    private var detail: Text {
        if let reason = state.blocked { return Text(KeepAwakeText.protectionLine(reason)) }
        if state.manualActive {
            if let remaining { return Text(verbatim: KeepAwakeText.remaining(remaining)) }
            return Text("Elle başlatıldı, durdurulana kadar sürer.")
        }
        if !state.holdingTriggers.isEmpty {
            let names = AwakeTrigger.allCases.filter(state.holdingTriggers.contains)
            return Text(verbatim: names.map { String(localized: KeepAwakeText.name($0)) }.joined(separator: ", "))
        }
        return enabled ? Text("Süre seçerek başlatın ya da bir tetikleyici açın.") : Text("Modülü Modül sekmesinden açın.")
    }
}

/// Duration buttons and Stop.
struct KeepAwakeControls: View {
    let state: KeepAwakeState
    let enabled: Bool
    let start: (Double) -> Void
    let stop: () -> Void
    var includeSessionLabel = true

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SettingsStore.keepAwakeDurationChoices, id: \.self) { seconds in
                Button { start(seconds) } label: { Text(KeepAwakeText.durationShort(seconds)).lineLimit(1).fixedSize() }
                    .buttonStyle(QuietButtonStyle())
            }
            Spacer(minLength: 0)
            if state.manualActive {
                Button(action: stop) { Text("Durdur").lineLimit(1).fixedSize() }.buttonStyle(AccentButtonStyle())
            }
        }
        .disabled(!enabled || state.blocked != nil)
    }
}

/// Who holds the Mac awake, from `IOPMCopyAssertionsByProcess`.
struct AwakeHolderList: View {
    let sample: AssertionSample?
    var limit: Int?

    var body: some View {
        let rows = (sample?.holders ?? []).prefix(limit ?? .max)
        VStack(alignment: .leading, spacing: 8) {
            if rows.isEmpty {
                Text(sample == nil ? "Okunuyor…" : "Şu an uykuyu engelleyen bir süreç yok.")
                    .font(.sistemBody).foregroundStyle(Palette.inkSecondary)
            }
            ForEach(Array(rows)) { holder in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: holder.preventsDisplaySleep ? "display" : "moon.zzz")
                        .font(.system(size: 12)).foregroundStyle(Palette.inkTertiary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: holder.isSelf ? "Sistem" : holder.processName)
                            .font(.sistemBody).foregroundStyle(Palette.ink).lineLimit(1)
                        if !holder.reason.isEmpty && !holder.isSelf {
                            Text(verbatim: holder.reason).font(.sistemCaption).foregroundStyle(Palette.inkTertiary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    if holder.preventsDisplaySleep { Pill(Text("Ekran"), tone: .neutral) }
                }
            }
            if let limit, (sample?.holders.count ?? 0) > limit {
                Text("+\((sample?.holders.count ?? 0) - limit) daha").font(.sistemCaption).foregroundStyle(Palette.inkTertiary)
            }
        }
    }
}

/// Which triggers are on and whether they are keeping the Mac awake right now.
struct AwakeTriggerSummary: View {
    let state: KeepAwakeState
    let config: KeepAwakeConfig

    var body: some View {
        let enabled = AwakeTrigger.allCases.filter(config.triggers.contains)
        VStack(alignment: .leading, spacing: 8) {
            if enabled.isEmpty {
                Text("Hiçbir tetikleyici açık değil. Modül sekmesinden açabilirsiniz.")
                    .font(.sistemBody).foregroundStyle(Palette.inkSecondary)
            }
            ForEach(enabled) { trigger in
                HStack {
                    Text(KeepAwakeText.name(trigger)).font(.sistemBody).foregroundStyle(Palette.ink)
                    Spacer()
                    if state.presentTriggers.contains(trigger) {
                        Pill(Text("Etkin"), tone: .good)
                    } else if state.holdingTriggers.contains(trigger) {
                        Pill(Text("Bekleme süresi"), tone: .accent)
                    } else {
                        Pill(Text("Bekliyor"), tone: .neutral)
                    }
                }
            }
        }
    }
}
