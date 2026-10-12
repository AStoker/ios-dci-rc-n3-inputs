/// Finds DUML frames and `55 CC` envelopes in an arbitrarily chunked byte stream.
///
/// A stream (unlike a WebSocket) has no message boundaries: one read can hold half a frame or
/// three frames. The scanner buffers bytes and emits complete items, resyncing on anything that
/// doesn't validate. It accepts both bare DUML and DUML inside envelopes, because we don't yet know
/// which one the RC-N3 sends.
public struct DUMLStreamScanner: Sendable {
    public enum Item: Sendable, Equatable {
        /// A DUML frame with valid CRCs. `envelopePort` is set when it arrived inside a `55 CC` envelope.
        case duml(DUMLFrame, raw: [UInt8], envelopePort: UInt16?)
        /// An envelope whose payload isn't DUML (e.g. video). Only the first bytes are kept.
        case envelope(port: UInt16, length: Int, head: [UInt8])
        /// Bytes that matched neither format.
        case skipped(Int)
    }

    private var buffer: [UInt8] = []
    private var start = 0

    public init() {}

    /// Bytes waiting for the rest of a frame.
    public var pendingByteCount: Int { buffer.count - start }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        start = 0
    }

    public mutating func append<C: Collection>(_ bytes: C) -> [Item] where C.Element == UInt8 {
        buffer.append(contentsOf: bytes)
        var items: [Item] = []
        var skipped = 0
        func flushSkipped() {
            if skipped > 0 { items.append(.skipped(skipped)); skipped = 0 }
        }

        scan: while start < buffer.count {
            if buffer[start] != DUMLFrame.magic {
                if let next = buffer[start...].firstIndex(of: DUMLFrame.magic) {
                    skipped += next - start
                    start = next
                } else {
                    skipped += buffer.count - start
                    start = buffer.count
                    break scan
                }
            }

            switch classify(at: start) {
            case .needMoreData:
                break scan
            case .notAFrame:
                skipped += 1
                start += 1
            case let .duml(frame, length):
                flushSkipped()
                items.append(.duml(frame, raw: Array(buffer[start..<start + length]), envelopePort: nil))
                start += length
            case let .envelope(port, length):
                flushSkipped()
                let payload = buffer[(start + LogicLink.headerLength)..<(start + LogicLink.headerLength + length)]
                let inner = Self.dumlFrames(in: payload)
                if inner.isEmpty {
                    items.append(.envelope(port: port, length: length, head: Array(payload.prefix(16))))
                } else {
                    for (frame, raw) in inner { items.append(.duml(frame, raw: raw, envelopePort: port)) }
                }
                start += LogicLink.headerLength + length
            }
        }

        flushSkipped()
        compact()
        return items
    }

    private enum Classification {
        case needMoreData
        case notAFrame
        case duml(DUMLFrame, length: Int)
        case envelope(port: UInt16, length: Int)
    }

    private func classify(at i: Int) -> Classification {
        let available = buffer.count - i
        guard available >= 2 else { return .needMoreData }

        // Check for an envelope first. A DUML frame whose second byte is 0xCC would be 204+ bytes
        // long and need a zero sequence number to look like this, which is rare.
        if buffer[i + 1] == LogicLink.magic1 {
            guard available >= LogicLink.headerLength else { return .needMoreData }
            if buffer[i + 6] == 0, buffer[i + 7] == 0 {
                let length = Int(buffer[i + 4]) | Int(buffer[i + 5]) << 8
                guard available >= LogicLink.headerLength + length else { return .needMoreData }
                let port = UInt16(buffer[i + 2]) | UInt16(buffer[i + 3]) << 8
                return .envelope(port: port, length: length)
            }
        }

        guard available >= 4 else { return .needMoreData }
        guard DUMLCRC.crc8(buffer[i..<i + 3]) == buffer[i + 3] else { return .notAFrame }
        let length = DUMLFrame.declaredLength(buffer[i + 1], buffer[i + 2])
        guard length >= DUMLFrame.minimumLength else { return .notAFrame }
        guard available >= length else { return .needMoreData }
        guard let frame = try? DUMLFrame.decode(buffer[i..<i + length]) else { return .notAFrame }
        return .duml(frame, length: length)
    }

    /// Back-to-back DUML frames at the start of an envelope payload.
    static func dumlFrames(in payload: ArraySlice<UInt8>) -> [(DUMLFrame, [UInt8])] {
        var result: [(DUMLFrame, [UInt8])] = []
        var i = payload.startIndex
        while payload.endIndex - i >= DUMLFrame.minimumLength, payload[i] == DUMLFrame.magic {
            let length = DUMLFrame.declaredLength(payload[i + 1], payload[i + 2])
            guard length >= DUMLFrame.minimumLength, i + length <= payload.endIndex,
                  let frame = try? DUMLFrame.decode(payload[i..<i + length])
            else { break }
            result.append((frame, Array(payload[i..<i + length])))
            i += length
        }
        return result
    }

    private mutating func compact() {
        if start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
        } else if start > 64 * 1024 {
            buffer.removeFirst(start)
            start = 0
        }
    }
}
