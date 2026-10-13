/// Tracks which byte positions change across a series of same-type packets.
///
/// This is the main reverse-engineering tool. Move one control and the positions that light up
/// are that control's bytes. Min/max per position shows the range.
public struct ByteDiffTracker: Sendable, Equatable {
    /// Most recent value at each position (arrays grow to the longest packet seen).
    public private(set) var latest: [UInt8] = []
    /// Length of the most recent packet.
    public private(set) var latestLength = 0
    /// Changes since the last baseline reset.
    public private(set) var changeCounts: [Int] = []
    /// `ProbeClock` time of the last change, or -1 if never changed.
    public private(set) var lastChange: [Double] = []
    public private(set) var minSeen: [UInt8] = []
    public private(set) var maxSeen: [UInt8] = []
    public private(set) var packetCount = 0

    public init() {}

    public mutating func ingest<C: Collection>(_ bytes: C, at time: Double) where C.Element == UInt8 {
        for (i, byte) in bytes.enumerated() {
            if i >= latest.count {
                latest.append(byte)
                changeCounts.append(0)
                lastChange.append(packetCount == 0 ? -1 : time)
                minSeen.append(byte)
                maxSeen.append(byte)
                continue
            }
            if latest[i] != byte {
                changeCounts[i] += 1
                lastChange[i] = time
                latest[i] = byte
            }
            minSeen[i] = min(minSeen[i], byte)
            maxSeen[i] = max(maxSeen[i], byte)
        }
        latestLength = bytes.count
        packetCount += 1
    }

    /// Forgets change history and ranges but keeps the current values as the new baseline.
    public mutating func resetBaseline() {
        changeCounts = Array(repeating: 0, count: latest.count)
        lastChange = Array(repeating: -1, count: latest.count)
        minSeen = latest
        maxSeen = latest
    }

    /// Positions that changed at least once since the baseline.
    public var changedPositions: [Int] {
        changeCounts.indices.filter { changeCounts[$0] > 0 }
    }
}
