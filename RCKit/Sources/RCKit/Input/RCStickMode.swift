/// Mode 1/2/3 mapping from physical sticks to flight axes (RC-N3 manual §4.3; Mode 2 is the
/// default).
///
/// The remote's channels are physical as long as it's left on its default Mode 2. Whether changing
/// the stick mode in DJI Fly makes the remote re-map its channels is untested.
public enum RCStickMode: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
    case mode1
    case mode2
    case mode3

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .mode1: "Mode 1"
        case .mode2: "Mode 2"
        case .mode3: "Mode 3"
        }
    }

    /// Flight axes, each -1…1. Positive = up, clockwise, forward, right.
    public struct Axes: Sendable, Equatable {
        public var throttle: Double
        public var yaw: Double
        public var pitch: Double
        public var roll: Double

        public init(throttle: Double, yaw: Double, pitch: Double, roll: Double) {
            self.throttle = throttle
            self.yaw = yaw
            self.pitch = pitch
            self.roll = roll
        }
    }

    public func axes(left: RCStick, right: RCStick) -> Axes {
        switch self {
        // Mode 1: left = pitch/yaw, right = throttle/roll
        case .mode1: Axes(throttle: right.y, yaw: left.x, pitch: left.y, roll: right.x)
        // Mode 2: left = throttle/yaw, right = pitch/roll
        case .mode2: Axes(throttle: left.y, yaw: left.x, pitch: right.y, roll: right.x)
        // Mode 3: left = pitch/roll, right = throttle/yaw
        case .mode3: Axes(throttle: right.y, yaw: right.x, pitch: left.y, roll: left.x)
        }
    }

    public func axes(_ sample: RCInputSample) -> Axes {
        axes(left: sample.leftStick, right: sample.rightStick)
    }
}
