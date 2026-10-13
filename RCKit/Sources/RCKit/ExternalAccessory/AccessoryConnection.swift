#if os(iOS)
import ExternalAccessory
import Foundation
import Synchronization

/// The byte streams of one `EASession` (one accessory + one protocol string), run on a
/// `RunLoopThread`.
///
/// Threading: the `EASession` and its streams live on the I/O thread. Every property in the
/// "I/O thread only" block is touched only from there, which is why the class can be
/// `@unchecked Sendable`. Events are delivered on the I/O thread too.
public final class AccessoryConnection: NSObject, StreamDelegate, @unchecked Sendable {
    public enum Event: Sendable {
        /// The session exists; says whether iOS handed us each stream.
        case opened(hasInput: Bool, hasOutput: Bool)
        /// One stream finished opening.
        case streamOpened(isInput: Bool)
        case received([UInt8], time: Double)
        /// The session is gone (stream error or end, or `close`). Sent once.
        case closed(String)
    }

    public let accessoryID: Int
    public let protocolString: String
    public let io: RunLoopThread
    private let onEvent: @Sendable (Event) -> Void

    private struct Shared {
        var isOpen = true
        var inputOpen = false
        var outputOpen = false
        var pendingWriteBytes = 0
    }
    private let shared = Mutex(Shared())

    // MARK: I/O thread only
    private var session: EASession?
    private var input: InputStream?
    private var output: OutputStream?
    private var pendingWrite: [UInt8] = []
    private var readBuffer = [UInt8](repeating: 0, count: 64 * 1024)

    /// Creates the `EASession` on the calling thread (normally main) and hands it to the I/O thread.
    /// Returns nil when iOS refuses: protocol not declared in Info.plist, accessory gone, or another
    /// app already holds a session for this protocol.
    public static func open(accessory: EAAccessory, protocolString: String, io: RunLoopThread,
                            onEvent: @escaping @Sendable (Event) -> Void) -> AccessoryConnection? {
        guard let session = EASession(accessory: accessory, forProtocol: protocolString) else { return nil }
        let connection = AccessoryConnection(accessoryID: accessory.connectionID, protocolString: protocolString,
                                             io: io, onEvent: onEvent)
        let box = UncheckedSendableBox(value: session)
        io.perform { [connection] in connection.attach(box.value) }
        return connection
    }

    private init(accessoryID: Int, protocolString: String, io: RunLoopThread, onEvent: @escaping @Sendable (Event) -> Void) {
        self.accessoryID = accessoryID
        self.protocolString = protocolString
        self.io = io
        self.onEvent = onEvent
        super.init()
    }

    public var isOpen: Bool { shared.withLock { $0.isOpen } }
    public var inputOpen: Bool { shared.withLock { $0.inputOpen } }
    public var outputOpen: Bool { shared.withLock { $0.outputOpen } }
    public var pendingWriteBytes: Int { shared.withLock { $0.pendingWriteBytes } }

    /// Queues bytes for the output stream. Safe from any thread.
    public func write(_ bytes: [UInt8]) {
        io.perform { [self] in
            guard session != nil else { return }
            pendingWrite += bytes
            pumpWrites()
        }
    }

    /// Closes the streams. With `wait`, returns only after the I/O thread has torn the session down,
    /// so the protocol is free for another session straight away.
    public func close(reason: String, wait: Bool = false) {
        let work: @Sendable () -> Void = { [self] in teardown(reason: reason) }
        if wait { io.performAndWait(work) } else { io.perform(work) }
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
        onEvent(.opened(hasInput: input != nil, hasOutput: output != nil))
    }

    public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        let isInput = aStream === input
        switch eventCode {
        case .openCompleted:
            shared.withLock { if isInput { $0.inputOpen = true } else { $0.outputOpen = true } }
            onEvent(.streamOpened(isInput: isInput))
        case .hasBytesAvailable:
            readAvailable()
        case .hasSpaceAvailable:
            pumpWrites()
        case .errorOccurred:
            let error = aStream.streamError.map { "\($0.localizedDescription) [\(($0 as NSError).domain) \(($0 as NSError).code)]" } ?? "unknown"
            teardown(reason: "\(isInput ? "input" : "output") error: \(error)")
        case .endEncountered:
            teardown(reason: "\(isInput ? "input" : "output") ended")
        default:
            break
        }
    }

    private func readAvailable() {
        guard let input else { return }
        while input.hasBytesAvailable {
            let count = readBuffer.withUnsafeMutableBufferPointer { input.read($0.baseAddress!, maxLength: $0.count) }
            guard count > 0 else { break }
            onEvent(.received(Array(readBuffer[0..<count]), time: ProbeClock.now()))
        }
    }

    private func pumpWrites() {
        guard let output, !pendingWrite.isEmpty else { return }
        while output.hasSpaceAvailable, !pendingWrite.isEmpty {
            let written = pendingWrite.withUnsafeBufferPointer { output.write($0.baseAddress!, maxLength: $0.count) }
            guard written > 0 else { break }
            pendingWrite.removeFirst(written)
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
        shared.withLock { $0 = Shared(isOpen: false) }
        onEvent(.closed(reason))
    }
}
#endif
