import Foundation
import Synchronization

/// Thread-safe, timestamped event log with an in-memory tail and an optional file on disk.
///
/// Any thread can call `log(_:_:)`. The I/O thread logs packets while the main thread logs UI
/// actions, so all state sits behind a `Mutex` (a lock, the Swift equivalent of guarding shared
/// memory between Workers).
public final class ProbeLog: Sendable {
    public enum Category: String, Sendable, CaseIterable {
        case app = "APP"
        case ea = "EA"
        case stream = "IO"
        case duml = "DUML"
        case gc = "GC"
        case net = "NET"
        case mark = "MARK"
        case stats = "STATS"
    }

    public struct Line: Sendable, Identifiable, Equatable {
        public let id: Int
        /// Seconds since the log started.
        public let time: Double
        public let category: Category
        public let text: String

        public var formatted: String {
            let t = String(format: "%9.3f", time)
            let cat = category.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)
            return "+\(t) \(cat) \(text)"
        }
    }

    private struct State {
        var lines: [Line] = []
        var nextID = 0
        var startTime: Double
        var fileHandle: FileHandle?
        var fileURL: URL?
        var pending: [UInt8] = []
        var bytesWritten = 0
        var fileLimitHit = false
    }

    public static let memoryLineLimit = 5000
    public static let fileByteLimit = 200 * 1024 * 1024

    private let state: Mutex<State>
    private let directory: URL?

    /// - Parameter directory: where log files go. Pass nil for memory only (tests).
    public init(directory: URL?) {
        self.directory = directory
        state = Mutex(State(startTime: ProbeClock.now()))
    }

    public func log(_ category: Category, _ text: String) {
        let now = ProbeClock.now()
        state.withLock { s in
            let line = Line(id: s.nextID, time: now - s.startTime, category: category, text: text)
            s.nextID += 1
            s.lines.append(line)
            if s.lines.count > Self.memoryLineLimit + 500 {
                s.lines.removeFirst(s.lines.count - Self.memoryLineLimit)
            }
            Self.write(line.formatted + "\n", into: &s)
        }
    }

    /// The last `count` lines, oldest first.
    public func recentLines(_ count: Int) -> [Line] {
        state.withLock { Array($0.lines.suffix(count)) }
    }

    public var lastLineID: Int { state.withLock { $0.nextID - 1 } }

    public var currentFileURL: URL? { state.withLock { $0.fileURL } }

    public var currentFileSize: Int { state.withLock { $0.bytesWritten + $0.pending.count } }

    /// Closes the current file (if any) and starts a new one beginning with `header`.
    @discardableResult
    public func startNewFile(header: String) -> URL? {
        guard let directory else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = directory.appendingPathComponent("rcn3-probe-\(formatter.string(from: Date())).txt")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: url)

        state.withLock { s in
            Self.flush(&s)
            try? s.fileHandle?.close()
            s.fileHandle = handle
            s.fileURL = handle == nil ? nil : url
            s.bytesWritten = 0
            s.fileLimitHit = false
            Self.write(header.hasSuffix("\n") ? header : header + "\n", into: &s)
            // Include the in-memory tail so nothing logged before the rotation is lost.
            for line in s.lines.suffix(500) { Self.write(line.formatted + "\n", into: &s) }
            Self.flush(&s)
        }
        return handle == nil ? nil : url
    }

    /// Writes buffered lines to disk. Called about once a second and before exporting.
    public func flush() {
        state.withLock { Self.flush(&$0) }
    }

    public func clearMemory() {
        state.withLock { $0.lines.removeAll() }
    }

    private static func write(_ text: String, into s: inout State) {
        guard s.fileHandle != nil, !s.fileLimitHit else { return }
        s.pending.append(contentsOf: text.utf8)
        if s.pending.count > 64 * 1024 { flush(&s) }
    }

    private static func flush(_ s: inout State) {
        guard let handle = s.fileHandle, !s.pending.isEmpty else { return }
        do {
            try handle.write(contentsOf: s.pending)
            s.bytesWritten += s.pending.count
        } catch {
            s.fileLimitHit = true
        }
        s.pending.removeAll(keepingCapacity: true)
        if s.bytesWritten > fileByteLimit, !s.fileLimitHit {
            s.fileLimitHit = true
            try? handle.write(contentsOf: Array("!!! log file size limit reached; further lines are memory-only\n".utf8))
        }
    }
}
