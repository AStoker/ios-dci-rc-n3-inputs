import Testing
import RCKit
@testable import RCKitProbe

/// A 38-byte 06/01 reply in the layout the RC-N3 uses (status + 8 × (tag, LE16)).
func syntheticChannelResponse(_ values: [UInt16]) -> [UInt8] {
    var payload: [UInt8] = [0x00]
    for (i, v) in values.enumerated() { payload += [UInt8(i), UInt8(v & 0xFF), UInt8(v >> 8)] }
    return DUMLFrame(sender: DUMLDevice.remoteControl, receiver: DUMLDevice.pc, sequence: 0x34EB,
                     commandType: 0x80, commandSet: 0x06, commandID: 0x01, payload: payload).encoded()
}

@Suite struct DiagnosticsTests {
    @Test func byteDiffTracksChangesAndRanges() {
        var diff = ByteDiffTracker()
        diff.ingest([1, 2, 3], at: 1)
        diff.ingest([1, 9, 3], at: 2)
        diff.ingest([1, 4, 3, 7], at: 3)
        #expect(diff.changedPositions == [1])
        #expect(diff.changeCounts[1] == 2)
        #expect(diff.minSeen[1] == 2 && diff.maxSeen[1] == 9)
        #expect(diff.latestLength == 4)
        diff.resetBaseline()
        #expect(diff.changedPositions.isEmpty)
        #expect(diff.minSeen == diff.latest)
    }

    @Test func analyzerDecodesStickResponses() {
        var analyzer = StreamAnalyzer(name: "test")
        let raw = syntheticChannelResponse([364, 1024, 1684, 1100, 900, 1024, 1024, 1024])
        analyzer.ingestIncoming(Array(raw.prefix(20)), at: 1, log: nil)
        analyzer.ingestIncoming(Array(raw.dropFirst(20)), at: 1.01, log: nil)
        #expect(analyzer.dumlFramesIn == 1)
        #expect(analyzer.latestChannels?.report.channels.first?.raw == 364)
        #expect(analyzer.responseCounts.values.reduce(0, +) == 1)
    }

    @Test func analyzerMatchesRepliesBySequence() {
        // RC-N3 behaviour: a 06/01 request to RC is answered by HDLINK-GND (0x0e), same sequence number.
        var analyzer = StreamAnalyzer(name: "test")
        let request = DUMLCommands.rcChannelParamsGet(sender: DUMLDevice.app, sequence: 0x1234)
        analyzer.recordOutgoing(LogicLink.wrap(request.encoded()), at: 10, note: "t", frame: request, log: nil)
        let reply = DUMLFrame(sender: 0x0E, receiver: DUMLDevice.app, sequence: 0x1234, commandType: 0x80,
                              commandSet: 0x06, commandID: 0x01, payload: [UInt8](repeating: 0, count: 25))
        let frames = analyzer.ingestIncoming(LogicLink.wrap(reply.encoded()) + [UInt8](repeating: 0, count: 100),
                                             at: 10.012, log: nil)
        #expect(frames.count == 1)
        let stats = analyzer.replyStats[0x0601]
        #expect(stats?.sent == 1 && stats?.replies == 1 && stats?.lastStatus == 0)
        #expect(abs((stats?.lastLatency ?? 0) - 0.012) < 1e-9)
        #expect(analyzer.paddingBytes == 100)
        #expect(analyzer.skippedBytes == 0)
    }

    @Test func analyzerMeasuresFreshStickValues() {
        // Polled every 10 ms, but values change only every other reply (a 50 Hz source), like the RC-N3.
        var analyzer = StreamAnalyzer(name: "test")
        for i in 0..<30 {
            let value = UInt16(1024 + (i / 2) * 20)
            let payload: [UInt8] = [0] + (0..<8).flatMap { _ in [0, UInt8(value & 0xFF), UInt8(value >> 8)] }
            let reply = DUMLFrame(sender: 0x0E, receiver: DUMLDevice.app, sequence: UInt16(i), commandType: 0x80,
                                  commandSet: 0x06, commandID: 0x01, payload: payload)
            analyzer.ingestIncoming(LogicLink.wrap(reply.encoded()), at: 50 + Double(i) * 0.01, log: nil)
        }
        let median = analyzer.medianChannelChangeInterval
        #expect(median.map { abs($0 - 0.02) < 1e-6 } == true)
    }
}
