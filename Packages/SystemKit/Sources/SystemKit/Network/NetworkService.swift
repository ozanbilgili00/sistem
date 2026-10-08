import Dispatch
import Foundation

/// Connectivity events, the optional public-IP lookup and the optional latency probe.
///
/// Everything here is event-driven or switched off:
/// - the path monitor starts the first time the network is wanted on screen (or an
///   extra is enabled) and then stays: it costs nothing between changes, and keeping
///   it makes the connection history meaningful;
/// - the public address is looked up only when the user enabled it **and** the path
///   changed (plus once when they enable it);
/// - latency runs only while enabled, on screen, plugged in and awake, every 60 s.
/// With default settings it makes no outbound request at all.
@MainActor
public final class NetworkService {
    public let monitor = NetworkPathMonitor()
    private let store: MetricStore
    private let fetchAddress: @Sendable () async -> String?
    private let measureRoundTrip: @Sendable () async -> Double?

    /// Look up the public address when connectivity changes. Off by default.
    public var publicIPEnabled = false { didSet { if publicIPEnabled != oldValue { publicIPSettingChanged() } } }
    /// Measure latency every 60 s. Off by default.
    public var latencyEnabled = false { didSet { if latencyEnabled != oldValue { latencySettingChanged() } } }

    public static let latencyInterval = 60.0

    private struct Conditions: Equatable {
        var demanded = false
        var onBattery = false
        var paused = false
    }

    private var conditions = Conditions()
    private var ipTask: Task<Void, Never>?
    private var latencyTimer: DispatchSourceTimer?
    private var latencyTask: Task<Void, Never>?

    /// The two closures are the only code that talks to the network; tests swap
    /// them to count calls.
    public init(store: MetricStore,
                fetchAddress: @escaping @Sendable () async -> String? = { await PublicIPClient().fetch() },
                measureRoundTrip: @escaping @Sendable () async -> Double? = { await LatencyProbe().measure() }) {
        self.store = store
        self.fetchAddress = fetchAddress
        self.measureRoundTrip = measureRoundTrip
    }

    /// Called by the engine whenever demand, power or pause state changes.
    public func update(demanded: Bool, onBattery: Bool, paused: Bool) {
        let new = Conditions(demanded: demanded, onBattery: onBattery, paused: paused)
        guard new != conditions else { return }
        conditions = new
        if demanded { startMonitor() }
        evaluateLatency()
    }

    private func startMonitor() {
        guard !monitor.isRunning else { return }
        monitor.start { [weak self] state, events in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.pathChanged(state, events) }
            }
        }
    }

    private func pathChanged(_ state: PathState, _ events: [ConnectionEvent]) {
        store.ingest(Snapshot(path: state, connectionEvents: events))
        if publicIPEnabled, state.isConnected { lookUpPublicIP() }
        evaluateLatency()
    }

    // MARK: Public IP

    private func publicIPSettingChanged() {
        if publicIPEnabled {
            startMonitor()  // the first update (the current path) triggers the lookup
            if let state = monitor.state, state.isConnected { lookUpPublicIP() }
        } else {
            ipTask?.cancel()
            ipTask = nil
            store.ingest(Snapshot(publicIP: .off))
        }
    }

    private func lookUpPublicIP() {
        ipTask?.cancel()
        store.ingest(Snapshot(publicIP: .fetching))
        let fetch = fetchAddress
        ipTask = Task { [weak self] in
            // One retry: right after a connectivity change DNS is often not ready yet.
            var address = await fetch()
            if address == nil, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { address = await fetch() }
            }
            guard !Task.isCancelled else { return }
            self?.store.ingest(Snapshot(publicIP: address.map { .address($0, Date()) } ?? .failed))
        }
    }

    // MARK: Latency

    private func latencySettingChanged() {
        if latencyEnabled {
            evaluateLatency()
        } else {
            stopLatency()
            store.ingest(Snapshot(latency: .off))
        }
    }

    private var latencyShouldRun: Bool {
        latencyEnabled && conditions.demanded && !conditions.onBattery && !conditions.paused
            && (monitor.state?.isConnected ?? true)
    }

    private func evaluateLatency() {
        if latencyShouldRun {
            guard latencyTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: .main)
            let interval = DispatchTimeInterval.seconds(Int(Self.latencyInterval))
            timer.schedule(deadline: .now(), repeating: interval, leeway: .seconds(10))
            timer.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.measureLatency() }
            }
            timer.activate()
            latencyTimer = timer
        } else {
            stopLatency()
        }
    }

    private func stopLatency() {
        latencyTimer?.cancel()
        latencyTimer = nil
        latencyTask?.cancel()
        latencyTask = nil
    }

    private func measureLatency() {
        guard latencyTask == nil else { return }
        let measure = measureRoundTrip
        latencyTask = Task { [weak self] in
            let milliseconds = await measure()
            guard let self, !Task.isCancelled else { return }
            latencyTask = nil
            store.ingest(Snapshot(latency: milliseconds.map { .measured(milliseconds: $0, Date()) } ?? .failed(Date())))
        }
    }

    isolated deinit {
        stopLatency()
        ipTask?.cancel()
        monitor.stop()
    }
}
