import AppKit
import SwiftUI

/// Design tokens from PLAN.md §6: soft black and off-white grounds, one blue accent,
/// no gradients, no pure black or pure white anywhere.
///
/// Every token resolves per appearance at draw time, so the AppKit menu bar and the
/// SwiftUI window share one source of truth.
public enum Palette {
    public static let background = Color(nsColor: NSPalette.background)
    public static let surface = Color(nsColor: NSPalette.surface)
    public static let surface2 = Color(nsColor: NSPalette.surface2)
    public static let line = Color(nsColor: NSPalette.line)

    public static let ink = Color(nsColor: NSPalette.ink)
    public static let inkSecondary = Color(nsColor: NSPalette.inkSecondary)
    public static let inkTertiary = Color(nsColor: NSPalette.inkTertiary)

    public static let accent = Color(nsColor: NSPalette.accent)
    public static let accentSoft = Color(nsColor: NSPalette.accentSoft)
    public static let onAccent = Color(nsColor: NSPalette.onAccent)

    public static let good = Color(nsColor: NSPalette.good)
    public static let warning = Color(nsColor: NSPalette.warning)
    public static let critical = Color(nsColor: NSPalette.critical)
}

/// The same tokens as `NSColor`, for AppKit drawing (menu bar widgets, window chrome).
public enum NSPalette {
    public static var background: NSColor { .sistem(light: 0xF6F5F2, dark: 0x141416) }
    public static var surface: NSColor { .sistem(light: 0xFCFBF9, dark: 0x1C1C1F) }
    public static var surface2: NSColor { .sistem(light: 0xEFEEEA, dark: 0x242428) }
    public static var line: NSColor { .sistem(light: 0xE2E0DB, dark: 0x2E2E33) }

    public static var ink: NSColor { .sistem(light: 0x1B1B1E, dark: 0xECECEE) }
    public static var inkSecondary: NSColor { .sistem(light: 0x6C6C73, dark: 0x9C9CA4) }
    public static var inkTertiary: NSColor { .sistem(light: 0x93939A, dark: 0x6E6E76) }

    public static var accent: NSColor { .sistem(light: 0x2F6FD3, dark: 0x5E9BF2) }
    public static var accentSoft: NSColor { .sistem(light: 0x2F6FD3, lightAlpha: 0.12, dark: 0x5E9BF2, darkAlpha: 0.16) }
    /// Text on an accent fill: off-white on the light theme's deep blue, soft black on
    /// the dark theme's lighter blue — white on #5E9BF2 would fail contrast.
    public static var onAccent: NSColor { .sistem(light: 0xFCFBF9, dark: 0x141416) }

    public static var good: NSColor { .sistem(light: 0x2F8F57, dark: 0x5DBB82) }
    public static var warning: NSColor { .sistem(light: 0xB07C14, dark: 0xE0B04E) }
    public static var critical: NSColor { .sistem(light: 0xC0473A, dark: 0xE2685A) }
}

extension NSColor {
    static func sistem(light: UInt32, lightAlpha: CGFloat = 1, dark: UInt32, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? NSColor(hex: dark, alpha: darkAlpha) : NSColor(hex: light, alpha: lightAlpha)
        }
    }

    convenience init(hex: UInt32, alpha: CGFloat) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
