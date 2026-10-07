import Testing
@testable import SystemKit

/// Footprint is per process and Swift Testing runs tests in parallel, so a neighbour
/// allocating (threads, IOReport samples) can inflate one window. A real per-read leak
/// grows every window; a neighbour's burst doesn't, so one clean window out of three
/// is a pass.
func footprintStaysFlat(margin: UInt64, _ body: () -> Void) throws -> Bool {
    var growth: Int64 = 0
    for _ in 0..<3 {
        let before = try #require(ProcessUsage.current()).physFootprint
        body()
        let after = try #require(ProcessUsage.current()).physFootprint
        growth = Int64(after) - Int64(before)
        if growth < Int64(margin) { return true }
    }
    Issue.record("footprint grew \(growth) bytes in each of three windows")
    return false
}
