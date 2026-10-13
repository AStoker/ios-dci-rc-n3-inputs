import Foundation
import RCKit

/// Everything the probe learns about one byte stream: totals, rates, recent raw chunks, DUML frame
/// types with per-type byte diffs, envelope ports and the latest decoded RC payloads.
///
/// A plain value type. `AccessoryStreamSession` keeps one behind a lock, the I/O thread mutates it,
/// and the UI takes snapshots (copies) at its own pace.
public struct StreamAnalyzer: Sendable {
    public enum Direction: String, Sendable { case incoming = "←", outgoing = "→" }

    public struct Chunk: Sendable, Identifiable {
        public let id: Int
        public let time: Double
        public let direction: Direction
        public let length: Int
        /// First bytes only (`StreamAnalyzer.chunkHeadLength`).
        public let head: [UInt8]
        public let note: String?
    }

    public struct FrameType: Sendable, Identifiable {
        public let id: String
        public var commandSet: UInt8
        public var commandID: UInt8
        public var sender: UInt8
        public var receiver: UInt8
        public var isResponse: Bool
        public var envelopePort: UInt16?
        public var count = 0
        public var firstTime: Double
        public var lastTime: Double
        public var lastRaw: [UInt8] = []
        public var lastPayload: [UInt8] = []
        public var payloadLengths: Set<Int> = []
        /// Diff over the payload only (header bytes such as the sequence number always change).
        public var diff = ByteDiffTracker()
        var meter = RateMeter()
        public var rate: Double = 0

        public var name: String {
            DUMLCommandNames.name(set: commandSet, id: commandID) ?? "unknown"
        }
        public var label: String {
            "\(Hex.byte(commandSet))/\(Hex.byte(commandID)) \(isResponse ? "rsp" : "req") "
                + "\(DUMLDevice.name(sender))→\(DUMLDevice.name(receiver))"
        }
    }

    /// Replies to requests we sent, matched by sequence number (DUML replies echo it).
    public struct ReplyStats: Sendable {
        public var commandSet: UInt8
        public var commandID: UInt8
        public var sent = 0
        public var replies = 0
        public var lastStatus: UInt8?
        public var lastReplyTime: Double?
        public var lastLatency: Double?
        /// Most recent latencies in seconds (up to `latencySampleLimit`).
        public var latencies: [Double] = []
        var meter = RateMeter()
        public var replyRate: Double = 0

        public var label: String { "\(Hex.byte(commandSet))/\(Hex.byte(commandID))" }

        public var averageLatency: Double? {
            latencies.isEmpty ? nil : latencies.reduce(0, +) / Double(latencies.count)
        }

        /// 95th percentile of the recent latencies.
        public var p95Latency: Double? {
            guard !latencies.isEmpty else { return nil }
            let sorted = latencies.sorted()
            return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        }
    }

    public struct PortStats: Sendable, Identifiable {
        public var id: UInt16 { port }
        public let port: UInt16
        public var packets = 0
        public var bytes = 0
        public var lastHead: [UInt8] = []
        public var lastTime: Double = 0
    }

    public static let chunkHeadLength = 64
    public static let recentChunkLimit = 80
    public static let frameTypeLimit = 128
    public static let rawDiffMaxLength = 512
    public static let rawDiffKeyLimit = 32
    public static let latencySampleLimit = 200

    public let name: String

    // Totals
    public private(set) var bytesIn = 0
    public private(set) var chunksIn = 0
    public private(set) var bytesOut = 0
    public private(set) var writesOut = 0
    public private(set) var dumlFramesIn = 0
    public private(set) var skippedBytes = 0
    public private(set) var paddingBytes = 0
    public private(set) var firstInTime: Double?
    public private(set) var lastInTime: Double?
    public private(set) var lastDumlTime: Double?

    // Rates (per second, refreshed by `refreshRates`)
    public private(set) var chunkRate: Double = 0
    public private(set) var byteRate: Double = 0
    public private(set) var dumlRate: Double = 0

    public private(set) var recentChunks: [Chunk] = []
    public private(set) var frameTypes: [String: FrameType] = [:]
    /// Diffs of whole raw chunks keyed by chunk length (only short chunks), for non-DUML data.
    public private(set) var rawDiffs: [Int: ByteDiffTracker] = [:]
    public private(set) var ports: [UInt16: PortStats] = [:]
    /// Keyed by `commandSet << 8 | commandID`.
    public private(set) var replyStats: [UInt16: ReplyStats] = [:]

    public private(set) var latestChannels: (report: RCChannelReport, time: Double)?
    public private(set) var latestPush: (params: RCPushParams, time: Double)?
    public private(set) var latestBattery: (info: RCBatteryInfo, time: Double)?
    /// 06/01 replies whose stick/gimbal values differ from the previous reply, per second.
    /// While a stick is moving fast this approximates the remote's internal update rate.
    public private(set) var freshChannelRate: Double = 0
    /// Recent intervals (seconds) between 06/01 value changes, ignoring pauses over 200 ms.
    public private(set) var channelChangeIntervals: [Double] = []
    private var freshChannelMeter = RateMeter()
    private var lastChannelChange: Double?
    public private(set) var versionInfo: String?

    private var scanner = DUMLStreamScanner()
    private var chunkMeter = RateMeter()
    private var byteMeter = RateMeter()
    private var dumlMeter = RateMeter()
    private var nextChunkID = 0
    /// Requests awaiting a reply: sequence → (command key, send time).
    private var outstanding: [UInt16: (command: UInt16, time: Double)] = [:]

    // Log rate limiting, per one-second window
    private var logWindow = 0
    private var chunkLinesThisWindow = 0
    private var frameLinesThisWindow = 0
    private var outLinesThisWindow = 0
    private var suppressedChunkLines = 0
    private var suppressedFrameLines = 0
    private var suppressedOutLines = 0
    private var lastStatsLog: Double = 0
    public var chunkLogLimitPerSecond = 25
    public var frameLogLimitPerSecond = 120
    public var outgoingLogLimitPerSecond = 25

    public init(name: String) {
        self.name = name
    }

    // MARK: Ingest

    /// Feeds received bytes. Returns the DUML frames completed by this chunk.
    @discardableResult
    public mutating func ingestIncoming(_ bytes: [UInt8], at time: Double, log: ProbeLog?) -> [DUMLFrame] {
        rollLogWindow(at: time, log: log)
        var frames: [DUMLFrame] = []
        bytesIn += bytes.count
        chunksIn += 1
        firstInTime = firstInTime ?? time
        lastInTime = time
        chunkMeter.add(at: time)
        byteMeter.add(Double(bytes.count), at: time)
        appendChunk(.incoming, bytes, at: time, note: nil)

        if chunkLinesThisWindow < chunkLogLimitPerSecond {
            chunkLinesThisWindow += 1
            log?.log(.stream, "\(name) ← [\(bytes.count)] \(Hex.string(bytes, limit: Self.chunkHeadLength))")
        } else {
            suppressedChunkLines += 1
        }

        if bytes.count <= Self.rawDiffMaxLength,
           rawDiffs[bytes.count] != nil || rawDiffs.count < Self.rawDiffKeyLimit {
            rawDiffs[bytes.count, default: ByteDiffTracker()].ingest(bytes, at: time)
        }

        for item in scanner.append(bytes) {
            switch item {
            case let .duml(frame, raw, port):
                ingestFrame(frame, raw: raw, port: port, at: time, log: log)
                frames.append(frame)
            case let .envelope(port, length, head):
                var stats = ports[port] ?? PortStats(port: port)
                stats.packets += 1
                stats.bytes += length
                stats.lastHead = head
                stats.lastTime = time
                ports[port] = stats
            case let .skipped(count):
                skippedBytes += count
            case let .padding(count):
                paddingBytes += count
            }
        }

        if time - lastStatsLog >= 5 {
            lastStatsLog = time
            refreshRates(at: time)
            log?.log(.stats, statsLine())
        }
        return frames
    }

    /// Records bytes we wrote. Pass `frame` for DUML requests so their replies can be matched.
    public mutating func recordOutgoing(_ bytes: [UInt8], at time: Double, note: String, frame: DUMLFrame? = nil, log: ProbeLog?) {
        rollLogWindow(at: time, log: log)
        bytesOut += bytes.count
        writesOut += 1
        appendChunk(.outgoing, bytes, at: time, note: note)
        if let frame, !frame.isResponse {
            let command = UInt16(frame.commandSet) << 8 | UInt16(frame.commandID)
            replyStats[command, default: ReplyStats(commandSet: frame.commandSet, commandID: frame.commandID)].sent += 1
            outstanding[frame.sequence] = (command, time)
            if outstanding.count > 1024 { outstanding = outstanding.filter { time - $0.value.time < 2 } }
        }
        if outLinesThisWindow < outgoingLogLimitPerSecond {
            outLinesThisWindow += 1
            log?.log(.stream, "\(name) → [\(bytes.count)] \(note): \(Hex.string(bytes, limit: Self.chunkHeadLength))")
        } else {
            suppressedOutLines += 1
        }
    }

    private mutating func ingestFrame(_ frame: DUMLFrame, raw: [UInt8], port: UInt16?, at time: Double, log: ProbeLog?) {
        dumlFramesIn += 1
        lastDumlTime = time
        dumlMeter.add(at: time)
        if let port {
            var stats = ports[port] ?? PortStats(port: port)
            stats.packets += 1
            stats.bytes += raw.count
            stats.lastHead = Array(raw.prefix(16))
            stats.lastTime = time
            ports[port] = stats
        }

        let key = "\(Hex.byte(frame.commandSet))/\(Hex.byte(frame.commandID))"
            + "|\(frame.isResponse ? 1 : 0)|\(Hex.byte(frame.sender))|\(Hex.byte(frame.receiver))"
        if frameTypes[key] == nil, frameTypes.count < Self.frameTypeLimit {
            frameTypes[key] = FrameType(
                id: key, commandSet: frame.commandSet, commandID: frame.commandID,
                sender: frame.sender, receiver: frame.receiver, isResponse: frame.isResponse,
                envelopePort: port, firstTime: time, lastTime: time
            )
            log?.log(.duml, "\(name) NEW frame type \(frame.label) "
                + "(\(DUMLCommandNames.name(set: frame.commandSet, id: frame.commandID) ?? "unknown"))"
                + (port.map { " via 55CC port \($0)" } ?? " bare"))
        }
        if var type = frameTypes[key] {
            type.count += 1
            type.lastTime = time
            type.lastRaw = raw
            type.lastPayload = frame.payload
            type.payloadLengths.insert(frame.payload.count)
            type.diff.ingest(frame.payload, at: time)
            type.meter.add(at: time)
            frameTypes[key] = type
        }

        if frame.isResponse, let pending = outstanding[frame.sequence],
           pending.command == UInt16(frame.commandSet) << 8 | UInt16(frame.commandID) {
            outstanding[frame.sequence] = nil
            var stats = replyStats[pending.command] ?? ReplyStats(commandSet: frame.commandSet, commandID: frame.commandID)
            stats.replies += 1
            stats.lastStatus = frame.payload.first
            stats.lastReplyTime = time
            stats.lastLatency = time - pending.time
            stats.latencies.append(time - pending.time)
            if stats.latencies.count > Self.latencySampleLimit { stats.latencies.removeFirst() }
            stats.meter.add(at: time)
            replyStats[pending.command] = stats
        }

        decodeKnown(frame, at: time, log: log)

        if frameLinesThisWindow < frameLogLimitPerSecond {
            frameLinesThisWindow += 1
            log?.log(.duml, "\(name) ← \(frame.label) seq \(String(format: "%04x", frame.sequence)) "
                + "len \(raw.count)\(port.map { " [55CC:\($0)]" } ?? "") payload \(Hex.string(frame.payload, limit: 64))")
        } else {
            suppressedFrameLines += 1
        }
    }

    private mutating func decodeKnown(_ frame: DUMLFrame, at time: Double, log: ProbeLog?) {
        guard frame.isResponse || frame.commandSet == 0x06 else { return }
        switch (frame.commandSet, frame.commandID) {
        case (0x06, 0x01) where frame.isResponse:
            if let report = RCChannelReport(payload: frame.payload) {
                if let previous = latestChannels?.report, previous.channels != report.channels {
                    freshChannelMeter.add(at: time)
                    if let last = lastChannelChange, time - last < 0.2 {
                        channelChangeIntervals.append(time - last)
                        if channelChangeIntervals.count > Self.latencySampleLimit { channelChangeIntervals.removeFirst() }
                    }
                    lastChannelChange = time
                }
                latestChannels = (report, time)
            }
        case (0x06, 0x05):
            if let params = RCPushParams(payload: frame.payload) { latestPush = (params, time) }
        case (0x06, 0x1E):
            if let info = RCBatteryInfo(payload: frame.payload) { latestBattery = (info, time) }
        case (0x00, 0x01) where frame.isResponse:
            let hw = DUMLVersionResponse.hardwareVersion(payload: frame.payload)
            let fw = DUMLVersionResponse.firmwareVersion(payload: frame.payload)
            let info = "\(DUMLDevice.name(frame.sender)) hw \(hw ?? "?") fw \(fw ?? "?")"
            if versionInfo != info {
                versionInfo = info
                log?.log(.duml, "\(name) VERSION \(info)")
            }
        default:
            break
        }
    }

    private mutating func appendChunk(_ direction: Direction, _ bytes: [UInt8], at time: Double, note: String?) {
        recentChunks.append(Chunk(id: nextChunkID, time: time, direction: direction, length: bytes.count,
                                  head: Array(bytes.prefix(Self.chunkHeadLength)), note: note))
        nextChunkID += 1
        if recentChunks.count > Self.recentChunkLimit + 20 {
            recentChunks.removeFirst(recentChunks.count - Self.recentChunkLimit)
        }
    }

    private mutating func rollLogWindow(at time: Double, log: ProbeLog?) {
        let window = Int(time)
        guard window != logWindow else { return }
        if suppressedChunkLines > 0 || suppressedFrameLines > 0 || suppressedOutLines > 0 {
            log?.log(.stream, "\(name) (rate limit: \(suppressedChunkLines) chunk, \(suppressedFrameLines) DUML "
                + "and \(suppressedOutLines) outgoing lines not logged in the last second)")
        }
        logWindow = window
        chunkLinesThisWindow = 0
        frameLinesThisWindow = 0
        outLinesThisWindow = 0
        suppressedChunkLines = 0
        suppressedFrameLines = 0
        suppressedOutLines = 0
    }

    // MARK: Queries

    public mutating func refreshRates(at time: Double) {
        chunkRate = chunkMeter.rate(at: time)
        byteRate = byteMeter.rate(at: time)
        dumlRate = dumlMeter.rate(at: time)
        for (key, var type) in frameTypes {
            type.rate = type.meter.rate(at: time)
            frameTypes[key] = type
        }
        for (key, var stats) in replyStats {
            stats.replyRate = stats.meter.rate(at: time)
            replyStats[key] = stats
        }
        freshChannelRate = freshChannelMeter.rate(at: time)
    }

    public mutating func resetDiffBaselines() {
        for key in frameTypes.keys { frameTypes[key]!.diff.resetBaseline() }
        for key in rawDiffs.keys { rawDiffs[key]!.resetBaseline() }
    }

    /// Median of `channelChangeIntervals`, i.e. the typical time between new stick values.
    public var medianChannelChangeInterval: Double? {
        guard channelChangeIntervals.count >= 10 else { return nil }
        return channelChangeIntervals.sorted()[channelChangeIntervals.count / 2]
    }

    /// Number of DUML responses so far, by frame-type key (for the sweep's before/after).
    public var responseCounts: [String: Int] {
        frameTypes.filter { $0.value.isResponse }.mapValues(\.count)
    }

    public func statsLine() -> String {
        var parts = ["\(name): in \(chunksIn) chunks/\(bytesIn) B (\(Int(chunkRate))/s, \(Int(byteRate)) B/s)",
                     "out \(writesOut) writes/\(bytesOut) B",
                     "DUML \(dumlFramesIn) (\(Int(dumlRate))/s)",
                     "padding \(paddingBytes) B", "unparsed \(skippedBytes) B"]
        for stats in replyStats.values.sorted(by: { $0.label < $1.label }) where stats.sent > 0 {
            parts.append("\(stats.label) replies \(stats.replies)/\(stats.sent) (\(Int(stats.replyRate))/s"
                + (stats.averageLatency.map { String(format: ", avg %.1f ms", $0 * 1000) } ?? "") + ")")
        }
        if let median = medianChannelChangeInterval {
            parts.append(String(format: "06/01 fresh %.0f/s, median change interval %.1f ms", freshChannelRate, median * 1000))
        }
        if !ports.isEmpty {
            parts.append("55CC ports " + ports.values.sorted { $0.port < $1.port }
                .map { "\($0.port)×\($0.packets)" }.joined(separator: ","))
        }
        return parts.joined(separator: ", ")
    }
}
