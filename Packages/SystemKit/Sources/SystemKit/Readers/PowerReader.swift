import Darwin

/// Power draw in watts over the last sampling interval. Each field is nil when its
/// source is missing on this Mac, so the UI can hide the row instead of showing 0.
public struct PowerSample: Sendable, Equatable {
    /// CPU package, SMC `PPMC`.
    public var cpu: Float?
    /// GPU, IOReport Energy Model `GPU Energy`.
    public var gpu: Float?
    /// Neural Engine, IOReport Energy Model `ANE0`. No utilisation channel exists,
    /// so this is the only ANE signal.
    public var ane: Float?
    /// Whole system, SMC `PSTR`.
    public var system: Float?

    public init(cpu: Float? = nil, gpu: Float? = nil, ane: Float? = nil, system: Float? = nil) {
        self.cpu = cpu
        self.gpu = gpu
        self.ane = ane
        self.system = system
    }
}

/// CPU and system power from the SMC (instantaneous), GPU and ANE power from the
/// IOReport energy counters (nJ delta over wall time).
///
/// The IOReport subscription is made once, for the two channels needed, and the SMC
/// connection once; a read is two SMC keys (~0.2 ms each) plus one delta over two
/// channels. IOReport's CPU energy channels stay at 0 without root, which is why
/// CPU power comes from the SMC (BULGULAR.md, "Güç").
///
/// Not thread-safe: confine to one executor.
public final class PowerReader {
    private let smc: SMC?
    private let subscription: IOReport.Subscription?
    private var previous: IOReport.Sample?

    /// Either source may be absent: `library` is nil when libIOReport can't be
    /// loaded, `smc` when the SMC can't be opened. Both default to the real thing;
    /// tests pass nil to exercise the degraded paths. Pass `subscription` to share
    /// one with a ``CPUFrequencyReader`` (see ``IOReport/performanceSubscription()``).
    public init(library: IOReport? = IOReport.library, smc: SMC? = SMC(),
                subscription: IOReport.Subscription? = nil) {
        self.smc = smc
        self.subscription = subscription ?? library?.performanceSubscription()
    }

    /// True if at least one source is available; a reader that can't read anything
    /// isn't worth keeping.
    public var isAvailable: Bool { smc != nil || subscription != nil }

    /// Forget the energy baseline; the next `sample()` reports GPU and ANE as nil.
    public func reset() {
        previous = nil
    }

    public func sample() -> PowerSample {
        var result = PowerSample(
            cpu: smc?.read("PPMC")?.number.map(Float.init),
            system: smc?.read("PSTR")?.number.map(Float.init)
        )
        guard let subscription, let current = subscription.sample() else { return result }
        defer { previous = current }
        guard let earlier = previous, current.time > earlier.time else { return result }
        let seconds = Double(current.time - earlier.time) / 1e9
        var gpu: Double?
        var ane: Double?
        for reading in subscription.readings(from: earlier, to: current) where reading.channel.group == "Energy Model" {
            guard let value = reading.value,
                  let watts = Self.watts(energy: value, unit: reading.channel.unit, seconds: seconds) else { continue }
            if reading.channel.name == "GPU Energy" {
                gpu = (gpu ?? 0) + watts
            } else {
                ane = (ane ?? 0) + watts  // several ANE channels on bigger chips
            }
        }
        result.gpu = gpu.map(Float.init)
        result.ane = ane.map(Float.init)
        return result
    }

    /// Energy counters come in mixed units (`mJ`, `uJ`, `nJ`) per channel.
    static func watts(energy: Int64, unit: String, seconds: Double) -> Double? {
        guard seconds > 0, energy >= 0 else { return nil }
        let joulesPerUnit: Double
        switch unit {
        case "mJ": joulesPerUnit = 1e-3
        case "uJ": joulesPerUnit = 1e-6
        case "nJ": joulesPerUnit = 1e-9
        default: return nil
        }
        return Double(energy) * joulesPerUnit / seconds
    }
}

extension IOReport {
    /// The channels the performance readers need, in one subscription: GPU and ANE
    /// energy, and the per-core CPU performance states. One subscription because
    /// sampling the CPU and energy groups costs about 4 ms of CPU each time and
    /// merging them doesn't add to it.
    ///
    /// Samples are reused for a quarter second: far below any sampling interval (the
    /// shortest is one second), far above the gap between two readers running back to
    /// back, so both see the same sample in a tick.
    public func performanceSubscription() -> Subscription? {
        let subscription = subscribe(to: [("Energy Model", nil), ("CPU Stats", "CPU Core Performance States")]) { channel in
            channel.group == "CPU Stats" || channel.name == "GPU Energy" || channel.name.hasPrefix("ANE")
        }
        subscription?.reuseWindow = 0.25
        return subscription
    }
}
