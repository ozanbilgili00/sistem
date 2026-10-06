import Observation
import SystemKit

/// The heartbeat of one on-screen surface — the main window or a popover.
///
/// Metric history lives in the non-observable ``MetricStore``; views read it
/// directly and depend only on `frame`, which bumps once per delivered tick and
/// only while the surface is actually visible. While hidden (occluded window,
/// closed popover) the feed neither redraws nor holds demand, so the metrics it
/// asked for stop being read unless something else needs them (PLAN.md §3-C).
@Observable
final class LiveFeed {
    @ObservationIgnored let store: MetricStore
    /// nil for offscreen snapshots, which render fixed data.
    @ObservationIgnored let engine: SamplingEngine?

    private(set) var frame = 0

    @ObservationIgnored private var needs: [Metric: Int] = [:]
    @ObservationIgnored private var token: ObservationToken?

    init(store: MetricStore, engine: SamplingEngine?) {
        self.store = store
        self.engine = engine
    }

    convenience init(engine: SamplingEngine) {
        self.init(store: engine.store, engine: engine)
    }

    @ObservationIgnored var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            if isActive {
                engine?.demand.retain(Set(needs.keys))
                token = store.observe { [weak self] in self?.frame &+= 1 }
                frame &+= 1  // catch up on what was missed while hidden
            } else {
                token = nil
                engine?.demand.release(Set(needs.keys))
            }
        }
    }

    func need(_ metric: Metric) {
        needs[metric, default: 0] += 1
        if needs[metric] == 1, isActive { engine?.demand.retain(metric) }
    }

    func unneed(_ metric: Metric) {
        guard let count = needs[metric] else { return }
        if count == 1 {
            needs[metric] = nil
            if isActive { engine?.demand.release(metric) }
        } else {
            needs[metric] = count - 1
        }
    }
}
