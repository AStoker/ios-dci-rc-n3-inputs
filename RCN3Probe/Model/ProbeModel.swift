import Foundation
import Observation
import RCKit
import RCKitProbe
import SwiftUI
import UIKit

/// App-level state for the probe dashboard.
///
/// `@Observable` is SwiftUI's reactive store: views that read a property re-render when it
/// changes, like a MobX/Vue reactive object. This target defaults to main-actor isolation
/// (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), so everything here runs on the main thread,
/// like UI code in a browser tab. Byte I/O happens on RCKit's own thread; this model only takes
/// snapshots of it about 20 times a second.
@Observable
final class ProbeModel {
    let log: ProbeLog
    let environment: ProbeEnvironment
    let ea: ExternalAccessoryProbe
    let gc: GameControllerProbe
    /// The clean input API (RCKit). The simulator will use exactly this.
    let remote: RCN3Remote
    /// Feeds the remote's raw traffic into the probe's analyzer and log.
    let remoteTap: RemoteDiagnosticsTap

    /// iOS allows one EA session per protocol, so the clean API and the raw probe take turns.
    enum Engine: String, CaseIterable, Identifiable {
        case inputAPI = "Input API"
        case rawProbe = "Raw probe"
        var id: String { rawValue }
    }
    var engine: Engine = .inputAPI {
        didSet { if engine != oldValue { applyEngine() } }
    }

    // Input API state, refreshed by `tick()`
    private(set) var inputState: RCConnectionState = .stopped
    private(set) var remoteStats = RCN3Remote.Stats()
    var stickMode: RCStickMode = .mode2
    private(set) var recorder: RCRecorder?
    private(set) var recordingSampleCount = 0
    private(set) var recordingDuration: Double = 0
    private(set) var recordings: [RecordingFile] = []
    private(set) var replay: RCReplaySource?
    private(set) var replayingURL: URL?

    /// Press counts and last-press times per button, from every sample (so a one-message pulse,
    /// like the Fn button's, is counted even if no frame of the UI shows it).
    static let buttonNames: [(name: String, button: RCButtons)] = [
        ("Pause/RTH", .pauseRTH), ("Shutter", .shutterRecord), ("Photo/Video", .photoVideo), ("Fn", .customizable),
    ]
    private(set) var buttonPresses: [String: Int] = [:]
    private(set) var buttonLastPressed: [String: Double] = [:]
    private var buttonWatch: Task<Void, Never>?

    struct RecordingFile: Identifiable, Hashable {
        let url: URL
        let size: Int
        let date: Date
        var id: URL { url }
        var name: String { url.deletingPathExtension().lastPathComponent }
    }

    // Snapshots, refreshed by `tick()`
    private(set) var accessories: [AccessoryInfo] = []
    private(set) var sessions: [AccessoryStreamSession.Snapshot] = []
    private(set) var devices: [GameControllerProbe.Device] = []
    private(set) var interfaces: [NetworkInterfaceInfo] = []
    private(set) var launchInterfaceIDs: Set<String> = []
    private(set) var logLines: [ProbeLog.Line] = []
    private(set) var logFileURL: URL?
    private(set) var logFileSize = 0
    private(set) var now = ProbeClock.now()

    // DUML experiment controls. Defaults are what the RC-N3 answered in the first hardware test
    // (55 CC envelope, sent as App). Raw/PC got no replies.
    var sender: UInt8 = DUMLDevice.app { didSet { restartPollingIfNeeded() } }
    var framing: DUMLOutboundFraming = .logicLink { didSet { restartPollingIfNeeded() } }
    /// nil = every open session.
    var targetSessionID: String? { didSet { restartPollingIfNeeded() } }
    enum PollMode: String, CaseIterable, Identifiable {
        case fixedRate = "Fixed rate"
        case replyDriven = "As fast as replies"
        var id: String { rawValue }
    }
    var pollMode: PollMode = .fixedRate { didSet { restartPollingIfNeeded() } }
    /// Test 2: the remote refreshes sticks at ~50-60 Hz; 100 Hz polling catches every new value
    /// with ~99% replies, while 200 Hz halves the 06/05 push rate for no gain.
    static let pollRates: [Double] = [25, 50, 100, 200]
    var pollHz: Double = 100 { didSet { restartPollingIfNeeded() } }
    var pollEnabled = false {
        didSet { if pollEnabled != oldValue { pollChanged() } }
    }
    var autoOpenSessions = true {
        didSet {
            guard engine == .rawProbe else { return }
            ea.autoOpenSessions = autoOpenSessions
            if autoOpenSessions { ea.refresh() }
        }
    }
    private(set) var sweepRunning = false
    private(set) var sweepProgress = ""
    private(set) var sweepResults: [SweepResult] = []

    // Log markers
    var markerStep = 1

    private var sequence = DUMLSequence()
    private var refreshTask: Task<Void, Never>?
    private var tickCount = 0
    private var lastShownLineID = -1
    private var started = false

    init() {
        let environment = ProbeEnvironment.current()
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let log = ProbeLog(directory: documents.appendingPathComponent("Logs"))
        self.environment = environment
        self.log = log
        ea = ExternalAccessoryProbe(log: log, declaredProtocols: environment.declaredAccessoryProtocols)
        gc = GameControllerProbe(log: log)
        let tap = RemoteDiagnosticsTap(log: log)
        remoteTap = tap
        remote = RCN3Remote(diagnostics: { tap.handle($0) })
        logFileURL = log.startNewFile(header: Self.logHeader(environment))
    }

    static func logHeader(_ environment: ProbeEnvironment) -> String {
        """
        === RC-N3 Probe log ===
        Started: \(Date().formatted(.iso8601))
        \(environment.summary)
        Times are seconds since the app started. Directions: ← from accessory, → to accessory.
        """
    }

    func start() {
        guard !started else { return }
        started = true
        log.log(.app, "Probe started. \(environment.summary.replacingOccurrences(of: "\n", with: " | "))")
        interfaces = NetworkInterfaces.snapshot()
        launchInterfaceIDs = Set(interfaces.map(\.id))
        log.log(.net, "Network interfaces at launch: " + interfaces.map(\.logDescription).joined(separator: "; "))
        ea.autoOpenSessions = engine == .rawProbe && autoOpenSessions
        ea.start()
        gc.start()
        refreshRecordings()
        watchButtons(of: remote)
        applyEngine()
        // `-replay <recording name>` starts a replay at launch (demo mode without the remote).
        if let name = UserDefaults.standard.string(forKey: "replay"),
           let file = recordings.first(where: { $0.name == name }) {
            startReplay(file)
        }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func tick() {
        now = ProbeClock.now()
        accessories = ea.accessories
        sessions = ea.allSessions.map { $0.snapshot() }
        if engine == .inputAPI { sessions.append(remoteTap.snapshot()) }
        inputState = activeSource.connectionState
        remoteStats = remote.stats
        if let recorder {
            recordingSampleCount = recorder.sampleCount
            recordingDuration = recorder.duration
        }
        // A session that (re)opened while polling is on starts polling too.
        if pollEnabled {
            for session in targetSessions where session.snapshot().poll == nil { session.startPolling(pollConfig) }
        }
        gc.poll()
        devices = gc.devices

        let lastID = log.lastLineID
        if lastID != lastShownLineID {
            lastShownLineID = lastID
            logLines = log.recentLines(400)
        }
        if tickCount % 20 == 0 {
            log.flush()
            logFileSize = log.currentFileSize
            refreshInterfaces()
        }
        tickCount += 1
    }

    private func refreshInterfaces() {
        let fresh = NetworkInterfaces.snapshot()
        let oldIDs = Set(interfaces.map(\.id))
        let newIDs = Set(fresh.map(\.id))
        guard oldIDs != newIDs else { return }
        for added in fresh where !oldIDs.contains(added.id) {
            log.log(.net, "Interface APPEARED: \(added.logDescription)")
        }
        for removed in interfaces where !newIDs.contains(removed.id) {
            log.log(.net, "Interface disappeared: \(removed.logDescription)")
        }
        interfaces = fresh
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        // The first `.active` arrives before `start()`. start() does the initial refresh itself.
        guard started else { return }
        switch phase {
        case .background:
            log.log(.app, "App → background. Closing EA sessions (without the external-accessory "
                + "background mode, iOS doesn't keep them for a suspended app).")
            pollEnabled = false
            ea.closeAll(reason: "app backgrounded")
            log.flush()
        case .inactive:
            log.log(.app, "App → inactive")
        case .active:
            log.log(.app, "App → active")
            ea.refresh()
            if engine == .inputAPI { remote.refresh() }
            gc.poll(logDevices: true)
        @unknown default:
            break
        }
    }

    // MARK: Engine & input API

    private func applyEngine() {
        switch engine {
        case .inputAPI:
            pollEnabled = false
            ea.autoOpenSessions = false
            ea.closeAll(reason: "engine switched to Input API", wait: true)
            log.log(.app, "Engine: Input API (RCN3Remote, 06/01 at \(Int(remote.configuration.pollRate)) Hz)")
            remote.start()
        case .rawProbe:
            stopReplay()
            stopRecording()
            remote.stop()
            log.log(.app, "Engine: raw probe")
            ea.autoOpenSessions = autoOpenSessions
            ea.refresh()
        }
    }

    /// What the Input tab shows: a replay if one is running, otherwise the live remote.
    var activeSource: any RCInputSource {
        if let replay { return replay }
        return remote
    }

    /// Latest sample, read directly (not observed) so the Input tab can redraw at display rate.
    func currentSample() -> RCInputSample? { activeSource.latest }

    private var recordingsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Recordings")
    }

    /// Recording captures the live remote, so it needs the Input API engine streaming (and no replay).
    var canRecord: Bool {
        engine == .inputAPI && replay == nil && inputState.isStreaming
    }

    func startRecording() {
        guard recorder == nil, canRecord else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = recordingsDirectory.appendingPathComponent("rc-n3-\(formatter.string(from: Date())).jsonl")
        do {
            let header = RCRecordingHeader(accessory: remote.connectionState.accessory,
                                           note: "RC-N3 Probe \(environment.appVersion), \(environment.deviceModel)")
            let recorder = try RCRecorder(url: url, header: header)
            recorder.record(from: remote)
            self.recorder = recorder
            recordingSampleCount = 0
            recordingDuration = 0
            log.log(.app, "Recording samples to \(url.lastPathComponent)")
        } catch {
            log.log(.app, "Couldn't start recording: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        guard let recorder else { return }
        recorder.stop()
        log.log(.app, "Recording stopped: \(recorder.sampleCount) samples, \(String(format: "%.1f", recorder.duration)) s")
        self.recorder = nil
        refreshRecordings()
    }

    func refreshRecordings() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: recordingsDirectory, includingPropertiesForKeys: keys)) ?? []
        recordings = urls.filter { $0.pathExtension == "jsonl" }.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return RecordingFile(url: url, size: values?.fileSize ?? 0, date: values?.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.date > $1.date }
    }

    func startReplay(_ file: RecordingFile) {
        stopReplay()
        do {
            let replay = try RCReplaySource(url: file.url, loops: true)
            self.replay = replay
            replayingURL = file.url
            watchButtons(of: replay)
            replay.start()
            log.log(.app, "Replaying \(file.name): \(replay.recording.samples.count) samples, \(String(format: "%.1f", replay.recording.duration)) s, looping")
        } catch {
            log.log(.app, "Couldn't load \(file.name): \(error)")
        }
    }

    func stopReplay() {
        guard let replay else { return }
        replay.stop()
        self.replay = nil
        replayingURL = nil
        watchButtons(of: remote)
        log.log(.app, "Replay stopped")
    }

    private func watchButtons(of source: any RCInputSource) {
        buttonWatch?.cancel()
        let stream = source.samples()
        buttonWatch = Task { [weak self] in
            var held: RCButtons = []
            for await sample in stream {
                let pressed = sample.buttons.subtracting(held)
                held = sample.buttons
                if !pressed.isEmpty { self?.notePresses(pressed, at: sample.time) }
            }
        }
    }

    private func notePresses(_ pressed: RCButtons, at time: Double) {
        for (name, button) in Self.buttonNames where pressed.contains(button) {
            buttonPresses[name, default: 0] += 1
            buttonLastPressed[name] = time
            log.log(.app, "Button press: \(name) (#\(buttonPresses[name]!))")
        }
    }

    func resetButtonCounts() {
        buttonPresses = [:]
        buttonLastPressed = [:]
    }

    // MARK: Sessions

    func session(id: String) -> AccessoryStreamSession.Snapshot? {
        sessions.first { $0.id == id }
    }

    var liveSessionCount: Int { sessions.filter { $0.state == .open }.count }

    var totalDumlFrames: Int { sessions.reduce(0) { $0 + $1.analyzer.dumlFramesIn } }

    var lastPacketAge: Double? {
        let last = sessions.compactMap(\.analyzer.lastInTime).max()
        return last.map { now - $0 }
    }

    func toggleSession(accessoryID: Int, protocolString: String) {
        let id = "\(accessoryID)|\(protocolString)"
        if let existing = ea.sessions[id], existing.state.isLive {
            ea.closeSession(id: id)
        } else {
            ea.openSession(accessoryID: accessoryID, protocolString: protocolString)
        }
    }

    func resetDiffs(sessionID: String) {
        ea.sessions[sessionID]?.resetDiffBaselines()
        log.log(.app, "Diff baselines reset for \(sessionID)")
    }

    // MARK: DUML sending

    enum Request: String, CaseIterable, Identifiable {
        case version, simulatorMode, sticks, rcParams
        var id: String { rawValue }

        var title: String {
            switch self {
            case .version: "Version ping (00/01)"
            case .simulatorMode: "Enable simulator mode (06/24 01)"
            case .sticks: "Request sticks (06/01)"
            case .rcParams: "Request RC params (06/05)"
            }
        }

        var shortName: String {
            switch self {
            case .version: "00/01 version"
            case .simulatorMode: "06/24 sim-mode on"
            case .sticks: "06/01 sticks"
            case .rcParams: "06/05 params"
            }
        }

        func frame(sender: UInt8, sequence: UInt16) -> DUMLFrame {
            switch self {
            case .version: DUMLCommands.versionInquiry(sender: sender, sequence: sequence)
            case .simulatorMode: DUMLCommands.rcSimulatorMode(true, sender: sender, sequence: sequence)
            case .sticks: DUMLCommands.rcChannelParamsGet(sender: sender, sequence: sequence)
            case .rcParams: DUMLCommands.rcParameterGet(sender: sender, sequence: sequence)
            }
        }
    }

    private var targetSessions: [AccessoryStreamSession] {
        let live = ea.liveSessions
        guard let targetSessionID else { return live }
        return live.filter { $0.id == targetSessionID }
    }

    func send(_ request: Request) {
        if engine == .inputAPI {
            let frame = request.frame(sender: sender, sequence: sequence.next())
            remote.sendDiagnostic(framing.wrap(frame.encoded()),
                                  note: "\(request.shortName) [\(framing.label), from \(DUMLDevice.name(sender))]", frame: frame)
            return
        }
        send(request, sender: sender, framing: framing, to: targetSessions)
    }

    private func send(_ request: Request, sender: UInt8, framing: DUMLOutboundFraming, to targets: [AccessoryStreamSession]) {
        guard !targets.isEmpty else {
            log.log(.duml, "Not sent (\(request.shortName)): no open EA session")
            return
        }
        for session in targets {
            let frame = request.frame(sender: sender, sequence: sequence.next())
            session.send(framing.wrap(frame.encoded()),
                         note: "\(request.shortName) [\(framing.label), from \(DUMLDevice.name(sender))]",
                         frame: frame)
        }
    }

    /// Latest reply stats for a request on the first targeted session that has sent it.
    func replyStats(for request: Request) -> StreamAnalyzer.ReplyStats? {
        let frame = request.frame(sender: sender, sequence: 0)
        let key = UInt16(frame.commandSet) << 8 | UInt16(frame.commandID)
        let candidates = sessions.filter { targetSessionID == nil || $0.id == targetSessionID }
        return candidates.compactMap { $0.analyzer.replyStats[key] }.first { $0.sent > 0 }
    }

    /// Builds a DUML frame from hex fields and sends it. Returns an error message, or nil on success.
    func sendCustom(receiver: String, commandType: String, commandSet: String, commandID: String, payload: String) -> String? {
        guard let rx = Hex.parse(receiver), rx.count == 1,
              let type = Hex.parse(commandType), type.count == 1,
              let set = Hex.parse(commandSet), set.count == 1,
              let id = Hex.parse(commandID), id.count == 1
        else { return "Receiver, type, set and id must each be one hex byte" }
        guard let body = Hex.parse(payload) else { return "Payload isn't valid hex" }
        guard DUMLFrame.minimumLength + body.count <= DUMLFrame.maximumLength else { return "Payload too long" }
        if engine == .inputAPI {
            let frame = DUMLFrame(sender: sender, receiver: rx[0], sequence: sequence.next(),
                                  commandType: type[0], commandSet: set[0], commandID: id[0], payload: body)
            remote.sendDiagnostic(framing.wrap(frame.encoded()), note: "custom \(frame.label) [\(framing.label)]", frame: frame)
            return nil
        }
        let targets = targetSessions
        guard !targets.isEmpty else { return "No open EA session" }
        for session in targets {
            let frame = DUMLFrame(sender: sender, receiver: rx[0], sequence: sequence.next(),
                                  commandType: type[0], commandSet: set[0], commandID: id[0], payload: body)
            session.send(framing.wrap(frame.encoded()), note: "custom \(frame.label) [\(framing.label)]", frame: frame)
        }
        return nil
    }

    func sendRawHex(_ text: String) -> String? {
        guard let bytes = Hex.parse(text), !bytes.isEmpty else { return "Not valid hex" }
        if engine == .inputAPI {
            remote.sendDiagnostic(bytes, note: "raw hex (as typed)")
            return nil
        }
        let targets = targetSessions
        guard !targets.isEmpty else { return "No open EA session" }
        for session in targets { session.send(bytes, note: "raw hex (as typed)") }
        return nil
    }

    private var pollConfig: AccessoryStreamSession.PollConfig {
        AccessoryStreamSession.PollConfig(
            mode: pollMode == .replyDriven ? .replyDriven : .fixedRate(pollHz),
            framing: framing, sender: sender)
    }

    /// Polling runs on the I/O thread inside each session; the model just starts and stops it.
    private func pollChanged() {
        for session in ea.liveSessions { session.stopPolling() }
        guard pollEnabled, engine == .rawProbe else { return }
        let targets = targetSessions
        if targets.isEmpty { log.log(.duml, "Polling not started: no open EA session") }
        for session in targets { session.startPolling(pollConfig) }
    }

    private func restartPollingIfNeeded() {
        if pollEnabled { pollChanged() }
    }

    /// Poll stats (06/01) for the first targeted session that is polling.
    var pollStats: (stats: StreamAnalyzer.ReplyStats?, timeouts: Int)? {
        guard let session = sessions.first(where: { $0.poll != nil }) else { return nil }
        return (session.analyzer.replyStats[0x0601], session.pollTimeouts)
    }

    // MARK: Sweep

    struct SweepResult: Identifiable {
        let id = UUID()
        let protocolString: String
        let framing: DUMLOutboundFraming
        let sender: UInt8
        let bytesIn: Int
        /// Frame types whose count went up during this variant: label → delta.
        let frameDeltas: [(label: String, delta: Int, isResponse: Bool, receiver: UInt8)]

        var repliesToSender: Int {
            frameDeltas.filter { $0.isResponse && $0.receiver == sender }.reduce(0) { $0 + $1.delta }
        }

        var summary: String {
            let frames = frameDeltas.isEmpty ? "no DUML frames"
                : frameDeltas.map { "\($0.label) +\($0.delta)" }.joined(separator: ", ")
            return "\(protocolString) | \(framing.label) | from \(DUMLDevice.name(sender)): "
                + "+\(bytesIn) B in, replies to us: \(repliesToSender); \(frames)"
        }
    }

    /// Tries every framing × sender combination on every open session and records what comes back.
    func runSweep() async {
        guard !sweepRunning, engine == .rawProbe else { return }
        let sessions = ea.liveSessions
        guard !sessions.isEmpty else {
            log.log(.duml, "Sweep not run: no open EA session")
            return
        }
        sweepRunning = true
        sweepResults = []
        let wasPolling = pollEnabled
        pollEnabled = false
        log.log(.duml, "=== SWEEP START: \(sessions.count) session(s) × \(DUMLOutboundFraming.allCases.count) framings × 2 senders ===")

        for session in sessions {
            for framing in DUMLOutboundFraming.allCases {
                for sender in [DUMLDevice.pc, DUMLDevice.app] {
                    sweepProgress = "\(session.protocolString) · \(framing.label) · \(DUMLDevice.name(sender))"
                    log.log(.duml, "SWEEP variant: \(sweepProgress)")
                    let before = session.snapshot().analyzer
                    for request in Request.allCases {
                        send(request, sender: sender, framing: framing, to: [session])
                        try? await Task.sleep(for: .milliseconds(80))
                    }
                    try? await Task.sleep(for: .milliseconds(700))
                    let after = session.snapshot().analyzer
                    let deltas = after.frameTypes.values.compactMap { type -> (String, Int, Bool, UInt8)? in
                        let delta = type.count - (before.frameTypes[type.id]?.count ?? 0)
                        return delta > 0 ? (type.label, delta, type.isResponse, type.receiver) : nil
                    }
                    .sorted { $0.0 < $1.0 }
                    let result = SweepResult(protocolString: session.protocolString, framing: framing, sender: sender,
                                             bytesIn: after.bytesIn - before.bytesIn,
                                             frameDeltas: deltas.map { ($0.0, $0.1, $0.2, $0.3) })
                    sweepResults.append(result)
                    log.log(.duml, "SWEEP result: \(result.summary)")
                }
            }
        }

        log.log(.duml, "=== SWEEP END ===")
        sweepProgress = ""
        sweepRunning = false
        pollEnabled = wasPolling
    }

    // MARK: Log & export

    func addMarker(_ note: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        log.log(.mark, "──── STEP \(markerStep)\(trimmed.isEmpty ? "" : ": \(trimmed)") ────")
        markerStep += 1
    }

    func startNewLogFile() {
        logFileURL = log.startNewFile(header: Self.logHeader(environment))
        log.log(.app, "Started new log file \(logFileURL?.lastPathComponent ?? "(none)")")
    }

    /// Flushes the log so the file on disk is complete, then returns its URL for sharing.
    func prepareLogForSharing() -> URL? {
        log.log(.app, "Log exported")
        log.flush()
        logFileSize = log.currentFileSize
        return logFileURL
    }

    func copyReportToClipboard() {
        UIPasteboard.general.string = makeReport()
        log.log(.app, "Report copied to clipboard")
    }

    func makeReport(logLineCount: Int = 300) -> String {
        var out: [String] = []
        out.append("=== RC-N3 Probe report \(Date().formatted(.iso8601)) ===")
        out.append(environment.summary)
        out.append("Log file: \(logFileURL?.lastPathComponent ?? "(none)")")

        out.append("\n--- Input API (engine: \(engine.rawValue))")
        out.append("state: \(inputState.label)")
        out.append("samples \(Format.rate(remoteStats.sampleRate)), poll replies \(Format.rate(remoteStats.pollReplyRate)), "
            + "push \(Format.rate(remoteStats.pushRate)), latency \(remoteStats.averageLatency.map(Format.ms) ?? "-"), "
            + "frames \(remoteStats.framesReceived), remote \(remoteStats.remoteVersion ?? "?")")
        if let sample = currentSample() {
            out.append("latest: L(\(String(format: "%+.3f, %+.3f", sample.leftStick.x, sample.leftStick.y))) "
                + "R(\(String(format: "%+.3f, %+.3f", sample.rightStick.x, sample.rightStick.y))) "
                + "gimbal \(String(format: "%+.3f", sample.gimbalDial)) mode \(sample.flightMode.rawValue) "
                + "buttons \(sample.buttons.rawValue) source \(sample.source.rawValue) raw \(sample.raw)")
        }

        out.append("\n--- External Accessories (\(accessories.count))")
        if accessories.isEmpty { out.append("(none visible to this app)") }
        for accessory in accessories { out.append(accessory.logDescription) }

        out.append("\n--- EA sessions (\(sessions.count))")
        for s in sessions {
            let a = s.analyzer
            out.append("[\(s.protocolString)] accessory \(s.accessoryID): \(s.state.label); "
                + "input open \(s.inputOpen), output open \(s.outputOpen)")
            out.append("  " + a.statsLine())
            if let last = a.lastInTime { out.append("  last packet \(Format.age(now - last)) ago") }
            if let version = a.versionInfo { out.append("  VERSION \(version)") }
            if let poll = s.poll { out.append("  polling \(poll.mode) \(poll.framing.label) from \(DUMLDevice.name(poll.sender)); timeouts \(s.pollTimeouts)") }
            for stats in a.replyStats.values.sorted(by: { $0.label < $1.label }) {
                out.append("  replies \(stats.label): \(stats.replies)/\(stats.sent) sent, \(Format.rate(stats.replyRate)), "
                    + "last status \(stats.lastStatus.map(Hex.byte) ?? "-"), "
                    + "latency avg \(stats.averageLatency.map(Format.ms) ?? "-") p95 \(stats.p95Latency.map(Format.ms) ?? "-")")
            }
            if let battery = a.latestBattery?.info { out.append("  battery (06/1e): \(battery.percent)% remaining \(battery.remaining)") }
            if let median = a.medianChannelChangeInterval {
                out.append("  06/01 fresh values \(Format.rate(a.freshChannelRate)), median change interval \(Format.ms(median))")
            }
            for port in a.ports.values.sorted(by: { $0.port < $1.port }) {
                out.append("  55CC \(LogicLink.Port.name(port.port)): \(port.packets) pkts, \(port.bytes) B, head \(Hex.string(port.lastHead))")
            }
            for type in a.frameTypes.values.sorted(by: { $0.count > $1.count }) {
                out.append("  DUML \(type.label) (\(type.name)) ×\(type.count) @\(Format.rate(type.rate)) "
                    + "payload len \(type.payloadLengths.sorted().map(String.init).joined(separator: "/")) "
                    + "changed bytes \(type.diff.changedPositions.map(String.init).joined(separator: ","))")
                out.append("    last: \(Hex.string(type.lastRaw, limit: 96))")
            }
            if let report = a.latestChannels?.report {
                out.append("  06/01 decode: status \(report.status) " + report.channels.enumerated().map {
                    "ch\($0.offset)[tag \(Hex.byte($0.element.tag))]=\($0.element.raw)"
                }.joined(separator: " "))
            }
            if let push = a.latestPush?.params {
                out.append("  06/05 decode: ail \(push.aileron) ele \(push.elevator) thr \(push.throttle) rud \(push.rudder) "
                    + "gimbal \(push.gimbal) wheel \(Hex.byte(push.wheelInfo)) btnA \(Hex.byte(push.buttonsA)) btnB \(Hex.byte(push.buttonsB)) "
                    + "mode \(push.flightMode.rawValue) RTH \(push.goHomePressed) shutter \(push.shutter) photo/video \(push.photoVideo) B10 \(push.custom1)")
            }
            for (length, diff) in a.rawDiffs.sorted(by: { $0.key < $1.key }) where diff.packetCount > 1 {
                out.append("  raw chunks len \(length): ×\(diff.packetCount), changed bytes \(diff.changedPositions.map(String.init).joined(separator: ","))")
            }
        }

        if !sweepResults.isEmpty {
            out.append("\n--- Sweep results")
            for result in sweepResults { out.append(result.summary) }
        }

        out.append("\n--- GameController (\(devices.count))")
        if devices.isEmpty { out.append("(no controllers, keyboards or mice)") }
        for device in devices {
            out.append("\(device.kind.rawValue): vendor \"\(device.vendorName)\" category \"\(device.productCategory)\" \(device.details.joined(separator: " "))")
            for element in device.elements { out.append("  \(element.id) [\(element.kind.rawValue)] = \(element.display)") }
        }

        out.append("\n--- Network interfaces (+ = appeared after launch)")
        for interface in interfaces {
            out.append("\(launchInterfaceIDs.contains(interface.id) ? " " : "+") \(interface.logDescription)")
        }

        out.append("\n--- Last \(logLineCount) log lines")
        out += log.recentLines(logLineCount).map(\.formatted)
        return out.joined(separator: "\n")
    }
}

/// Small display formatters.
enum Format {
    static func rate(_ value: Double) -> String {
        value >= 10 ? "\(Int(value.rounded()))/s" : String(format: "%.1f/s", value)
    }

    static func bytes(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
    }

    static func byteRate(_ value: Double) -> String {
        bytes(Int(value)) + "/s"
    }

    static func ms(_ seconds: Double) -> String {
        String(format: "%.1f ms", seconds * 1000)
    }

    static func age(_ seconds: Double) -> String {
        seconds < 1 ? "\(Int(seconds * 1000)) ms" : String(format: "%.1f s", seconds)
    }
}
