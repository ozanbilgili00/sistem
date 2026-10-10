import Foundation

/// The smart triggers: each keeps the Mac awake while its condition holds. All off by default.
public enum AwakeTrigger: String, CaseIterable, Codable, Sendable, Identifiable {
    case aiTools, build, network, charging

    public var id: String { rawValue }

    /// Process names (the kernel's `proc_name`, case-sensitive) that satisfy a process trigger.
    public var processNames: Set<String> {
        switch self {
        case .aiTools: ["claude", "codex", "cursor-agent", "ollama"]
        case .build: ["xcodebuild", "swift-build", "docker"]
        case .network, .charging: []
        }
    }

    public var isProcessBased: Bool { !processNames.isEmpty }

    /// Seconds the Mac stays awake after the condition ended.
    public var grace: TimeInterval { self == .charging ? 0 : 120 }

    /// Choices for the download/upload threshold, bytes per second.
    public static let networkThresholdChoices: [Double] = [1_000_000, 5_000_000, 10_000_000, 25_000_000]
    public static let defaultNetworkThreshold: Double = 5_000_000
}

/// How long a manual session lasts. nil = until stopped.
public enum AwakeDuration {
    public static let choices: [TimeInterval?] = [1_800, 3_600, 10_800, 28_800, nil]
}

/// Why the protection let go of the Mac (or refuses to hold it).
public enum ProtectionReason: String, Sendable, Equatable, CaseIterable {
    case battery, thermalState, temperature
}

/// Settings the controller needs; everything off by default.
public struct KeepAwakeConfig: Sendable, Equatable {
    public var enabled = false
    /// Also prevent the display from sleeping. Off = "display may turn off, system stays on".
    public var keepDisplayOn = false
    public var triggers: Set<AwakeTrigger> = []
    public var networkThreshold = AwakeTrigger.defaultNetworkThreshold

    public init(enabled: Bool = false, keepDisplayOn: Bool = false, triggers: Set<AwakeTrigger> = [],
                networkThreshold: Double = AwakeTrigger.defaultNetworkThreshold) {
        self.enabled = enabled
        self.keepDisplayOn = keepDisplayOn
        self.triggers = triggers
        self.networkThreshold = networkThreshold
    }
}

/// What the controller is doing, for the menu bar item, popover and page.
public struct KeepAwakeState: Sendable, Equatable {
    /// An assertion is held right now.
    public var isHolding = false
    public var holdsDisplay = false
    public var manualActive = false
    /// nil while `manualActive` = indefinite.
    public var manualEndsAt: Date?
    /// Triggers keeping the Mac awake now (including their grace period).
    public var holdingTriggers: Set<AwakeTrigger> = []
    /// Triggers whose condition is true right now (not only in grace).
    public var presentTriggers: Set<AwakeTrigger> = []
    /// Protection is refusing or has ended a hold.
    public var blocked: ProtectionReason?

    public init() {}
}

public enum KeepAwakeEvent: Sendable, Equatable {
    case protectionTripped(ProtectionReason)
    case protectionCleared
}
