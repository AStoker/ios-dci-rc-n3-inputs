import Foundation
import Testing
@testable import RCKit

/// 06/05 push as the RC-N3 sends it (RC→APP, cmd type 0x00, seq 0).
func pushFrame(aileron: UInt16 = 1024, elevator: UInt16 = 1024, throttle: UInt16 = 1024, rudder: UInt16 = 1024,
               gimbal: UInt16 = 1024, flagsA: UInt8 = 0x10, flagsB: UInt8 = 0) -> DUMLFrame {
    var payload: [UInt8] = []
    for v in [aileron, elevator, throttle, rudder, gimbal] { payload += [UInt8(v & 0xFF), UInt8(v >> 8)] }
    payload += [0x00, flagsA, flagsB]
    return DUMLFrame(sender: DUMLDevice.remoteControl, receiver: DUMLDevice.app, sequence: 0, commandType: 0x00,
                     commandSet: 0x06, commandID: 0x05, payload: payload)
}

/// 06/01 reply as the RC-N3 sends it (HDLINK-GND→APP). `channels`: right X, right Y, left Y, left X, gimbal.
func pollReply(_ channels: [UInt16], sequence: UInt16 = 1) -> DUMLFrame {
    var payload: [UInt8] = [0x00]
    for v in channels + [1024, 1024, 1024] { payload += [0x00, UInt8(v & 0xFF), UInt8(v >> 8)] }
    return DUMLFrame(sender: 0x0E, receiver: DUMLDevice.app, sequence: sequence, commandType: 0x80,
                     commandSet: 0x06, commandID: 0x01, payload: payload)
}

@Suite struct AssemblerTests {
    @Test func pushAloneDrivesEverything() throws {
        var assembler = RCN3InputAssembler()
        let sampleValue = assembler.ingest(pushFrame(throttle: 1684, rudder: 364, flagsA: 0x28, flagsB: 0x41), at: 1)
        let sample = try #require(sampleValue)
        #expect(sample.source == .push)
        #expect(sample.leftStick == RCStick(x: -1, y: 1))
        #expect(sample.rightStick == .centered)
        #expect(sample.flightMode == .cine)
        #expect(sample.buttons == [.pauseRTH, .shutterRecord, .photoVideo])
        #expect(sample.raw.flagsA == 0x28 && sample.raw.flagsB == 0x41)
    }

    @Test func pollDrivesSticksAndModeIsUnknownUntilFirstPush() throws {
        var assembler = RCN3InputAssembler()
        let firstValue = assembler.ingest(pollReply([1684, 364, 1024, 1024, 1024]), at: 1)
        let first = try #require(firstValue)
        #expect(first.source == .poll)
        #expect(first.rightStick == RCStick(x: 1, y: -1))
        #expect(first.flightMode == .unknown)
        #expect(first.buttons.isEmpty)
        // Same values again: no new information, no sample.
        #expect(assembler.ingest(pollReply([1684, 364, 1024, 1024, 1024]), at: 1.01) == nil)
    }

    @Test func pushOnlyAddsSamplesForModeOrButtonChangesWhilePolling() throws {
        var assembler = RCN3InputAssembler()
        _ = assembler.ingest(pollReply([1100, 1024, 1024, 1024, 1024]), at: 1.00)
        // First push while polling: buttons/mode "changed" from nothing → sample, sticks from the poll.
        let withModeValue = assembler.ingest(pushFrame(aileron: 900, flagsA: 0x10), at: 1.01)
        let withMode = try #require(withModeValue)
        #expect(withMode.source == .push)
        #expect(withMode.raw.rightX == 1100)
        #expect(withMode.flightMode == .normal)
        // Same flags again: nothing new.
        #expect(assembler.ingest(pushFrame(aileron: 950, flagsA: 0x10), at: 1.12) == nil)
        // Photo/Video pressed → sample.
        let pressedValue = assembler.ingest(pushFrame(flagsA: 0x10, flagsB: 0x01), at: 1.20)
        let pressed = try #require(pressedValue)
        #expect(pressed.buttons == [.photoVideo])
        // Later polls carry the latest mode and buttons.
        let polledValue = assembler.ingest(pollReply([1200, 1024, 1024, 1024, 1024]), at: 1.21)
        let polled = try #require(polledValue)
        #expect(polled.buttons == [.photoVideo] && polled.flightMode == .normal)
    }

    @Test func pushTakesOverSticksWhenPollingGoesStale() throws {
        var assembler = RCN3InputAssembler()
        _ = assembler.ingest(pollReply([1100, 1024, 1024, 1024, 1024]), at: 1.0)
        _ = assembler.ingest(pushFrame(flagsA: 0x10), at: 1.1)
        let staleValue = assembler.ingest(pushFrame(aileron: 364, flagsA: 0x10), at: 1.0 + RCN3InputAssembler.pollStaleAfter + 0.01)
        let stale = try #require(staleValue)
        #expect(stale.raw.rightX == 364)
    }

    @Test func indexIncreasesPerSample() {
        var assembler = RCN3InputAssembler()
        let a = assembler.ingest(pollReply([1100, 1024, 1024, 1024, 1024]), at: 1)
        let b = assembler.ingest(pollReply([1110, 1024, 1024, 1024, 1024]), at: 1.01)
        #expect(a?.index == 0 && b?.index == 1)
    }

    @Test func ignoresOtherFramesAndBadReplies() {
        var assembler = RCN3InputAssembler()
        #expect(assembler.ingest(DUMLCommands.versionInquiry(sender: DUMLDevice.app, sequence: 1), at: 1) == nil)
        var failed = pollReply([1100, 1024, 1024, 1024, 1024])
        failed.payload[0] = 0x01 // non-zero status
        #expect(assembler.ingest(failed, at: 1) == nil)
    }
}

@Suite struct StickModeTests {
    let left = RCStick(x: 0.1, y: 0.2)
    let right = RCStick(x: 0.3, y: 0.4)

    @Test func mode2IsTheDefaultLayout() {
        #expect(RCStickMode.mode2.axes(left: left, right: right) == .init(throttle: 0.2, yaw: 0.1, pitch: 0.4, roll: 0.3))
    }

    @Test func mode1And3() {
        #expect(RCStickMode.mode1.axes(left: left, right: right) == .init(throttle: 0.4, yaw: 0.1, pitch: 0.2, roll: 0.3))
        #expect(RCStickMode.mode3.axes(left: left, right: right) == .init(throttle: 0.4, yaw: 0.3, pitch: 0.2, roll: 0.1))
    }
}

@Suite struct RecordingTests {
    func makeSamples() -> [RCInputSample] {
        var assembler = RCN3InputAssembler()
        var samples: [RCInputSample] = []
        if let s = assembler.ingest(pushFrame(flagsA: 0x20), at: 10) { samples.append(s) }
        for i in 1...5 {
            if let s = assembler.ingest(pollReply([UInt16(1024 + i * 50), 1024, 1024, 1024, 1024]), at: 10 + Double(i) * 0.02) {
                samples.append(s)
            }
        }
        return samples
    }

    @Test func recorderWritesJSONLinesThatLoadBack() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rckit-test-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let header = RCRecordingHeader(startedAt: Date(timeIntervalSince1970: 1_800_000_000), note: "unit test")
        let recorder = try RCRecorder(url: url, header: header)
        let samples = makeSamples()
        for sample in samples { recorder.append(sample) }
        recorder.stop()
        #expect(recorder.sampleCount == samples.count)

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.split(separator: "\n").count == samples.count + 1)
        #expect(text.hasPrefix("{\"format\":\"rckit-recording\""))

        let loaded = try RCRecording.load(from: url)
        #expect(loaded.header == header)
        #expect(loaded.samples == samples)
        #expect(abs(loaded.duration - 0.1) < 1e-9)
    }

    @Test func rejectsFilesThatArentRecordings() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rckit-test-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try "{\"hello\":1}\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: RCRecording.LoadError.notARecording) { try RCRecording.load(from: url) }
    }

    @Test @MainActor func replayPlaysSamplesInOrderWithTiming() async throws {
        let samples = RecordingTests().makeSamples()
        let replay = RCReplaySource(recording: RCRecording(header: RCRecordingHeader(), samples: samples), name: "test")
        let stream = replay.samples()
        let started = ProbeClock.now()
        replay.start()
        #expect(replay.connectionState == .replaying("test"))
        var received: [RCInputSample] = []
        for await sample in stream {
            received.append(sample)
            if received.count == samples.count { break }
        }
        let elapsed = ProbeClock.now() - started
        #expect(received.map(\.raw) == samples.map(\.raw))
        #expect(received.allSatisfy { $0.source == .replay })
        #expect(elapsed >= 0.09) // the recording spans 0.1 s
        replay.stop()
        #expect(replay.connectionState == .stopped)
    }
}

@Suite struct BroadcasterTests {
    @Test func latestAndStreams() async {
        let hub = Broadcaster<Int>(bufferSize: 8, replaysLatest: true)
        #expect(hub.latest == nil)
        hub.publish(1)
        let stream = hub.stream()
        hub.publish(2)
        #expect(hub.publish(2, onlyIfChanged: true) == false)
        hub.publish(3)
        var values: [Int] = []
        for await value in stream {
            values.append(value)
            if values.count == 3 { break }
        }
        #expect(values == [1, 2, 3])
        #expect(hub.latest == 3)
    }
}
