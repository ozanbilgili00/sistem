/// The resource ceilings from PLAN.md §3. The Diagnostics page and `perfcheck`
/// both compare against these, so a budget change lands in one place.
public enum EnergyBudget {
    /// Idle: windows closed, three or four menu bar widgets, 2 s interval.
    public static let idleCPUPercent = 0.3
    public static let idleWakeupsPerSecond = 2.0
    public static let idleFootprintMB = 35.0

    /// Main window in front with live graphs.
    public static let windowCPUPercent = 4.0
    public static let windowFootprintMB = 80.0
}
