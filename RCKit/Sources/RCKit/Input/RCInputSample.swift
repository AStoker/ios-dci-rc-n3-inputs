/// One reading of every RC-N3 input. This is the type the simulator consumes.
///
/// Sticks are **physical** (left/right stick, x/y), not flight axes; use `RCStickMode` to get
/// throttle/yaw/pitch/roll. Values are linear in -1…1 with no deadzone or expo; shaping belongs
/// to the consumer. `raw` keeps the exact wire values, so recordings replay bit-for-bit.
public struct RCInputSample: Sendable, Equatable, Codable {
    /// Monotonic seconds (`ProbeClock`) when the bytes arrived.
    public var time: Double
    /// Increases by 1 per sample from a given source.
    public var index: UInt64
    public var leftStick: RCStick
    public var rightStick: RCStick
    /// Gimbal dial, -1…1, springs back to 0.
    public var gimbalDial: Double
    public var flightMode: RCFlightMode
    /// Buttons currently held.
    public var buttons: RCButtons
    public var raw: RCRawInput
    public var source: RCSampleSource

    public init(time: Double, index: UInt64, leftStick: RCStick, rightStick: RCStick, gimbalDial: Double,
                flightMode: RCFlightMode, buttons: RCButtons, raw: RCRawInput, source: RCSampleSource) {
        self.time = time
        self.index = index
        self.leftStick = leftStick
        self.rightStick = rightStick
        self.gimbalDial = gimbalDial
        self.flightMode = flightMode
        self.buttons = buttons
        self.raw = raw
        self.source = source
    }

    /// Builds a sample from wire values, normalising the axes with the RC-N3 range (364…1024…1684).
    public init(time: Double, index: UInt64, raw: RCRawInput, flightMode: RCFlightMode, buttons: RCButtons,
                source: RCSampleSource) {
        self.init(time: time, index: index,
                  leftStick: RCStick(x: RCStickRange.normalized(raw.leftX), y: RCStickRange.normalized(raw.leftY)),
                  rightStick: RCStick(x: RCStickRange.normalized(raw.rightX), y: RCStickRange.normalized(raw.rightY)),
                  gimbalDial: RCStickRange.normalized(raw.gimbal),
                  flightMode: flightMode, buttons: buttons, raw: raw, source: source)
    }
}

/// One physical stick. -1…1, +x right, +y up (away from the pilot).
public struct RCStick: Sendable, Equatable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let centered = RCStick(x: 0, y: 0)
}

/// The RC-N3 buttons that the remote reports.
///
/// Pause/RTH, Shutter/Record and Photo/Video are **held states** (set while pressed). The Fn
/// (Customizable) button reports **gestures** instead: each tap or double-tap sets its member for
/// exactly one status push (~0.15 s), then it clears. A long Fn press, and Fn pressed together with
/// another button, aren't reported. The Power button isn't reported. (Hardware tests 2 and Fn.)
public struct RCButtons: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Flight Pause / Return to Home.
    public static let pauseRTH = RCButtons(rawValue: 1 << 0)
    public static let shutterRecord = RCButtons(rawValue: 1 << 1)
    public static let photoVideo = RCButtons(rawValue: 1 << 2)
    /// Fn single tap: a one-push pulse (06/05 byte 12 bit 0x10, the dissector's "custom1").
    public static let customizableTap = RCButtons(rawValue: 1 << 3)
    /// Fn double tap: a one-push pulse (06/05 byte 12 bit 0x08, the dissector's "custom2").
    public static let customizableDoubleTap = RCButtons(rawValue: 1 << 4)
}

/// The flight mode switch (RC-N3 manual §4.5). `unknown` until the remote's first status push.
public enum RCFlightMode: String, Sendable, Equatable, Codable, CaseIterable {
    case cine = "C"
    case normal = "N"
    case sport = "S"
    case unknown = "?"

    /// From the 2-bit field in 06/05 byte 11 bits 4-5 (C=2, N=1, S=0; hardware test 2).
    public init(raw: UInt8) {
        switch raw {
        case 2: self = .cine
        case 1: self = .normal
        case 0: self = .sport
        default: self = .unknown
        }
    }
}

/// Exact wire values behind a sample.
public struct RCRawInput: Sendable, Equatable, Codable {
    public var leftX: UInt16
    public var leftY: UInt16
    public var rightX: UInt16
    public var rightY: UInt16
    public var gimbal: UInt16
    /// 06/05 byte 11 (mode switch, Pause/RTH) and byte 12 (shutter, photo/video) from the latest push.
    public var flagsA: UInt8
    public var flagsB: UInt8

    public init(leftX: UInt16, leftY: UInt16, rightX: UInt16, rightY: UInt16, gimbal: UInt16, flagsA: UInt8, flagsB: UInt8) {
        self.leftX = leftX
        self.leftY = leftY
        self.rightX = rightX
        self.rightY = rightY
        self.gimbal = gimbal
        self.flagsA = flagsA
        self.flagsB = flagsB
    }
}

/// Where a sample's stick values came from.
public enum RCSampleSource: String, Sendable, Equatable, Codable {
    /// 06/01 reply to our poll (~50-60 new values/s).
    case poll
    /// 06/05 status push (~7-9/s): sticks only when polling is unavailable, otherwise a mode or
    /// button change.
    case push
    /// Played back from a recording.
    case replay
}

/// Connection status of an input source.
public enum RCConnectionState: Sendable, Equatable {
    case stopped
    case waitingForAccessory
    /// Session opening, or data stopped for more than a second.
    case connecting(AccessoryInfo?)
    case streaming(AccessoryInfo)
    case failed(String)
    case replaying(String)

    public var accessory: AccessoryInfo? {
        switch self {
        case let .connecting(info): info
        case let .streaming(info): info
        default: nil
        }
    }

    public var isStreaming: Bool {
        switch self {
        case .streaming, .replaying: true
        default: false
        }
    }

    public var label: String {
        switch self {
        case .stopped: "Stopped"
        case .waitingForAccessory: "Waiting for remote"
        case .connecting: "Connecting…"
        case .streaming: "Streaming"
        case let .failed(reason): "Failed: \(reason)"
        case let .replaying(name): "Replaying \(name)"
        }
    }
}
