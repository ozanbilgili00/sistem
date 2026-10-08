import Dispatch

/// Wires demand, power policy and pause state into one ``SamplerConfig`` and
/// hands it to the sampler whenever any input changes. Owned by the app delegate.
@MainActor
public final class SamplingEngine {
    public let store: MetricStore
    public let demand = DemandRegistry()
    public let power = PowerPolicy()
    public let pauses = PauseMonitor()
    /// Connectivity events and the optional public-IP and latency lookups.
    public let network: NetworkService
    private let sampler: SamplerActor

    /// The user's interval in seconds, before the power multiplier.
    public var baseInterval: Double = 2 { didSet { update() } }
    public var slowDownOnBattery = true { didSet { update() } }

    /// What the sampler is currently told to do. For the diagnostics page.
    public private(set) var config = SamplerConfig(interval: 2, metrics: [], paused: true)

    public init(store: MetricStore = MetricStore()) {
        self.store = store
        network = NetworkService(store: store)
        sampler = SamplerActor(pathMonitor: network.monitor) { snapshot in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { store.ingest(snapshot) }
            }
        }
        demand.onChange = { [weak self] in self?.update() }
        power.onChange = { [weak self] in self?.update() }
        pauses.onChange = { [weak self] in self?.update() }
        update(force: true)
    }

    private func update(force: Bool = false) {
        network.update(demanded: demand.active.contains(.network) || demand.active.contains(.networkInfo),
                       onBattery: power.state.onBattery, paused: !pauses.reasons.isEmpty)
        let new = SamplerConfig(
            interval: baseInterval * power.multiplier(slowDownOnBattery: slowDownOnBattery),
            metrics: demand.active,
            paused: !pauses.reasons.isEmpty
        )
        guard force || new != config else { return }
        config = new
        sampler.send(new)
    }
}
