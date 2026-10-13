import Foundation

/// Decoders for the remote's stick/button DUML payloads.
///
/// Every layout here comes from tools for *other* DJI remotes. None of it is confirmed on an RC-N3
/// yet (HYPOTHESIS). The probe shows the raw bytes next to every decoded value for that reason.

/// Raw stick range used by the RC-N1 tools: min 364, centre 1024, max 1684 (±660).
public enum RCStickRange {
    public static let minimum: UInt16 = 364
    public static let center: UInt16 = 1024
    public static let maximum: UInt16 = 1684

    /// Maps raw → -1...1 using the RC-N1 range. Clamped.
    public static func normalized(_ raw: UInt16) -> Double {
        let value = (Double(raw) - Double(center)) / Double(maximum - center)
        return min(1, max(-1, value))
    }
}

/// Response to 06/01 "RC Channel Params Get".
///
/// RC-N1 tools treat a 38-byte frame as a stick report and read little-endian `UInt16`s at frame
/// offsets 13, 16, 19, 22 and 25, which is a 3-byte stride. The 25-byte payload decodes as:
///
///     payload[0]          status byte (0 = success in the o-gs dissector's convention)
///     payload[1 + 3k]     one byte per channel (unknown; maybe a channel/mapping id) → `tag`
///     payload[2 + 3k...]  UInt16 LE channel value
///
/// RC-N1 channel order (from the tools): 0 right stick X (roll), 1 right stick Y (pitch),
/// 2 left stick Y (throttle), 3 left stick X (yaw), 4 gimbal dial. Channels 5-7 are unmapped.
public struct RCChannelReport: Sendable, Equatable {
    public struct Channel: Sendable, Equatable {
        public var tag: UInt8
        public var raw: UInt16
        public var normalized: Double { RCStickRange.normalized(raw) }
    }

    public static let rcN1Labels = [
        "Right X (roll)", "Right Y (pitch)", "Left Y (throttle)", "Left X (yaw)", "Gimbal dial",
    ]

    public var status: UInt8
    public var channels: [Channel]

    public init?(payload: [UInt8]) {
        guard payload.count >= 4 else { return nil }
        status = payload[0]
        let count = (payload.count - 1) / 3
        channels = (0..<count).map { k in
            let base = 1 + 3 * k
            return Channel(tag: payload[base], raw: UInt16(payload[base + 1]) | UInt16(payload[base + 2]) << 8)
        }
    }

    public func label(for index: Int) -> String {
        index < Self.rcN1Labels.count ? Self.rcN1Labels[index] : "Channel \(index)"
    }
}

/// 06/05 "RC Parameter Push" layout, per the o-gs dissector (`rc_push_param_dissector`).
///
/// RC-N3 (hardware tests 1-2, 2026-10-12): pushed unprompted, RC→APP, cmd type 0x00, seq 0000,
/// ~9 Hz idle (fewer while 06/01 is polled fast), 13-byte payload. All five analog fields span
/// 364…1684. Bits: buttonsA 0x08 Pause/RTH, 0x30 mode switch (C=2, N=1, S=0); buttonsB 0x40
/// Shutter/Record, 0x01 Photo/Video. The Customizable button isn't reported. The wheel byte stays 0.
public struct RCPushParams: Sendable, Equatable {
    public var aileron: UInt16
    public var elevator: UInt16
    public var throttle: UInt16
    public var rudder: UInt16
    public var gimbal: UInt16
    public var wheelInfo: UInt8
    public var buttonsA: UInt8
    public var buttonsB: UInt8
    public var bandWidth: UInt8?

    public init?(payload: [UInt8]) {
        guard payload.count >= 13 else { return nil }
        func u16(_ i: Int) -> UInt16 { UInt16(payload[i]) | UInt16(payload[i + 1]) << 8 }
        aileron = u16(0)
        elevator = u16(2)
        throttle = u16(4)
        rudder = u16(6)
        gimbal = u16(8)
        wheelInfo = payload[10]
        buttonsA = payload[11]
        buttonsB = payload[12]
        bandWidth = payload.count >= 14 ? payload[13] : nil
    }

    public var wheelClick: Bool { wheelInfo & 0x01 != 0 }
    public var wheelOffset: UInt8 { (wheelInfo & 0x3E) >> 1 }
    public var wheelNegative: Bool { wheelInfo & 0x40 != 0 }
    public var wheelChanged: Bool { wheelInfo & 0x80 != 0 }
    public var goHomePressed: Bool { buttonsA & 0x08 != 0 }
    public var modeSwitch: UInt8 { (buttonsA & 0x30) >> 4 }
    /// RC-N3 mapping, confirmed in hardware test 2.
    public var flightMode: RCFlightMode { RCFlightMode(raw: modeSwitch) }
    public var footStool: UInt8 { (buttonsA & 0xC0) >> 6 }
    public var custom2: Bool { buttonsB & 0x08 != 0 }
    public var custom1: Bool { buttonsB & 0x10 != 0 }
    public var playback: Bool { buttonsB & 0x20 != 0 }
    public var shutter: Bool { buttonsB & 0x40 != 0 }
    public var record: Bool { buttonsB & 0x80 != 0 }
    /// Not in the dissector. RC-N3 Photo/Video button (confirmed in hardware test 2).
    public var photoVideo: Bool { buttonsB & 0x01 != 0 }
}

/// 06/1E "RC Battery Info Push" (RC→APP, ~0.8 Hz on the RC-N3).
///
/// Observed payloads like `a6 09 00 00 5f 00`: LE32 2470, then 95. The RC-N3 battery is 2600 mAh,
/// so the first field looks like remaining mAh and payload[4] like percent. HYPOTHESIS.
public struct RCBatteryInfo: Sendable, Equatable {
    public var remaining: UInt32
    public var percent: UInt8

    public init?(payload: [UInt8]) {
        guard payload.count >= 5 else { return nil }
        remaining = UInt32(payload[0]) | UInt32(payload[1]) << 8 | UInt32(payload[2]) << 16 | UInt32(payload[3]) << 24
        percent = payload[4]
    }
}

/// Response to 00/01 Version Inquiry: payload[2..<18] is an ASCII hardware version (o-gs dissector).
public enum DUMLVersionResponse {
    public static func hardwareVersion(payload: [UInt8]) -> String? {
        guard payload.count >= 18 else { return nil }
        let ascii = payload[2..<18].prefix { $0 != 0 }
        guard !ascii.isEmpty, ascii.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return String(decoding: ascii, as: UTF8.self)
    }

    /// Firmware app version at payload[22..<26] as `AA.BB.CC.DD`.
    public static func firmwareVersion(payload: [UInt8]) -> String? {
        guard payload.count >= 26 else { return nil }
        let v = payload[22..<26]
        return String(format: "%02d.%02d.%02d.%02d", v[v.startIndex + 3], v[v.startIndex + 2], v[v.startIndex + 1], v[v.startIndex])
    }
}
