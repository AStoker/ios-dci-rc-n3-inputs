#if os(iOS)
import ExternalAccessory
import Foundation
import Synchronization

/// Metadata for one connected External Accessory (a value copy of `EAAccessory`).
public struct AccessoryInfo: Sendable, Identifiable, Hashable {
    public var id: Int { connectionID }
    public let connectionID: Int
    public let name: String
    public let manufacturer: String
    public let modelNumber: String
    public let serialNumber: String
    public let firmwareRevision: String
    public let hardwareRevision: String
    public let protocolStrings: [String]
    public let isConnected: Bool

    init(_ accessory: EAAccessory) {
        connectionID = accessory.connectionID
        name = accessory.name
        manufacturer = accessory.manufacturer
        modelNumber = accessory.modelNumber
        serialNumber = accessory.serialNumber
        firmwareRevision = accessory.firmwareRevision
        hardwareRevision = accessory.hardwareRevision
        protocolStrings = accessory.protocolStrings
        isConnected = accessory.isConnected
    }

    public var logDescription: String {
        "name=\"\(name)\" manufacturer=\"\(manufacturer)\" model=\"\(modelNumber)\" serial=\"\(serialNumber)\" "
            + "fw=\"\(firmwareRevision)\" hw=\"\(hardwareRevision)\" connectionID=\(connectionID) "
            + "connected=\(isConnected) protocols=[\(protocolStrings.joined(separator: ", "))]"
    }
}

/// One open `EASession` (one accessory + one protocol string) and its two byte streams.
///
/// Threading: the `EASession` and its streams live on the shared I/O `RunLoopThread`. Every
/// property in the "I/O thread only" block is touched only from that thread. That invariant is why
/// the class can be `@unchecked Sendable`. Anything the UI reads goes through the `Mutex`.
public final class AccessoryStreamSession: NSObject, StreamDelegate, @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case opening
        case open
        case closed(String)
        case failed(String)

        public var label: String {
            switch self {
            case .opening: "opening"
            case .open: "open"
            case let .closed(reason): "closed (\(reason))"
            case let .failed(reason): "FAILED (\(reason))"
            }
        }

        public var isLive: Bool { self == .opening || self == .open }
    }

    public struct Snapshot: Sendable, Identifiable {
        public let id: String
        public let accessoryID: Int
        public let accessoryName: String
        public let protocolString: String
        public let state: State
        public let openedAt: Double
        public let inputOpen: Bool
        public let outputOpen: Bool
        public let pendingWriteBytes: Int
        public let analyzer: StreamAnalyzer
    }

    public let id: String
    public let accessoryID: Int
    public let accessoryName: String
    public let protocolString: String
    public let openedAt = ProbeClock.now()

    private let io: RunLoopThread
    private let log: ProbeLog

    private struct Shared {
        var state: State = .opening
        var analyzer: StreamAnalyzer
        var inputOpen = false
        var outputOpen = false
        var pendingWriteBytes = 0
    }
    private let shared: Mutex<Shared>

    // MARK: I/O thread only
    private var session: EASession?
    private var input: InputStream?
    private var output: OutputStream?
    private var pendingWrite: [UInt8] = []
    private var readBuffer = [UInt8](repeating: 0, count: 64 * 1024)

    init(accessory: EAAccessory, protocolString: String, io: RunLoopThread, log: ProbeLog) {
        accessoryID = accessory.connectionID
        accessoryName = accessory.name
        self.protocolString = protocolString
        id = "\(accessory.connectionID)|\(protocolString)"
        self.io = io
        self.log = log
        shared = Mutex(Shared(analyzer: StreamAnalyzer(name: protocolString)))
        super.init()
    }

    /// Creates the `EASession` (on the caller's thread, normally main) and hands it to the I/O thread.
    func open(accessory: EAAccessory) {
        log.log(.ea, "Opening EASession for \(protocolString) on accessory \(accessoryID)…")
        guard let session = EASession(accessory: accessory, forProtocol: protocolString) else {
            // Typical causes: protocol not in Info.plist, another app holds a session for it,
            // or the accessory doesn't really support it.
            let reason = "EASession init returned nil"
            shared.withLock { $0.state = .failed(reason) }
            log.log(.ea, "\(protocolString): \(reason). Is another app (e.g. DJI Fly) holding it?")
            return
        }
        let box = UncheckedSendableBox(value: session)
        io.perform { [self] in attach(box.value) }
    }

    /// Queues bytes for the output stream. Safe from any thread.
    public func send(_ bytes: [UInt8], note: String) {
        io.perform { [self] in
            guard session != nil else {
                log.log(.stream, "\(protocolString): send ignored, session not open (\(note))")
                return
            }
            pendingWrite += bytes
            let now = ProbeClock.now()
            let pending = pendingWrite.count
            shared.withLock {
                $0.analyzer.recordOutgoing(bytes, at: now, note: note, log: log)
                $0.pendingWriteBytes = pending
            }
            pumpWrites()
        }
    }

    public func close(reason: String) {
        io.perform { [self] in teardown(reason: reason) }
    }

    public func snapshot() -> Snapshot {
        let now = ProbeClock.now()
        return shared.withLock { s in
            s.analyzer.refreshRates(at: now)
            return Snapshot(id: id, accessoryID: accessoryID, accessoryName: accessoryName,
                            protocolString: protocolString, state: s.state, openedAt: openedAt,
                            inputOpen: s.inputOpen, outputOpen: s.outputOpen,
                            pendingWriteBytes: s.pendingWriteBytes, analyzer: s.analyzer)
        }
    }

    public var state: State { shared.withLock { $0.state } }

    public func resetDiffBaselines() {
        shared.withLock { $0.analyzer.resetDiffBaselines() }
    }

    // MARK: I/O thread

    private func attach(_ session: EASession) {
        precondition(io.isCurrent)
        self.session = session
        input = session.inputStream
        output = session.outputStream
        for stream in [input, output] as [Stream?] {
            stream?.delegate = self
            stream?.schedule(in: .current, forMode: .default)
            stream?.open()
        }
        shared.withLock { $0.state = .open }
        log.log(.ea, "\(protocolString): EASession created; input \(input == nil ? "missing" : "present"), "
            + "output \(output == nil ? "missing" : "present"). Streams opening.")
    }

    public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        let which = aStream === input ? "input" : "output"
        switch eventCode {
        case .openCompleted:
            shared.withLock { if aStream === input { $0.inputOpen = true } else { $0.outputOpen = true } }
            log.log(.ea, "\(protocolString): \(which) stream open")
        case .hasBytesAvailable:
            readAvailable()
        case .hasSpaceAvailable:
            pumpWrites()
        case .errorOccurred:
            let error = aStream.streamError.map { "\($0.localizedDescription) [\(($0 as NSError).domain) \(($0 as NSError).code)]" } ?? "unknown"
            log.log(.ea, "\(protocolString): \(which) stream ERROR \(error)")
            teardown(reason: "\(which) error: \(error)")
        case .endEncountered:
            log.log(.ea, "\(protocolString): \(which) stream ended")
            teardown(reason: "\(which) ended")
        default:
            break
        }
    }

    private func readAvailable() {
        guard let input else { return }
        while input.hasBytesAvailable {
            let count = readBuffer.withUnsafeMutableBufferPointer { input.read($0.baseAddress!, maxLength: $0.count) }
            guard count > 0 else {
                if count < 0 { log.log(.stream, "\(protocolString): read error \(input.streamError?.localizedDescription ?? "?")") }
                break
            }
            let chunk = Array(readBuffer[0..<count])
            let now = ProbeClock.now()
            shared.withLock { $0.analyzer.ingestIncoming(chunk, at: now, log: log) }
        }
    }

    private func pumpWrites() {
        guard let output, !pendingWrite.isEmpty else { return }
        while output.hasSpaceAvailable, !pendingWrite.isEmpty {
            let written = pendingWrite.withUnsafeBufferPointer { output.write($0.baseAddress!, maxLength: $0.count) }
            if written > 0 {
                pendingWrite.removeFirst(written)
            } else {
                if written < 0 { log.log(.stream, "\(protocolString): write error \(output.streamError?.localizedDescription ?? "?")") }
                break
            }
        }
        let pending = pendingWrite.count
        shared.withLock { $0.pendingWriteBytes = pending }
    }

    private func teardown(reason: String) {
        guard session != nil else { return }
        for stream in [input, output] as [Stream?] {
            stream?.delegate = nil
            stream?.close()
            stream?.remove(from: .current, forMode: .default)
        }
        input = nil
        output = nil
        session = nil
        pendingWrite.removeAll()
        shared.withLock {
            $0.state = .closed(reason)
            $0.inputOpen = false
            $0.outputOpen = false
            $0.pendingWriteBytes = 0
        }
        log.log(.ea, "\(protocolString): session closed (\(reason))")
    }
}
#endif
