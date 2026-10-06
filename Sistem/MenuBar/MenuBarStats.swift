/// Counts status item redraws for the diagnostics page. Each one costs ~6 ms
/// and ~4 wakeups on a three-display Mac (macOS re-renders the item per menu
/// bar), so this number explains most of the app's idle cost.
enum MenuBarStats {
    static var redraws = 0
}
