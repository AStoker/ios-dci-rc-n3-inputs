import Foundation

/// Hex formatting and parsing for byte dumps.
public enum Hex {
    private static let digits: [UInt8] = Array("0123456789abcdef".utf8)

    /// Formats bytes as lowercase hex pairs, e.g. `"55 0d 04"`.
    /// - Parameter limit: maximum number of bytes to print; the rest is summarised as `…(+N)`.
    public static func string<C: Collection>(_ bytes: C, separator: String = " ", limit: Int? = nil) -> String
    where C.Element == UInt8 {
        let shown = min(bytes.count, limit ?? Int.max)
        let sep = Array(separator.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(shown * (2 + sep.count) + 12)
        for (i, byte) in bytes.prefix(shown).enumerated() {
            if i > 0 { out += sep }
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        if shown < bytes.count {
            out += Array(" …(+\(bytes.count - shown))".utf8)
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Parses `"55 0d 04"`, `"550d04"` or `"0x55, 0x0d"` into bytes.
    /// Returns nil for an odd number of digits or any character that isn't hex or a separator.
    public static func parse(_ text: String) -> [UInt8]? {
        let cleaned = text.replacingOccurrences(of: "0x", with: "").replacingOccurrences(of: "0X", with: "")
        var nibbles: [UInt8] = []
        for scalar in cleaned.unicodeScalars {
            switch scalar {
            case "0"..."9": nibbles.append(UInt8(scalar.value - 48))
            case "a"..."f": nibbles.append(UInt8(scalar.value - 87))
            case "A"..."F": nibbles.append(UInt8(scalar.value - 55))
            case " ", ",", ":", "-", "\n", "\t", "\r": continue
            default: return nil
            }
        }
        guard nibbles.count.isMultiple(of: 2) else { return nil }
        return stride(from: 0, to: nibbles.count, by: 2).map { nibbles[$0] << 4 | nibbles[$0 + 1] }
    }

    /// `0x06` → `"06"`.
    public static func byte(_ value: UInt8) -> String {
        String(decoding: [digits[Int(value >> 4)], digits[Int(value & 0x0F)]], as: UTF8.self)
    }
}
