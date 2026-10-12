/// The `55 CC` envelope DJI ground devices use on the iPhone USB link.
///
/// From samuelsadok/dji_protocol `usb_mobile_protocol.md` (sniffed between a DJI device and an
/// iPhone). The name comes from the Goggles N3 interface string `com.dji.logiclink`.
///
/// | offset | size | field |
/// |---|---|---|
/// | 0 | 2 | magic `55 CC` |
/// | 2 | 2 | port number (little-endian) |
/// | 4 | 2 | payload length, excluding this header (little-endian) |
/// | 6 | 2 | always `00 00` in captures |
/// | 8 | n | payload |
///
/// Newer devices (Goggles N3, 2024) wrap traffic in both directions. Older ones (Mavic Pro RC,
/// 2016) wrap only device→phone traffic and accept bare DUML from the phone. The RC-N3 is unknown.
public enum LogicLink {
    public static let magic0: UInt8 = 0x55
    public static let magic1: UInt8 = 0xCC
    public static let headerLength = 8

    /// Port numbers seen in the captures.
    public enum Port {
        /// Phone → device DUML (Goggles N3). Also device → phone DUML on the Mavic Pro RC.
        public static let duml: UInt16 = 22345 // 0x5749, bytes "49 57"
        /// Device → phone H.264 video.
        public static let video: UInt16 = 22346 // 0x574A, bytes "4a 57"
        /// Device → phone DUML (Goggles N3).
        public static let dumlFromDevice: UInt16 = 30000 // 0x7530, bytes "30 75"

        public static func name(_ port: UInt16) -> String {
            switch port {
            case duml: "DUML (22345)"
            case video: "video (22346)"
            case dumlFromDevice: "DUML-in (30000)"
            default: "port \(port)"
            }
        }
    }

    public static func wrap(_ payload: [UInt8], port: UInt16 = Port.duml) -> [UInt8] {
        precondition(payload.count <= Int(UInt16.max), "LogicLink payload too long")
        let header: [UInt8] = [
            magic0, magic1,
            UInt8(port & 0xFF), UInt8(port >> 8),
            UInt8(payload.count & 0xFF), UInt8(payload.count >> 8),
            0x00, 0x00,
        ]
        return header + payload
    }
}

/// How the probe frames DUML it writes to the remote. Which one the RC-N3 wants is unknown.
public enum DUMLOutboundFraming: String, CaseIterable, Sendable, Identifiable {
    /// Bare DUML, as the RC-N1 tools write to the Windows VCOM port.
    case raw
    /// DUML inside a `55 CC` envelope on port 22345, as captured from Goggles N3 ↔ iPhone.
    case logicLink

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .raw: "Raw DUML"
        case .logicLink: "55 CC envelope"
        }
    }

    public func wrap(_ duml: [UInt8]) -> [UInt8] {
        switch self {
        case .raw: duml
        case .logicLink: LogicLink.wrap(duml, port: LogicLink.Port.duml)
        }
    }
}
