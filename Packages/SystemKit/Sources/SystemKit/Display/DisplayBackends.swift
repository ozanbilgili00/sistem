import Foundation

/// Everything the controller needs from the system, behind protocols so the logic is tested
/// without touching a real screen. The live versions are in `LiveDisplay.swift`.

/// The display list, modes and mode switching.
@MainActor
public protocol DisplayBackend: AnyObject {
    func displays() -> [DisplayInfo]
    /// Every mode the display offers, unfiltered.
    func modes(for id: DisplayID) -> [DisplayMode]
    /// false when the system refused. `.appOnly` changes revert by themselves when the process ends.
    func setMode(_ mode: DisplayMode, on id: DisplayID, scope: ModeScope) -> Bool
    /// Calls `handler` for every reconfiguration. Only one handler is kept.
    func startObserving(_ handler: @escaping @MainActor (DisplayChangeFlags) -> Void)
    func stopObserving()
}

/// Software dimming and tone through the display's transfer table.
@MainActor
public protocol GammaBackend: AnyObject {
    func apply(_ table: GammaTable, to id: DisplayID) -> Bool
    /// Puts every display back to the ColorSync settings. The system also does this when the process ends.
    func resetAll()
}

/// Finds the DDC channel of a display, if it has one.
@MainActor
public protocol DDCProvider: AnyObject {
    /// `all` is every display, so a channel is only handed out when exactly one display matches it.
    func transport(for display: DisplayInfo, among all: [DisplayInfo]) -> DDCTransport?
}

/// Runs blocking work (DDC transfers) off the main thread and returns the result to it.
@MainActor
public protocol DisplayWorker: AnyObject {
    func run<T: Sendable>(_ work: @escaping @Sendable () -> T, then: @escaping @MainActor (T) -> Void)
}

/// Time, injectable: the 15 s revert and the write limiter are tested without waiting.
@MainActor
public protocol DisplayClock: AnyObject {
    func now() -> Date
    /// Runs `action` once after `delay`. Returns a closure that cancels it.
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void
}
