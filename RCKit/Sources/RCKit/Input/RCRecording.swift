import Foundation
import Synchronization

/// First line of a recording file.
public struct RCRecordingHeader: Sendable, Equatable, Codable {
    public static let formatName = "rckit-recording"

    public var format: String
    public var version: Int
    public var startedAt: Date
    public var accessory: AccessoryInfo?
    public var note: String?

    public init(startedAt: Date = Date(), accessory: AccessoryInfo? = nil, note: String? = nil) {
        format = Self.formatName
        version = 1
        self.startedAt = startedAt
        self.accessory = accessory
        self.note = note
    }
}

/// A recorded session. File format: JSON Lines, a header object then one `RCInputSample` per line.
/// Human-readable and diffable; about 10 KB/s at 60 samples/s.
public struct RCRecording: Sendable, Equatable {
    public var header: RCRecordingHeader
    public var samples: [RCInputSample]

    public init(header: RCRecordingHeader, samples: [RCInputSample]) {
        self.header = header
        self.samples = samples
    }

    /// Seconds from the first to the last sample.
    public var duration: Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return last.time - first.time
    }

    public enum LoadError: Error, Equatable {
        case empty
        case notARecording
        case badLine(Int)
    }

    public static func load(from url: URL) throws -> RCRecording {
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline)
        guard let first = lines.first else { throw LoadError.empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let header = try? decoder.decode(RCRecordingHeader.self, from: Data(first.utf8)),
              header.format == RCRecordingHeader.formatName else { throw LoadError.notARecording }
        var samples: [RCInputSample] = []
        samples.reserveCapacity(lines.count - 1)
        for (offset, line) in lines.dropFirst().enumerated() {
            guard let sample = try? decoder.decode(RCInputSample.self, from: Data(line.utf8)) else {
                throw LoadError.badLine(offset + 2)
            }
            samples.append(sample)
        }
        return RCRecording(header: header, samples: samples)
    }

    static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }
}

/// Writes samples to a recording file as they arrive.
public final class RCRecorder: Sendable {
    public let url: URL

    private struct State {
        var handle: FileHandle?
        var count = 0
        var firstTime: Double?
        var lastTime: Double?
        var task: Task<Void, Never>?
    }
    private let state: Mutex<State>

    /// Creates the file (and its folder) and writes the header line.
    public init(url: URL, header: RCRecordingHeader) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: try RCRecording.encodeLine(header)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        state = Mutex(State(handle: handle))
    }

    public func append(_ sample: RCInputSample) {
        guard let line = try? RCRecording.encodeLine(sample) else { return }
        state.withLock { s in
            guard let handle = s.handle else { return }
            try? handle.write(contentsOf: line)
            s.count += 1
            s.firstTime = s.firstTime ?? sample.time
            s.lastTime = sample.time
        }
    }

    /// Records every sample `source` produces until `stop()`.
    public func record(from source: some RCInputSource) {
        let stream = source.samples()
        let task = Task.detached { [weak self] in
            for await sample in stream {
                guard let self else { return }
                self.append(sample)
            }
        }
        state.withLock { s in
            s.task?.cancel()
            s.task = task
        }
    }

    /// Stops recording and closes the file.
    public func stop() {
        state.withLock { s in
            s.task?.cancel()
            s.task = nil
            try? s.handle?.close()
            s.handle = nil
        }
    }

    public var sampleCount: Int { state.withLock { $0.count } }

    public var duration: Double {
        state.withLock { s in
            guard let first = s.firstTime, let last = s.lastTime else { return 0 }
            return last - first
        }
    }
}

/// Plays a recording back in real time through the `RCInputSource` interface.
public final class RCReplaySource: RCInputSource {
    public let recording: RCRecording
    public let loops: Bool
    public let name: String

    private let sampleHub = Broadcaster<RCInputSample>(bufferSize: 1024, replaysLatest: false)
    private let stateHub = Broadcaster<RCConnectionState>(initial: .stopped, bufferSize: 16, replaysLatest: true)
    private let task = Mutex<Task<Void, Never>?>(nil)

    public init(recording: RCRecording, name: String = "recording", loops: Bool = false) {
        self.recording = recording
        self.name = name
        self.loops = loops
    }

    public convenience init(url: URL, loops: Bool = false) throws {
        try self.init(recording: RCRecording.load(from: url), name: url.deletingPathExtension().lastPathComponent, loops: loops)
    }

    public var latest: RCInputSample? { sampleHub.latest }
    public var connectionState: RCConnectionState { stateHub.latest ?? .stopped }
    public func samples() -> AsyncStream<RCInputSample> { sampleHub.stream() }
    public func connectionStates() -> AsyncStream<RCConnectionState> { stateHub.stream() }

    @MainActor public func start() {
        stop()
        stateHub.publish(.replaying(name))
        let player = Task.detached { [recording, loops, sampleHub, stateHub] in
            repeat {
                guard let base = recording.samples.first?.time else { break }
                let start = ProbeClock.now()
                for original in recording.samples {
                    let wait = start + (original.time - base) - ProbeClock.now()
                    if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                    if Task.isCancelled { return }
                    var sample = original
                    sample.time = ProbeClock.now()
                    sample.source = .replay
                    sampleHub.publish(sample)
                }
            } while loops && !Task.isCancelled
            if !Task.isCancelled { stateHub.publish(.stopped) }
        }
        task.withLock { $0 = player }
    }

    @MainActor public func stop() {
        let running = task.withLock { t -> Task<Void, Never>? in
            defer { t = nil }
            return t
        }
        running?.cancel()
        if running != nil { stateHub.publish(.stopped) }
    }
}
