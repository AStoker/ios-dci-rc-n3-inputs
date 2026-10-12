import Foundation
import Observation
import RCKit
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

    // DUML experiment controls
    var sender: UInt8 = DUMLDevice.pc
    var framing: DUMLOutboundFraming = .raw
    /// nil = every open session.
    var targetSessionID: String?
    var pollHz: Double = 20
    var pollEnabled = false {
        didSet { if pollEnabled != oldValue { pollChanged() } }
    }
    var autoOpenSessions = true {
        didSet {
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
    private var pollTask: Task<Void, Never>?
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
        ea.start()
        gc.start()
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
            gc.poll(logDevices: true)
        @unknown default:
            break
        }
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
                         note: "\(request.shortName) [\(framing.label), from \(DUMLDevice.name(sender))]")
        }
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
        let targets = targetSessions
        guard !targets.isEmpty else { return "No open EA session" }
        for session in targets {
            let frame = DUMLFrame(sender: sender, receiver: rx[0], sequence: sequence.next(),
                                  commandType: type[0], commandSet: set[0], commandID: id[0], payload: body)
            session.send(framing.wrap(frame.encoded()), note: "custom \(frame.label) [\(framing.label)]")
        }
        return nil
    }

    func sendRawHex(_ text: String) -> String? {
        guard let bytes = Hex.parse(text), !bytes.isEmpty else { return "Not valid hex" }
        let targets = targetSessions
        guard !targets.isEmpty else { return "No open EA session" }
        for session in targets { session.send(bytes, note: "raw hex (as typed)") }
        return nil
    }

    private func pollChanged() {
        pollTask?.cancel()
        guard pollEnabled else {
            log.log(.duml, "Stick polling stopped")
            return
        }
        log.log(.duml, "Stick polling started at \(Int(pollHz)) Hz (\(framing.label), from \(DUMLDevice.name(sender)))")
        pollTask = Task { [weak self] in
            while !Task.isCancelled, let self, self.pollEnabled {
                self.send(.sticks)
                try? await Task.sleep(for: .seconds(1 / max(1, self.pollHz)))
            }
        }
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
        guard !sweepRunning else { return }
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
                    + "gimbal \(push.gimbal) wheel \(Hex.byte(push.wheelInfo)) btnA \(Hex.byte(push.buttonsA)) btnB \(Hex.byte(push.buttonsB))")
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

    static func age(_ seconds: Double) -> String {
        seconds < 1 ? "\(Int(seconds * 1000)) ms" : String(format: "%.1f s", seconds)
    }
}
