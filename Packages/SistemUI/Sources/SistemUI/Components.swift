import SwiftUI

/// Flat surface with a hairline border. No shadow, no rotation, no gradient.
public struct Card<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    public init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: .rect(cornerRadius: Metrics.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Palette.line, lineWidth: 1))
    }
}

public struct SectionLabel: View {
    private let text: LocalizedStringKey
    public init(_ text: LocalizedStringKey) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.sistemLabel)
            .tracking(1.1)
            .textCase(.uppercase)
            .foregroundStyle(Palette.inkTertiary)
    }
}

public struct PageHeader: View {
    private let title: Text
    private let subtitle: Text?

    public init(_ title: Text, subtitle: Text? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            title.font(.sistemPageTitle).foregroundStyle(Palette.ink)
            if let subtitle {
                subtitle.font(.sistemBody).foregroundStyle(Palette.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One settings row: title (+ optional detail) on the left, control on the right.
public struct SettingRow<Control: View>: View {
    private let title: Text
    private let detail: Text?
    private let control: Control

    public init(_ title: Text, detail: Text? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    public init(_ title: LocalizedStringKey, detail: LocalizedStringKey? = nil, @ViewBuilder control: () -> Control) {
        self.init(Text(title), detail: detail.map { Text($0) }, control: control)
    }

    public var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                title.font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
                if let detail {
                    detail.font(.sistemCaption).foregroundStyle(Palette.inkSecondary)
                }
            }
            Spacer(minLength: 0)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

/// Hairline between rows inside a card.
public struct RowDivider: View {
    public init() {}
    public var body: some View {
        Rectangle().fill(Palette.line).frame(height: 1).padding(.leading, 16)
    }
}

/// Status chip. Semantic color only — never the accent.
public struct Pill: View {
    public enum Tone { case good, warning, critical, neutral, accent }

    private let text: Text
    private let tone: Tone

    public init(_ text: Text, tone: Tone) {
        self.text = text
        self.tone = tone
    }

    public var body: some View {
        text
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.13), in: .rect(cornerRadius: 5))
    }

    private var color: Color {
        switch tone {
        case .good: Palette.good
        case .warning: Palette.warning
        case .critical: Palette.critical
        case .neutral: Palette.inkSecondary
        case .accent: Palette.accent
        }
    }
}

public struct AccentButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Palette.accent.opacity(configuration.isPressed ? 0.8 : 1), in: .rect(cornerRadius: Metrics.controlRadius))
    }
}

public struct QuietButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Palette.surface2.opacity(configuration.isPressed ? 0.7 : 1), in: .rect(cornerRadius: Metrics.controlRadius))
    }
}
