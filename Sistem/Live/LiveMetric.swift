import SwiftUI
import SystemKit

extension View {
    /// Declares that this view shows `metric`, for as long as it is on screen.
    func liveMetric(_ metric: Metric) -> some View {
        modifier(LiveMetricModifier(metric: metric))
    }
}

private struct LiveMetricModifier: ViewModifier {
    let metric: Metric
    @Environment(LiveFeed.self) private var feed

    func body(content: Content) -> some View {
        content
            .onAppear { feed.need(metric) }
            .onDisappear { feed.unneed(metric) }
    }
}
