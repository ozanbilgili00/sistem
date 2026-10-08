import Testing
@testable import SystemKit

@Test func ratesUseTwoSignificantDigitsInDecimalUnits() {
    func shown(_ rate: Double) -> String {
        let (value, digits, unit) = RateScale.displayed(rate)
        return "\(digits == 1 ? String(format: "%.1f", value) : String(Int(value))) \(unit)"
    }
    #expect(shown(0) == "0 B")
    #expect(shown(512) == "512 B")
    #expect(shown(1_234) == "1.2 KB")
    #expect(shown(12_345) == "12 KB")
    #expect(shown(987_654) == "988 KB")
    #expect(shown(1_234_567) == "1.2 MB")
    #expect(shown(150_000_000) == "150 MB")
    #expect(shown(2_300_000_000) == "2.3 GB")
    // Rounding up to 1000 moves to the next unit instead of printing "1000 KB".
    #expect(shown(999_700) == "1.0 MB")
    #expect(shown(-5) == "0 B")
}

@Test func equalKeysMeanEqualText() {
    #expect(RateScale.displayKey(12_300) == RateScale.displayKey(12_400))
    #expect(RateScale.displayKey(12_300) != RateScale.displayKey(13_300))
    #expect(RateScale.displayKey(999_000) != RateScale.displayKey(1_000_000))
}

@Test func hysteresisHoldsSmallChangesAndLetsJumpsThrough() {
    var filter = RateHysteresis()
    // First value shows at once.
    #expect(filter.filter(50_000, 5_000).0 == 50_000)
    // 50 KB/s → 52 KB/s: text differs but under 10 %: held.
    #expect(filter.filter(52_000, 5_000).0 == 50_000)
    // A real 40 % change inside the minimum of two ticks is held back too…
    var quick = RateHysteresis()
    _ = quick.filter(50_000, 5_000)
    #expect(quick.filter(70_000, 5_000).0 == 50_000)
    // …and shown on the next tick.
    #expect(quick.filter(70_000, 5_000).0 == 70_000)
    // Idle → busy is an order-of-magnitude jump: immediate.
    var jumpy = RateHysteresis()
    _ = jumpy.filter(300, 0)
    #expect(jumpy.filter(40_000_000, 0).0 == 40_000_000)
    // Busy → idle too.
    #expect(jumpy.filter(200, 0).0 == 200)
}

@Test func steadyTrafficNeverRedraws() {
    var filter = RateHysteresis()
    var changes = 0
    var last: (Double, Double)?
    // ±4 % wobble around 3 MB/s and 200 KB/s for two simulated minutes.
    for tick in 0..<60 {
        let wobble = 1 + 0.04 * (tick % 2 == 0 ? 1 : -1)
        let shown = filter.filter(3_000_000 * wobble, 200_000 * wobble)
        if let last, last != shown { changes += 1 }
        last = shown
    }
    #expect(changes == 0)
}

@Test func burstyTrafficRedrawsAtMostEveryOtherTick() {
    var filter = RateHysteresis()
    var changes = 0
    var last: (Double, Double)?
    // Alternating 1 MB/s and 3 MB/s: every tick is a visible change, but at most one in two shows.
    for tick in 0..<60 {
        let shown = filter.filter(tick % 2 == 0 ? 1_000_000 : 3_000_000, 0)
        if let last, last != shown { changes += 1 }
        last = shown
    }
    #expect(changes <= 30)
}
