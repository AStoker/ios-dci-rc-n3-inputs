/// DUML checksums.
///
/// Ported from the table-driven routines in the RC-N1 tools (IvanYaky/DJI_RC-N1_SIMULATOR_FLY_DCL
/// `main.py`: `calc_pkt55_hdr_checksum` and `calc_checksum`). The tables here are generated from the
/// polynomials instead of pasted; tests check them against packets published by those tools and by
/// samuelsadok/dji_protocol.
public enum DUMLCRC {
    /// Seed for the header CRC8 over bytes 0...2.
    public static let headerSeed: UInt8 = 0x77
    /// Seed for the frame CRC16. The RC-N1 tools label it "P3/P4/Mavic".
    public static let frameSeed: UInt16 = 0x3692

    /// Reflected CRC-8, polynomial 0x31 (reversed 0x8C), the Dallas/Maxim table.
    public static func crc8<S: Sequence>(_ bytes: S, seed: UInt8 = headerSeed) -> UInt8 where S.Element == UInt8 {
        var crc = seed
        for byte in bytes { crc = table8[Int(crc ^ byte)] }
        return crc
    }

    /// Reflected CRC-16, polynomial 0x1021 (reversed 0x8408), the CCITT/Kermit table.
    public static func crc16<S: Sequence>(_ bytes: S, seed: UInt16 = frameSeed) -> UInt16 where S.Element == UInt8 {
        var crc = seed
        for byte in bytes { crc = (crc >> 8) ^ table16[Int((crc ^ UInt16(byte)) & 0xFF)] }
        return crc
    }

    private static let table8: [UInt8] = (0..<256).map { index in
        var c = UInt8(index)
        for _ in 0..<8 { c = c & 1 != 0 ? (c >> 1) ^ 0x8C : c >> 1 }
        return c
    }

    private static let table16: [UInt16] = (0..<256).map { index in
        var c = UInt16(index)
        for _ in 0..<8 { c = c & 1 != 0 ? (c >> 1) ^ 0x8408 : c >> 1 }
        return c
    }
}
