import Foundation

public typealias DisplayID = UInt32

/// One video mode of a display: what the UI offers in its resolution / refresh picker.
public struct DisplayMode: Sendable, Equatable, Hashable, Identifiable {
    /// `ioDisplayModeID`: unique per display, not across displays.
    public var id: Int32
    /// Size in points (what apps see).
    public var width: Int
    public var height: Int
    /// Size in pixels of the framebuffer behind it.
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Hz; 0 when the mode does not say (some built-in panels).
    public var refreshRate: Double

    public init(id: Int32, width: Int, height: Int, pixelWidth: Int? = nil, pixelHeight: Int? = nil, refreshRate: Double = 0) {
        self.id = id
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth ?? width
        self.pixelHeight = pixelHeight ?? height
        self.refreshRate = refreshRate
    }

    /// 2 on a Retina mode, 1 otherwise.
    public var scale: Double { width > 0 ? Double(pixelWidth) / Double(width) : 1 }
    public var isHiDPI: Bool { pixelWidth > width }
    /// Same picture at the same rate: the picker keeps one of them.
    var visualKey: String { "\(width)x\(height)@\(Int(refreshRate.rounded()))/\(pixelWidth)" }
}

/// What one display is right now. Names and numbers are shown, never logged.
public struct DisplayInfo: Sendable, Equatable, Identifiable {
    public var id: DisplayID
    public var name: String
    public var vendor: UInt32
    public var model: UInt32
    public var isBuiltIn: Bool
    public var isMain: Bool
    public var isMirrored: Bool
    public var mode: DisplayMode?
    /// Degrees: 0, 90, 180, 270.
    public var rotation: Int
    /// `NSScreen` EDR headroom now, and what the panel can reach. Potential above 1 = an HDR-capable display.
    public var edrCurrent: Float
    public var edrPotential: Float
    /// The built-in panel's brightness (0...1); nil on every other display.
    public var brightness: Float?

    public init(id: DisplayID, name: String = "", vendor: UInt32 = 0, model: UInt32 = 0, isBuiltIn: Bool = false, isMain: Bool = false,
                isMirrored: Bool = false, mode: DisplayMode? = nil, rotation: Int = 0, edrCurrent: Float = 1, edrPotential: Float = 1,
                brightness: Float? = nil) {
        self.id = id
        self.name = name
        self.vendor = vendor
        self.model = model
        self.isBuiltIn = isBuiltIn
        self.isMain = isMain
        self.isMirrored = isMirrored
        self.mode = mode
        self.rotation = rotation
        self.edrCurrent = edrCurrent
        self.edrPotential = edrPotential
        self.brightness = brightness
    }

    public var supportsHDR: Bool { edrPotential > 1.05 }
    /// The display is showing HDR headroom right now.
    public var isShowingHDR: Bool { edrCurrent > 1.05 }
}

/// The bits `CGDisplayRegisterReconfigurationCallback` reports; the raw values are CoreGraphics' own.
public struct DisplayChangeFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let beginConfiguration = DisplayChangeFlags(rawValue: 1 << 0)
    public static let moved = DisplayChangeFlags(rawValue: 1 << 1)
    public static let setMain = DisplayChangeFlags(rawValue: 1 << 2)
    public static let setMode = DisplayChangeFlags(rawValue: 1 << 3)
    public static let added = DisplayChangeFlags(rawValue: 1 << 4)
    public static let removed = DisplayChangeFlags(rawValue: 1 << 5)
    public static let enabled = DisplayChangeFlags(rawValue: 1 << 8)
    public static let disabled = DisplayChangeFlags(rawValue: 1 << 9)
    public static let mirrored = DisplayChangeFlags(rawValue: 1 << 10)
    public static let unmirrored = DisplayChangeFlags(rawValue: 1 << 11)
    public static let desktopShapeChanged = DisplayChangeFlags(rawValue: 1 << 12)

    /// The first of the two callbacks of a change only announces it; the second says what happened.
    public var isOnlyAnnouncement: Bool { self == .beginConfiguration }
}

/// How long a mode lasts: a trial dies with the app, a confirmed one lasts for the login session.
public enum ModeScope: Sendable { case appOnly, session }

public enum DisplayEventKind: String, Sendable, Equatable {
    case connected, disconnected, modeChanged, layoutChanged, modeReverted
}

/// A line of the connection log. Held in memory only, never written anywhere.
public struct DisplayEvent: Sendable, Equatable, Identifiable {
    public var id: Int
    public var date: Date
    public var kind: DisplayEventKind
    public var name: String
    /// "2560 × 1440 · 200 Hz" for connections and mode changes.
    public var detail: String

    public init(id: Int, date: Date, kind: DisplayEventKind, name: String, detail: String = "") {
        self.id = id
        self.date = date
        self.kind = kind
        self.name = name
        self.detail = detail
    }
}

/// A mode change waiting for the user's yes. Without it the old mode returns at `deadline`.
public struct PendingModeChange: Sendable, Equatable {
    public var display: DisplayID
    public var from: DisplayMode
    public var to: DisplayMode
    public var deadline: Date

    public init(display: DisplayID, from: DisplayMode, to: DisplayMode, deadline: Date) {
        self.display = display
        self.from = from
        self.to = to
        self.deadline = deadline
    }
}

// MARK: DDC

/// The controls DDC/CI is used for. The raw value is the VCP feature code.
public enum VCPControl: UInt8, CaseIterable, Sendable, Identifiable {
    case brightness = 0x10
    case contrast = 0x12
    case volume = 0x62
    case inputSource = 0x60

    public var id: UInt8 { rawValue }
    public var code: UInt8 { rawValue }
}

public struct VCPValue: Sendable, Equatable {
    public var current: UInt16
    public var maximum: UInt16

    public init(current: UInt16, maximum: UInt16) {
        self.current = current
        self.maximum = maximum
    }

    /// 0...1 for a slider; a monitor that reports no range counts as 0.
    public var fraction: Double { maximum > 0 ? min(1, Double(current) / Double(maximum)) : 0 }
}

public enum DDCUnsupportedReason: String, Sendable, Equatable {
    /// The built-in panel has no DDC; its brightness is the system's.
    case builtIn
    /// No DDC channel could be tied to this display (Sidecar, DisplayLink, some docks and HDMI ports).
    case noChannel
    /// The channel exists but the monitor did not answer.
    case noAnswer
}

public enum DDCStatus: Sendable, Equatable {
    /// Not asked yet: nothing is read until a page or popover is visible.
    case unknown
    case supported
    case unsupported(DDCUnsupportedReason)
}

/// Known values of the input-select control (VCP 0x60), MCCS standard numbering.
public enum DDCInput {
    public static let known: [UInt16] = [0x0F, 0x10, 0x11, 0x12, 0x1B]

    public static func name(_ value: UInt16) -> String {
        switch value {
        case 0x0F: "DisplayPort 1"
        case 0x10: "DisplayPort 2"
        case 0x11: "HDMI 1"
        case 0x12: "HDMI 2"
        case 0x1B: "USB-C"
        default: "#\(value)"
        }
    }
}

/// One display as the controller tracks it.
public struct DisplayEntry: Sendable, Equatable, Identifiable {
    public var info: DisplayInfo
    /// Loaded while the page or popover is visible; empty otherwise.
    public var modes: [DisplayMode] = []
    public var ddc: DDCStatus = .unknown
    public var controls: [VCPControl: VCPValue] = [:]
    /// The last DDC write got no acknowledgement.
    public var ddcWriteFailed = false
    /// Software dimming, 0.1...1 (1 = untouched).
    public var dim: Float = 1
    /// Night tone, 0...1 (0 = untouched).
    public var warmth: Float = 0

    public init(info: DisplayInfo) { self.info = info }

    public var id: DisplayID { info.id }
    public var colorIsAdjusted: Bool { dim < 0.999 || warmth > 0.001 }
}

public struct DisplayState: Sendable, Equatable {
    public var entries: [DisplayEntry] = []
    public var pending: PendingModeChange?
    /// Newest first, at most ``DisplayController/eventLimit``.
    public var events: [DisplayEvent] = []
    /// The last mode change the system refused.
    public var modeChangeFailed = false

    public init() {}
}
