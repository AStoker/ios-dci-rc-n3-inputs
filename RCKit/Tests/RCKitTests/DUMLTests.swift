import Testing
@testable import RCKit

/// Known-good packets from published sources (not from an RC-N3).
enum Fixtures {
    /// The RC-N1 tools' stick request, 06/01 PC→RC seq 0x34eb (pverhaert `dji.py`, hard-coded write).
    static let rcN1StickRequest = Hex.parse("55 0d 04 33 0a 06 eb 34 40 06 01 74 24")!

    /// Goggles N3 → iPhone captures (samuelsadok/dji_protocol `video_out_mobile.py` MAGIC_PACKETS),
    /// with the envelope header. The 2 bytes after each DUML frame lie outside the envelope's length
    /// and are left out here.
    static let gogglesCmd1 = Hex.parse("""
        55 cc 49 57 2d 00 00 00
        55 2d 04 f2 02 28 f3 fe 40 00 99
        02 02 00 00 d5 07 00 00 00 00 00 13 00 0d 00 63 61 6d 63 61 70 5f 63 6f 6d 6d 6f 6e 00 00 00 00
        d0 93
        """)!
    static let gogglesCmd2 = Hex.parse("""
        55 cc 49 57 1b 00 00 00
        55 1b 04 75 02 3c f4 fe 40 00 88
        17 00 00 23 00 41 50 50 00 00 00 00 00 02
        58 a6
        """)!
}

@Suite struct DUMLCRCTests {
    @Test func headerCRCMatchesPublishedPackets() {
        #expect(DUMLCRC.crc8(Fixtures.rcN1StickRequest[0..<3]) == 0x33)
        #expect(DUMLCRC.crc8(Fixtures.gogglesCmd1[8..<11]) == 0xF2)
        #expect(DUMLCRC.crc8(Fixtures.gogglesCmd2[8..<11]) == 0x75)
    }

    @Test func frameCRCMatchesPublishedPackets() {
        let req = Fixtures.rcN1StickRequest
        #expect(DUMLCRC.crc16(req.dropLast(2)) == 0x2474)
        let g1 = Array(Fixtures.gogglesCmd1.dropFirst(8))
        #expect(DUMLCRC.crc16(g1.dropLast(2)) == 0x93D0)
    }

    @Test func tablesMatchTheRCN1ToolTables() {
        // Spot-check entries against the literal tables in the RC-N1 tools' main.py.
        #expect(DUMLCRC.crc8([0x01], seed: 0) == 0x5E)
        #expect(DUMLCRC.crc8([0xFF], seed: 0) == 0x35)
        #expect(DUMLCRC.crc16([0x01], seed: 0) == 0x1189)
        #expect(DUMLCRC.crc16([0xFF], seed: 0) == 0x0F78)
    }
}

@Suite struct DUMLFrameTests {
    @Test func encodesTheExactRCN1StickRequest() {
        let frame = DUMLCommands.rcChannelParamsGet(sender: DUMLDevice.pc, sequence: 0x34EB)
        #expect(frame.encoded() == Fixtures.rcN1StickRequest)
    }

    @Test func encodesSimulatorModeLikeSendDUML() {
        // send_duml(s, 0x0a, 0x06, 0x40, 0x06, 0x24, '01') with seq 0x34eb, computed by the
        // Python port in docs/duml-protocol-notes.md.
        let frame = DUMLCommands.rcSimulatorMode(true, sender: DUMLDevice.pc, sequence: 0x34EB)
        #expect(frame.encoded() == Hex.parse("55 0e 04 66 0a 06 eb 34 40 06 24 01 d9 ec"))
    }

    @Test func decodesAndRoundTrips() throws {
        let frame = try DUMLFrame.decode(Fixtures.rcN1StickRequest)
        #expect(frame.sender == 0x0A)
        #expect(frame.receiver == 0x06)
        #expect(frame.sequence == 0x34EB)
        #expect(frame.commandType == 0x40)
        #expect(frame.commandSet == 0x06)
        #expect(frame.commandID == 0x01)
        #expect(frame.payload.isEmpty)
        #expect(frame.version == 1)
        #expect(!frame.isResponse)
        #expect(frame.label == "06/01 req PC→RC")
        #expect(frame.encoded() == Fixtures.rcN1StickRequest)
    }

    @Test func decodesGogglesFrame() throws {
        let frame = try DUMLFrame.decode(Fixtures.gogglesCmd2.dropFirst(8))
        #expect(frame.sender == 0x02)
        #expect(frame.commandSet == 0x00)
        #expect(frame.commandID == 0x88)
        #expect(frame.payload.count == 14)
    }

    @Test func rejectsCorruptFrames() {
        var bad = Fixtures.rcN1StickRequest
        bad[12] ^= 0xFF
        #expect(throws: DUMLFrame.DecodeError.badFrameCRC) { try DUMLFrame.decode(bad) }
        var badHeader = Fixtures.rcN1StickRequest
        badHeader[3] ^= 0x01
        #expect(throws: DUMLFrame.DecodeError.badHeaderCRC) { try DUMLFrame.decode(badHeader) }
        #expect(throws: DUMLFrame.DecodeError.tooShort) { try DUMLFrame.decode([0x55, 0x0d]) }
    }

    @Test func logicLinkWrapMatchesGogglesHeader() {
        let duml = Array(Fixtures.gogglesCmd1.dropFirst(8))
        #expect(LogicLink.wrap(duml, port: LogicLink.Port.duml) == Fixtures.gogglesCmd1)
    }
}

@Suite struct DUMLStreamScannerTests {
    @Test func findsFramesSplitAcrossChunks() {
        var scanner = DUMLStreamScanner()
        let stream = [0x00, 0x11] + Fixtures.rcN1StickRequest + Fixtures.rcN1StickRequest
        var frames = 0
        var skipped = 0
        for byte in stream {
            for item in scanner.append([byte]) {
                switch item {
                case .duml: frames += 1
                case let .skipped(n): skipped += n
                case .envelope: Issue.record("unexpected envelope")
                }
            }
        }
        #expect(frames == 2)
        #expect(skipped == 2)
        #expect(scanner.pendingByteCount == 0)
    }

    @Test func unwrapsEnvelopes() {
        var scanner = DUMLStreamScanner()
        let items = scanner.append(Fixtures.gogglesCmd1 + Fixtures.gogglesCmd2)
        let ports = items.compactMap { item -> UInt16? in
            if case let .duml(_, _, port) = item { return port }
            return nil
        }
        #expect(ports == [LogicLink.Port.duml, LogicLink.Port.duml])
    }

    @Test func reportsNonDUMLEnvelopes() {
        var scanner = DUMLStreamScanner()
        let video = LogicLink.wrap([0x00, 0x00, 0x00, 0x01, 0x67, 0x42], port: LogicLink.Port.video)
        let items = scanner.append(video)
        #expect(items == [.envelope(port: LogicLink.Port.video, length: 6, head: [0x00, 0x00, 0x00, 0x01, 0x67, 0x42])])
    }

    @Test func resyncsAfterACorruptFrame() {
        var scanner = DUMLStreamScanner()
        var corrupt = Fixtures.rcN1StickRequest
        corrupt[11] ^= 0xFF
        let items = scanner.append(corrupt + Fixtures.rcN1StickRequest)
        let frames = items.filter { if case .duml = $0 { true } else { false } }
        #expect(frames.count == 1)
    }

    @Test func waitsForTheRestOfAFrame() {
        var scanner = DUMLStreamScanner()
        #expect(scanner.append(Fixtures.rcN1StickRequest.prefix(6)).isEmpty)
        #expect(scanner.pendingByteCount == 6)
        let items = scanner.append(Fixtures.rcN1StickRequest.dropFirst(6))
        #expect(items.count == 1)
    }
}

@Suite struct RCDecoderTests {
    /// A 38-byte 06/01 response built to the layout the RC-N1 tools read (offsets 13/16/19/22/25).
    static func syntheticChannelResponse(_ values: [UInt16]) -> [UInt8] {
        var payload: [UInt8] = [0x00]
        for (i, v) in values.enumerated() { payload += [UInt8(i), UInt8(v & 0xFF), UInt8(v >> 8)] }
        let frame = DUMLFrame(sender: DUMLDevice.remoteControl, receiver: DUMLDevice.pc, sequence: 0x34EB,
                              commandType: 0x80, commandSet: 0x06, commandID: 0x01, payload: payload)
        return frame.encoded()
    }

    @Test func channelReportMatchesRCN1Offsets() throws {
        let values: [UInt16] = [364, 1024, 1684, 1100, 900, 1024, 1024, 1024]
        let raw = Self.syntheticChannelResponse(values)
        #expect(raw.count == 38)
        // The RC-N1 tools read data[13:15] etc. Check our layout agrees with theirs.
        func le(_ i: Int) -> UInt16 { UInt16(raw[i]) | UInt16(raw[i + 1]) << 8 }
        #expect([le(13), le(16), le(19), le(22), le(25)] == Array(values.prefix(5)))

        let frame = try DUMLFrame.decode(raw)
        let report = try #require(RCChannelReport(payload: frame.payload))
        #expect(report.channels.map(\.raw) == values)
        #expect(report.channels[0].normalized == -1)
        #expect(report.channels[1].normalized == 0)
        #expect(report.channels[2].normalized == 1)
    }

    @Test func pushParamsBits() throws {
        let payload: [UInt8] = [0x00, 0x04, 0x00, 0x04, 0x00, 0x04, 0x00, 0x04, 0x00, 0x04, 0x81, 0x18, 0xD0]
        let params = try #require(RCPushParams(payload: payload))
        #expect(params.aileron == 1024)
        #expect(params.wheelClick && params.wheelChanged)
        #expect(params.goHomePressed)
        #expect(params.modeSwitch == 1)
        #expect(params.custom1 && params.shutter && params.record)
        #expect(!params.custom2 && !params.playback)
    }

    @Test func versionResponseStrings() {
        var payload: [UInt8] = [0, 0] + Array("RC-N3-TEST".utf8)
        payload += [UInt8](repeating: 0, count: 16 - 10)
        payload += [0, 0, 0, 2] + [0x10, 0x03, 0x02, 0x01] + [0, 0, 0, 0]
        #expect(DUMLVersionResponse.hardwareVersion(payload: payload) == "RC-N3-TEST")
        #expect(DUMLVersionResponse.firmwareVersion(payload: payload) == "01.02.03.16")
    }
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

    @Test func rateMeterCountsTheLastSecond() {
        var meter = RateMeter()
        for i in 0..<50 { meter.add(at: 100 + Double(i) * 0.02) }
        #expect(meter.rate(at: 100.99) == 50)
        #expect(meter.rate(at: 102.5) == 0)
    }

    @Test func analyzerDecodesStickResponses() {
        var analyzer = StreamAnalyzer(name: "test")
        let raw = RCDecoderTests.syntheticChannelResponse([364, 1024, 1684, 1100, 900, 1024, 1024, 1024])
        analyzer.ingestIncoming(Array(raw.prefix(20)), at: 1, log: nil)
        analyzer.ingestIncoming(Array(raw.dropFirst(20)), at: 1.01, log: nil)
        #expect(analyzer.dumlFramesIn == 1)
        #expect(analyzer.latestChannels?.report.channels.first?.raw == 364)
        #expect(analyzer.responseCounts.values.reduce(0, +) == 1)
    }

    @Test func hexParsing() {
        #expect(Hex.parse("0x55, 0x0D 04") == [0x55, 0x0D, 0x04])
        #expect(Hex.parse("550d04") == [0x55, 0x0D, 0x04])
        #expect(Hex.parse("55 0") == nil)
        #expect(Hex.parse("zz") == nil)
        #expect(Hex.string([0x55, 0x0D, 0x04, 0xFF], limit: 2) == "55 0d …(+2)")
    }
}
