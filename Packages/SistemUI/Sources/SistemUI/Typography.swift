import SwiftUI

public enum Metrics {
    public static let cardRadius: CGFloat = 10
    public static let controlRadius: CGFloat = 7
    public static let pagePadding: CGFloat = 24
    public static let sidebarWidth: CGFloat = 208
}

public extension Font {
    static let sistemPageTitle = Font.system(size: 22, weight: .bold)
    static let sistemHeading = Font.system(size: 15, weight: .semibold)
    static let sistemBody = Font.system(size: 13)
    static let sistemCaption = Font.system(size: 11.5)
    /// Small uppercase instrument-style labels. Pair with `.tracking(1.1)`.
    static let sistemLabel = Font.system(size: 10.5, weight: .semibold, design: .monospaced)
    /// Readouts: tabular figures so digits don't shift as values change.
    static let sistemValue = Font.system(size: 13, weight: .medium, design: .monospaced)
    static let sistemBigValue = Font.system(size: 24, weight: .bold, design: .monospaced)
}
