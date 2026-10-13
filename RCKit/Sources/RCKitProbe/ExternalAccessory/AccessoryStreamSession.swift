#if os(iOS)
import ExternalAccessory
import Foundation
import RCKit
import Synchronization

/// A diagnostic session: one `AccessoryConnection` plus a `StreamAnalyzer`, request/reply matching
/// and poll experiments.
///
/// Threading: connection events, polling and writes run on the shared I/O `RunLoopThread`. The
/// properties in the "I/O thread only" block are touched only there, which is why the class can be
/// `@unchecked Sendable`. Anything the UI reads goes through the `Mutex`.
public final class AccessoryStreamSession: @unchecked Sendable {
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

    /// A repeating DUML request sent from the I/O thread (no main-thread timing jitter).
    public struct PollConfig: Sendable, Equatable {
        public enum Mode: Sendable, Equatable {
            /// Send at a fixed rate regardless of replies.
            case fixedRate(Double)
            /// Send the next request as soon as the previous reply arrives (one in flight).
            /// Shows the remote's maximum sustainable rate.
            case replyDriven
        }

        public var mode: Mode
        public var framing: DUMLOutboundFraming
        public var sender: UInt8
        public var commandSet: UInt8
        public var commandID: UInt8
        public var payload: [UInt8]

        public init(mode: Mode, framing: DUMLOutboundFraming, sender: UInt8,
                    commandSet: UInt8 = 0x06, commandID: UInt8 = 0x01, payload: [UInt8] = []) {
            self.mode = mode
            self.framing = framing
            self.sender = sender
            self.commandSet = commandSet
            self.commandID = commandID
            self.payload = payload
        }
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
        public let poll: PollConfig?
        public let pollTimeouts: Int
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
        var connection: AccessoryConnection?
        var poll: PollConfig?
        var pollTimeouts = 0
    }
    private let shared: Mutex<Shared>

    // MARK: I/O thread only
    private var poll: PollConfig?
    private var pollTimer: RunLoopTimer?
    // Separate range from the UI's sequence numbers (which start at 0x34EB) so replies match up.
    private var pollSequence = DUMLSequence(start: 0xA000)
    private var lastPollSequence: UInt16?
    private var lastPollSendTime: Double = 0

    init(accessory: EAAccessory, protocolString: String, io: RunLoopThread, log: ProbeLog) {
        accessoryID = accessory.connectionID
        accessoryName = accessory.name
        self.protocolString = protocolString
        id = "\(accessory.connectionID)|\(protocolString)"
        self.io = io
        self.log = log
        shared = Mutex(Shared(analyzer: StreamAnalyzer(name: protocolString)))
    }

    /// Creates the `EASession` (on the caller's thread, normally main).
    func open(accessory: EAAccessory) {
        log.log(.ea, "Opening EASession for \(protocolString) on accessory \(accessoryID)…")
        let connection = AccessoryConnection.open(accessory: accessory, protocolString: protocolString, io: io) {
            [weak self] event in self?.handle(event)
        }
        guard let connection else {
            // Typical causes: protocol not in Info.plist, another app holds a session for it,
            // or the accessory doesn't really support it.
            let reason = "EASession init returned nil"
            shared.withLock { $0.state = .failed(reason) }
            log.log(.ea, "\(protocolString): \(reason). Is another app (e.g. DJI Fly) holding it?")
            return
        }
        shared.withLock {
            $0.connection = connection
            $0.state = .open
        }
    }

    /// Queues bytes for the output stream. Safe from any thread. Pass the DUML `frame` the bytes
    /// carry so its reply can be matched (status, latency).
    public func send(_ bytes: [UInt8], note: String, frame: DUMLFrame? = nil) {
        io.perform { [self] in enqueue(bytes, note: note, frame: frame) }
    }

    /// Starts (or replaces) a repeating request on the I/O thread.
    public func startPolling(_ config: PollConfig) {
        io.perform { [self] in
            stopPollTimer()
            poll = config
            shared.withLock { $0.poll = config; $0.pollTimeouts = 0 }
            let interval: Double
            switch config.mode {
            case let .fixedRate(hz): interval = 1 / max(1, hz)
            case .replyDriven: interval = 0.05 // watchdog: resend if a reply is overdue
            }
            pollTimer = io.scheduleRepeating(interval: interval) { [weak self] in self?.pollTick() }
            log.log(.duml, "\(protocolString): polling \(Hex.byte(config.commandSet))/\(Hex.byte(config.commandID)) "
                + "\(config.mode) (\(config.framing.label), from \(DUMLDevice.name(config.sender)))")
            if config.mode == .replyDriven { pollSend() }
        }
    }

    public func stopPolling() {
        io.perform { [self] in
            guard poll != nil else { return }
            stopPollTimer()
            poll = nil
            shared.withLock { $0.poll = nil }
            log.log(.duml, "\(protocolString): polling stopped")
        }
    }

    /// Closes the session. With `wait`, returns once the protocol is free for another session.
    public func close(reason: String, wait: Bool = false) {
        let connection = shared.withLock { $0.connection }
        connection?.close(reason: reason, wait: wait)
    }

    public func snapshot() -> Snapshot {
        let now = ProbeClock.now()
        return shared.withLock { s in
            s.analyzer.refreshRates(at: now)
            return Snapshot(id: id, accessoryID: accessoryID, accessoryName: accessoryName,
                            protocolString: protocolString, state: s.state, openedAt: openedAt,
                            inputOpen: s.connection?.inputOpen ?? false, outputOpen: s.connection?.outputOpen ?? false,
                            pendingWriteBytes: s.connection?.pendingWriteBytes ?? 0, poll: s.poll,
                            pollTimeouts: s.pollTimeouts, analyzer: s.analyzer)
        }
    }

    public var state: State { shared.withLock { $0.state } }

    public func resetDiffBaselines() {
        shared.withLock { $0.analyzer.resetDiffBaselines() }
    }

    // MARK: I/O thread

    private func handle(_ event: AccessoryConnection.Event) {
        switch event {
        case let .opened(hasInput, hasOutput):
            log.log(.ea, "\(protocolString): EASession created; input \(hasInput ? "present" : "missing"), "
                + "output \(hasOutput ? "present" : "missing"). Streams opening.")
        case let .streamOpened(isInput):
            log.log(.ea, "\(protocolString): \(isInput ? "input" : "output") stream open")
        case let .received(chunk, time):
            let frames = shared.withLock { $0.analyzer.ingestIncoming(chunk, at: time, log: log) }
            if let poll, poll.mode == .replyDriven, let expected = lastPollSequence,
               frames.contains(where: { $0.isResponse && $0.sequence == expected
                   && $0.commandSet == poll.commandSet && $0.commandID == poll.commandID }) {
                pollSend()
            }
        case let .closed(reason):
            stopPollTimer()
            poll = nil
            shared.withLock {
                $0.state = .closed(reason)
                $0.poll = nil
            }
            log.log(.ea, "\(protocolString): session closed (\(reason))")
        }
    }

    private func enqueue(_ bytes: [UInt8], note: String, frame: DUMLFrame?) {
        guard let connection = shared.withLock({ $0.connection }), connection.isOpen else {
            log.log(.stream, "\(protocolString): send ignored, session not open (\(note))")
            return
        }
        let now = ProbeClock.now()
        shared.withLock { $0.analyzer.recordOutgoing(bytes, at: now, note: note, frame: frame, log: log) }
        connection.write(bytes)
    }

    private func pollTick() {
        guard let poll else { return }
        switch poll.mode {
        case .fixedRate:
            pollSend()
        case .replyDriven:
            if ProbeClock.now() - lastPollSendTime > 0.25 {
                shared.withLock { $0.pollTimeouts += 1 }
                pollSend()
            }
        }
    }

    private func pollSend() {
        guard let poll else { return }
        let sequence = pollSequence.next()
        let frame = DUMLFrame(sender: poll.sender, receiver: DUMLDevice.remoteControl, sequence: sequence,
                              commandSet: poll.commandSet, commandID: poll.commandID, payload: poll.payload)
        lastPollSequence = sequence
        lastPollSendTime = ProbeClock.now()
        enqueue(poll.framing.wrap(frame.encoded()), note: "poll \(frame.label)", frame: frame)
    }

    private func stopPollTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
        lastPollSequence = nil
    }
}
#endif
