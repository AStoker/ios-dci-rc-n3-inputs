/// DUML requests the probe can send to the remote.
///
/// Byte-exact reference, from the RC-N1 tools' source (`send_duml(s, 0x0a, 0x06, 0x40, 0x06, 0x01)`
/// and the hard-coded write in pverhaert/DJI_RCN1_for_drone_simulators `dji.py`):
///
///     55 0d 04 33 0a 06 eb 34 40 06 01 74 24   ← 06/01 from PC (0x0a) to RC (0x06), seq 0x34eb
public enum DUMLCommands {
    /// 00/01 Version Inquiry. Per the o-gs dissector every DJI module answers this, with an ASCII
    /// hardware version in the response. A good "is anyone listening?" ping.
    public static func versionInquiry(sender: UInt8, receiver: UInt8 = DUMLDevice.remoteControl, sequence: UInt16) -> DUMLFrame {
        DUMLFrame(sender: sender, receiver: receiver, sequence: sequence, commandSet: 0x00, commandID: 0x01)
    }

    /// 06/24 "RC Simulate Flight Mode Set", payload `01`. The RC-N1 tools send this once before
    /// polling: "without this stick positions are sent very slow by RC".
    public static func rcSimulatorMode(_ enabled: Bool, sender: UInt8, sequence: UInt16) -> DUMLFrame {
        DUMLFrame(sender: sender, receiver: DUMLDevice.remoteControl, sequence: sequence,
                  commandSet: 0x06, commandID: 0x24, payload: [enabled ? 0x01 : 0x00])
    }

    /// 06/01 "RC Channel Params Get", the stick poll used by every RC-N1 tool.
    public static func rcChannelParamsGet(sender: UInt8, sequence: UInt16) -> DUMLFrame {
        DUMLFrame(sender: sender, receiver: DUMLDevice.remoteControl, sequence: sequence,
                  commandSet: 0x06, commandID: 0x01)
    }

    /// 06/05 "RC Parameter Get/Push". Older remotes push sticks and buttons with this id. Sending it
    /// as a request is a guess.
    public static func rcParameterGet(sender: UInt8, sequence: UInt16) -> DUMLFrame {
        DUMLFrame(sender: sender, receiver: DUMLDevice.remoteControl, sequence: sequence,
                  commandSet: 0x06, commandID: 0x05)
    }
}

/// Wrapping sequence-number source.
public struct DUMLSequence: Sendable {
    private var value: UInt16

    /// Starts at 0x34eb, the value the RC-N1 tools use.
    public init(start: UInt16 = 0x34EB) { value = start }

    public mutating func next() -> UInt16 {
        defer { value &+= 1 }
        return value
    }
}
