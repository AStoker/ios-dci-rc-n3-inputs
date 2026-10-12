/// One DUML v1 frame, DJI's internal message-bus packet.
///
/// Wire layout (all multi-byte fields little-endian):
///
/// | offset | size | field |
/// |---|---|---|
/// | 0 | 1 | magic `0x55` |
/// | 1 | 2 | bits 0-9: total frame length; bits 10-15: version (1 → byte 2 is `0x04`) |
/// | 3 | 1 | CRC8 of bytes 0...2 |
/// | 4 | 1 | sender (bits 0-4 device type, bits 5-7 index) |
/// | 5 | 1 | receiver (same encoding) |
/// | 6 | 2 | sequence number |
/// | 8 | 1 | command type: bit 7 response, bits 5-6 ack type, bits 0-2 encryption |
/// | 9 | 1 | command set |
/// | 10 | 1 | command id |
/// | 11 | n | payload |
/// | 11+n | 2 | CRC16 of everything before it |
///
/// Sources: `send_duml` in the RC-N1 tools, and the o-gs/dji-firmware-tools Wireshark dissector
/// (`dji-dumlv1-proto.lua`).
public struct DUMLFrame: Sendable, Hashable {
    public static let magic: UInt8 = 0x55
    public static let headerLength = 11
    public static let minimumLength = 13
    public static let maximumLength = 0x3FF

    public var version: UInt8
    public var sender: UInt8
    public var receiver: UInt8
    public var sequence: UInt16
    public var commandType: UInt8
    public var commandSet: UInt8
    public var commandID: UInt8
    public var payload: [UInt8]

    public init(
        sender: UInt8,
        receiver: UInt8,
        sequence: UInt16,
        commandType: UInt8 = DUMLCommandType.requestAckAfterExec,
        commandSet: UInt8,
        commandID: UInt8,
        payload: [UInt8] = [],
        version: UInt8 = 1
    ) {
        self.version = version
        self.sender = sender
        self.receiver = receiver
        self.sequence = sequence
        self.commandType = commandType
        self.commandSet = commandSet
        self.commandID = commandID
        self.payload = payload
    }

    public var isResponse: Bool { commandType & 0x80 != 0 }
    public var ackType: UInt8 { (commandType >> 5) & 0x03 }
    public var encryption: UInt8 { commandType & 0x07 }
    public var length: Int { Self.minimumLength + payload.count }

    /// Short human label, e.g. `06/01 rsp RC→PC`.
    public var label: String {
        "\(Hex.byte(commandSet))/\(Hex.byte(commandID)) \(isResponse ? "rsp" : "req") "
            + "\(DUMLDevice.name(sender))→\(DUMLDevice.name(receiver))"
    }

    /// Serialises the frame, computing both CRCs.
    public func encoded() -> [UInt8] {
        precondition(length <= Self.maximumLength, "DUML frame too long")
        var out: [UInt8] = [Self.magic, UInt8(length & 0xFF), UInt8((length >> 8) & 0x03) | (version << 2)]
        out.reserveCapacity(length)
        out.append(DUMLCRC.crc8(out))
        out += [sender, receiver, UInt8(sequence & 0xFF), UInt8(sequence >> 8), commandType, commandSet, commandID]
        out += payload
        let crc = DUMLCRC.crc16(out)
        out += [UInt8(crc & 0xFF), UInt8(crc >> 8)]
        return out
    }

    public enum DecodeError: Error, Sendable, Equatable {
        case tooShort
        case badMagic
        case badHeaderCRC
        case lengthMismatch(declared: Int, actual: Int)
        case badFrameCRC
    }

    /// Declared total length from header bytes 1 and 2.
    static func declaredLength(_ b1: UInt8, _ b2: UInt8) -> Int {
        Int(b1) | (Int(b2 & 0x03) << 8)
    }

    /// Decodes exactly one complete frame (no trailing bytes).
    public static func decode<C: Collection>(_ bytes: C) throws(DecodeError) -> DUMLFrame
    where C.Element == UInt8, C.Index == Int {
        guard bytes.count >= minimumLength else { throw .tooShort }
        let b = bytes.startIndex
        guard bytes[b] == magic else { throw .badMagic }
        guard DUMLCRC.crc8(bytes[b..<b + 3]) == bytes[b + 3] else { throw .badHeaderCRC }
        let declared = declaredLength(bytes[b + 1], bytes[b + 2])
        guard declared == bytes.count else { throw .lengthMismatch(declared: declared, actual: bytes.count) }
        let crcIndex = b + declared - 2
        let crc = UInt16(bytes[crcIndex]) | UInt16(bytes[crcIndex + 1]) << 8
        guard DUMLCRC.crc16(bytes[b..<crcIndex]) == crc else { throw .badFrameCRC }
        return DUMLFrame(
            sender: bytes[b + 4],
            receiver: bytes[b + 5],
            sequence: UInt16(bytes[b + 6]) | UInt16(bytes[b + 7]) << 8,
            commandType: bytes[b + 8],
            commandSet: bytes[b + 9],
            commandID: bytes[b + 10],
            payload: Array(bytes[(b + headerLength)..<crcIndex]),
            version: bytes[b + 2] >> 2
        )
    }
}

/// Values for `DUMLFrame.commandType`.
public enum DUMLCommandType {
    public static let requestNoAck: UInt8 = 0x00
    public static let requestAckBeforeExec: UInt8 = 0x20
    /// What the RC-N1 tools send (`0x40`).
    public static let requestAckAfterExec: UInt8 = 0x40
}

/// DUML device ids (sender/receiver bits 0-4). Names follow the o-gs dissector.
public enum DUMLDevice {
    public static let app: UInt8 = 0x02
    public static let remoteControl: UInt8 = 0x06
    public static let pc: UInt8 = 0x0A

    private static let names: [UInt8: String] = [
        0: "ANY", 1: "CAM", 2: "APP", 3: "FC", 4: "GIMBAL", 5: "CENTER", 6: "RC", 7: "WIFI-AIR",
        8: "DM36x-AIR", 9: "HDLINK-AIR", 10: "PC", 11: "BATT", 12: "ESC", 13: "DM36x-GND",
        14: "HDLINK-GND", 15: "USB-AIR", 16: "USB-GND", 17: "MONO", 18: "BINO", 19: "FPGA-AIR",
        20: "FPGA-GND", 21: "SIM", 22: "BASE", 23: "COMPUTE", 24: "RC-BATT", 25: "IMU", 26: "GPS",
        27: "WIFI-GND", 28: "SIGCVT", 29: "PMU", 30: "UNK", 31: "LAST",
    ]

    /// `0x06` → `"RC"`, `0x28` → `"DM36x-AIR#1"`.
    public static func name(_ raw: UInt8) -> String {
        let type = raw & 0x1F
        let index = raw >> 5
        let base = names[type] ?? "?\(type)"
        return index == 0 ? base : "\(base)#\(index)"
    }
}

/// Names for the commands this probe knows about. Everything else shows as set/id only.
public enum DUMLCommandNames {
    private static let names: [UInt16: String] = [
        0x0001: "Version Inquiry",
        0x0601: "RC Channel Params Get",
        0x0605: "RC Parameter Get/Push",
        0x0624: "RC Simulate Flight Mode Set",
        0x0625: "RC Simulate Flight Mode Get",
        0x0626: "RC AETR Value Push",
        0x064C: "RC Custom Buttons Status",
        0x0650: "RC Push Key Info",
    ]

    public static func name(set: UInt8, id: UInt8) -> String? {
        names[UInt16(set) << 8 | UInt16(id)]
    }
}
