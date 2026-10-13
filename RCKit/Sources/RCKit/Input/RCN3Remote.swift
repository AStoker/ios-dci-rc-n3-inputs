#if os(iOS)
import ExternalAccessory
import Foundation
import Synchronization

/// The live DJI RC-N3, as an `RCInputSource`.
///
/// ```swift
/// let remote = RCN3Remote()
/// remote.start()                       // on the main actor
/// // every frame, from any thread:
/// if let input = remote.latest { let axes = RCStickMode.mode2.axes(input) }
/// ```
///
/// What it does (all confirmed on hardware, see docs/findings.md):
/// - watches External Accessory for a remote advertising `com.dji.logiclink` and opens it;
///   reconnects on replug, retries every 2 s if another app holds the remote;
/// - polls 06/01 (sticks + gimbal) at `pollRate` from the I/O thread, sent as App inside a
///   `55 CC` envelope; takes mode switch and buttons from the remote's 06/05 push;
/// - turns those into `RCInputSample`s (`RCN3InputAssembler`).
///
/// Threading: EA notifications and session creation on the main actor; stream I/O, polling and
/// sample assembly on a private `RunLoopThread`; shared state behind a `Mutex`. Samples are
/// published from the I/O thread.
public final class RCN3Remote: RCInputSource, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var protocolString: String
        /// 06/01 poll rate in Hz. 100 catches every new value (the remote refreshes at ~50-60 Hz)
        /// and still leaves the 06/05 push at ~7/s. 0 = push only (~9 samples/s).
        public var pollRate: Double

        public init(protocolString: String = "com.dji.logiclink", pollRate: Double = 100) {
            self.protocolString = protocolString
            self.pollRate = pollRate
        }
    }

    /// Raw traffic and state, for diagnostics tools. Delivered on the I/O thread (state changes may
    /// come from the main thread); keep the handler fast.
    public enum DiagnosticEvent: Sendable {
        case received([UInt8], time: Double)
        case sent([UInt8], note: String, frame: DUMLFrame?, time: Double)
        case state(RCConnectionState)
    }

    public struct Stats: Sendable, Equatable {
        public var sampleRate: Double = 0
        public var pollReplyRate: Double = 0
        public var pushRate: Double = 0
        /// Recent average 06/01 round trip, seconds.
        public var averageLatency: Double?
        public var lastSampleTime: Double?
        public var framesReceived = 0
        public var bytesReceived = 0
        /// From the 00/01 version reply, e.g. "rc151 fw 00.01.03.39".
        public var remoteVersion: String?

        public init() {}
    }

    public let configuration: Configuration
    private let diagnostics: (@Sendable (DiagnosticEvent) -> Void)?
    private let io = RunLoopThread(name: "RCKit.RCN3Remote")
    private let sampleHub = Broadcaster<RCInputSample>(bufferSize: 1024, replaysLatest: false)
    private let stateHub = Broadcaster<RCConnectionState>(initial: .stopped, bufferSize: 16, replaysLatest: true)

    private struct IOState {
        var connection: AccessoryConnection?
        var generation = 0
        var info: AccessoryInfo?
        var scanner = DUMLStreamScanner()
        var assembler = RCN3InputAssembler()
        var sequence = DUMLSequence(start: 0x4000)
        var outstanding: [UInt16: Double] = [:]
        var latencies: [Double] = []
        var streaming = false
        var lastFrameTime: Double?
        var sampleMeter = RateMeter()
        var replyMeter = RateMeter()
        var pushMeter = RateMeter()
        var stats = Stats()
    }
    private let ioState = Mutex(IOState())

    // Main actor only
    @MainActor private var running = false
    @MainActor private var observers: [NSObjectProtocol] = []
    @MainActor private var retryTask: Task<Void, Never>?
    @MainActor private var pollTimer: RunLoopTimer?
    @MainActor private var watchdogTimer: RunLoopTimer?

    public init(configuration: Configuration = Configuration(),
                diagnostics: (@Sendable (DiagnosticEvent) -> Void)? = nil) {
        self.configuration = configuration
        self.diagnostics = diagnostics
    }

    // MARK: RCInputSource

    public var latest: RCInputSample? { sampleHub.latest }
    public var connectionState: RCConnectionState { stateHub.latest ?? .stopped }
    public func samples() -> AsyncStream<RCInputSample> { sampleHub.stream() }
    public func connectionStates() -> AsyncStream<RCConnectionState> { stateHub.stream() }

    @MainActor public func start() {
        guard !running else { return }
        running = true
        EAAccessoryManager.shared().registerForLocalNotifications()
        for name in [Notification.Name.EAAccessoryDidConnect, .EAAccessoryDidDisconnect] {
            // queue: .main, so asserting main-actor isolation is correct.
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        watchdogTimer = io.scheduleRepeating(interval: 0.25) { [weak self] in self?.watchdog() }
        setState(.waitingForAccessory)
        refresh()
    }

    @MainActor public func stop() {
        guard running else { return }
        running = false
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        retryTask?.cancel()
        retryTask = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        closeConnection(reason: "stopped")
        setState(.stopped)
    }

    /// Re-checks connected accessories and (re)opens the remote if needed. Call when the app
    /// returns to the foreground; iOS tears EA sessions down for suspended apps.
    @MainActor public func refresh() {
        guard running else { return }
        let accessories = EAAccessoryManager.shared().connectedAccessories
        if let connection = ioState.withLock({ $0.connection }) {
            if connection.isOpen, accessories.contains(where: { $0.connectionID == connection.accessoryID }) { return }
            closeConnection(reason: "accessory gone")
        }
        guard let accessory = accessories.first(where: { $0.protocolStrings.contains(configuration.protocolString) }) else {
            setState(.waitingForAccessory)
            return
        }
        open(accessory)
    }

    // MARK: Stats & diagnostics

    public var stats: Stats {
        let now = ProbeClock.now()
        return ioState.withLock { s in
            var stats = s.stats
            stats.sampleRate = s.sampleMeter.rate(at: now)
            stats.pollReplyRate = s.replyMeter.rate(at: now)
            stats.pushRate = s.pushMeter.rate(at: now)
            stats.averageLatency = s.latencies.isEmpty ? nil : s.latencies.reduce(0, +) / Double(s.latencies.count)
            return stats
        }
    }

    /// Writes bytes exactly as given (wrap DUML in `LogicLink.wrap` yourself). For diagnostics.
    public func sendDiagnostic(_ bytes: [UInt8], note: String, frame: DUMLFrame? = nil) {
        io.perform { [self] in
            let now = ProbeClock.now()
            let connection = ioState.withLock { s -> AccessoryConnection? in
                if let frame, !frame.isResponse {
                    s.outstanding[frame.sequence] = now
                    // Lost replies (~1% at 100 Hz) would otherwise accumulate.
                    if s.outstanding.count > 512 { s.outstanding = s.outstanding.filter { now - $0.value < 1 } }
                }
                return s.connection
            }
            guard let connection, connection.isOpen else { return }
            connection.write(bytes)
            diagnostics?(.sent(bytes, note: note, frame: frame, time: now))
        }
    }

    // MARK: Main actor

    @MainActor private func open(_ accessory: EAAccessory) {
        let info = AccessoryInfo(accessory)
        let generation = ioState.withLock { s -> Int in
            s.generation += 1
            s.info = info
            s.scanner.reset()
            s.streaming = false
            s.lastFrameTime = nil
            s.outstanding.removeAll()
            return s.generation
        }
        setState(.connecting(info))
        let connection = AccessoryConnection.open(accessory: accessory, protocolString: configuration.protocolString, io: io) {
            [weak self] event in self?.handle(event, generation: generation)
        }
        guard let connection else {
            setState(.failed("Couldn't open \(configuration.protocolString). Another app (e.g. DJI Fly) may be using the remote."))
            scheduleRetry()
            return
        }
        ioState.withLock { $0.connection = connection }
        send(DUMLCommands.versionInquiry(sender: DUMLDevice.app, sequence: nextSequence()), note: "version")
        if configuration.pollRate > 0 {
            pollTimer = io.scheduleRepeating(interval: 1 / configuration.pollRate) { [weak self] in self?.pollTick() }
        }
    }

    @MainActor private func closeConnection(reason: String) {
        pollTimer?.invalidate()
        pollTimer = nil
        let connection = ioState.withLock { s -> AccessoryConnection? in
            defer { s.connection = nil }
            return s.connection
        }
        connection?.close(reason: reason, wait: true)
    }

    @MainActor private func connectionClosed(generation: Int) {
        guard running, ioState.withLock({ $0.generation }) == generation else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        ioState.withLock { $0.connection = nil }
        setState(.waitingForAccessory)
        scheduleRetry()
    }

    @MainActor private func scheduleRetry() {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    // MARK: I/O thread

    private func handle(_ event: AccessoryConnection.Event, generation: Int) {
        guard ioState.withLock({ $0.generation }) == generation else { return }
        switch event {
        case .opened, .streamOpened:
            break
        case let .received(bytes, time):
            diagnostics?(.received(bytes, time: time))
            let (samples, nowStreaming) = ingest(bytes, at: time)
            for sample in samples { sampleHub.publish(sample) }
            if let info = nowStreaming { setState(.streaming(info)) }
        case .closed:
            Task { @MainActor [weak self] in self?.connectionClosed(generation: generation) }
        }
    }

    /// Returns the new samples, and the accessory info if this chunk started (or resumed) the stream.
    private func ingest(_ bytes: [UInt8], at time: Double) -> ([RCInputSample], AccessoryInfo?) {
        ioState.withLock { s in
            s.stats.bytesReceived += bytes.count
            var samples: [RCInputSample] = []
            var resumed = false
            for item in s.scanner.append(bytes) {
                guard case let .duml(frame, _, _) = item else { continue }
                s.stats.framesReceived += 1
                s.lastFrameTime = time
                if !s.streaming {
                    s.streaming = true
                    resumed = true
                }
                if frame.isResponse, let sent = s.outstanding.removeValue(forKey: frame.sequence) {
                    if frame.commandSet == 0x06, frame.commandID == 0x01 {
                        s.replyMeter.add(at: time)
                        s.latencies.append(time - sent)
                        if s.latencies.count > 100 { s.latencies.removeFirst() }
                    } else if frame.commandSet == 0x00, frame.commandID == 0x01 {
                        let hw = DUMLVersionResponse.hardwareVersion(payload: frame.payload) ?? "?"
                        let fw = DUMLVersionResponse.firmwareVersion(payload: frame.payload) ?? "?"
                        s.stats.remoteVersion = "\(hw) fw \(fw)"
                    }
                }
                if frame.commandSet == 0x06, frame.commandID == 0x05, !frame.isResponse { s.pushMeter.add(at: time) }
                if let sample = s.assembler.ingest(frame, at: time) {
                    s.sampleMeter.add(at: time)
                    s.stats.lastSampleTime = time
                    samples.append(sample)
                }
            }
            return (samples, resumed ? s.info : nil)
        }
    }

    private func pollTick() {
        send(DUMLCommands.rcChannelParamsGet(sender: DUMLDevice.app, sequence: nextSequence()), note: "poll 06/01")
    }

    /// Marks the stream stalled if nothing arrived for a second.
    private func watchdog() {
        let now = ProbeClock.now()
        let stalled = ioState.withLock { s -> AccessoryInfo? in
            guard s.connection != nil, s.streaming, let last = s.lastFrameTime, now - last > 1 else { return nil }
            s.streaming = false
            return s.info
        }
        if let stalled { setState(.connecting(stalled)) }
    }

    // MARK: Any thread

    private func nextSequence() -> UInt16 {
        ioState.withLock { $0.sequence.next() }
    }

    private func send(_ frame: DUMLFrame, note: String) {
        sendDiagnostic(LogicLink.wrap(frame.encoded(), port: LogicLink.Port.duml), note: note, frame: frame)
    }

    private func setState(_ state: RCConnectionState) {
        if stateHub.publish(state, onlyIfChanged: true) { diagnostics?(.state(state)) }
    }
}
#endif
