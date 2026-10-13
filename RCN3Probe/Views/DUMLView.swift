import RCKit
import RCKitProbe
import SwiftUI

/// Send DUML requests (stick poll, simulator mode, version ping), run the framing/sender sweep and
/// view decoded stick values.
struct DUMLView: View {
    @Environment(ProbeModel.self) private var model
    @State private var customReceiver = "06"
    @State private var customType = "40"
    @State private var customSet = "06"
    @State private var customID = "01"
    @State private var customPayload = ""
    // 06/01 from App, in a 55 CC envelope (the form the RC-N3 answered).
    @State private var rawHex = "55 cc 49 57 0d 00 00 00 55 0d 04 33 02 06 f9 34 40 06 01 50 58"
    @State private var message: String?

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    if model.engine == .inputAPI {
                        Text("Engine: Input API. Requests go through RCN3Remote.sendDiagnostic.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Session", selection: $model.targetSessionID) {
                        Text("All open sessions").tag(String?.none)
                        ForEach(model.sessions.filter { $0.state == .open }) { session in
                            Text(session.protocolString).tag(String?.some(session.id))
                        }
                    }
                    Picker("Framing", selection: $model.framing) {
                        ForEach(DUMLOutboundFraming.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Send as", selection: $model.sender) {
                        Text("PC (0x0A)").tag(DUMLDevice.pc)
                        Text("App (0x02)").tag(DUMLDevice.app)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Target")
                } footer: {
                    Text("Defaults are what the RC-N3 answered: 55 CC envelope, sent as App. Raw DUML or PC got no replies in the first test.")
                }

                Section {
                    ForEach(ProbeModel.Request.allCases) { request in
                        VStack(alignment: .leading, spacing: 2) {
                            Button(request.title) { model.send(request) }
                            ReplyLine(stats: model.replyStats(for: request), now: model.now)
                        }
                    }
                } header: {
                    Text("Requests")
                } footer: {
                    Text("Each button sends one request. The line under it shows the remote's reply (status 00 = OK) and round-trip time. 06/05 is pushed by the remote rather than requested, so it shows no reply.")
                }

                Section {
                    if model.engine == .inputAPI {
                        Text("The Input API polls 06/01 at \(Int(model.remote.configuration.pollRate)) Hz by itself (rates on the Input tab). Switch the engine to Raw probe for poll experiments.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                    Toggle("Poll sticks (06/01)", isOn: $model.pollEnabled)
                    Picker("Mode", selection: $model.pollMode) {
                        ForEach(ProbeModel.PollMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if model.pollMode == .fixedRate {
                        Picker("Rate", selection: $model.pollHz) {
                            ForEach(ProbeModel.pollRates, id: \.self) { Text("\(Int($0)) Hz").tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    if let poll = model.pollStats {
                        let stats = poll.stats
                        LabeledContent("Replies", value: stats.map { "\(Format.rate($0.replyRate)) · \($0.replies)/\($0.sent)" } ?? "none yet")
                        LabeledContent("Latency avg / p95", value: "\(stats?.averageLatency.map(Format.ms) ?? "-") / \(stats?.p95Latency.map(Format.ms) ?? "-")")
                        if model.pollMode == .replyDriven {
                            LabeledContent("Timeouts (no reply in 250 ms)", value: "\(poll.timeouts)")
                        }
                        if let analyzer = model.sessions.first(where: { $0.poll != nil })?.analyzer {
                            LabeledContent("Fresh values (move a stick)", value: Format.rate(analyzer.freshChannelRate))
                            LabeledContent("Median time between new values",
                                           value: analyzer.medianChannelChangeInterval.map(Format.ms) ?? "move a stick fast")
                        }
                    }
                    }
                } header: {
                    Text("Stick polling")
                } footer: {
                    Text("Runs on the I/O thread. \"As fast as replies\" sends the next request the moment a reply arrives, which shows the most the remote can sustain.")
                }

                Section {
                    Button {
                        Task { await model.runSweep() }
                    } label: {
                        HStack {
                            Text(model.sweepRunning ? "Sweeping…" : "Run sweep")
                            if model.sweepRunning { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(model.sweepRunning || model.liveSessionCount == 0 || model.engine != .rawProbe)
                    if model.sweepRunning {
                        Text(model.sweepProgress).font(.caption.monospaced())
                    }
                    ForEach(model.sweepResults) { result in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("\(result.protocolString) · \(result.framing.label) · \(DUMLDevice.name(result.sender))")
                                    .font(.caption.bold())
                                Spacer()
                                Text(result.repliesToSender > 0 ? "\(result.repliesToSender) replies" : "no reply")
                                    .font(.caption.bold())
                                    .foregroundStyle(result.repliesToSender > 0 ? .green : .secondary)
                            }
                            Text("+\(result.bytesIn) B in" + (result.frameDeltas.isEmpty ? "" : " · " + result.frameDeltas.map { "\($0.label) +\($0.delta)" }.joined(separator: ", ")))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Sweep")
                } footer: {
                    Text("On each open session, tries both framings × both senders. Each variant sends version, simulator mode, stick and params requests, then waits 0.7 s for replies.")
                }

                ForEach(model.sessions.filter { $0.analyzer.latestChannels != nil || $0.analyzer.latestPush != nil }) { session in
                    DecodedSection(session: session, now: model.now)
                }

                Section {
                    HexField(label: "Receiver", text: $customReceiver)
                    HexField(label: "Cmd type", text: $customType)
                    HexField(label: "Cmd set", text: $customSet)
                    HexField(label: "Cmd id", text: $customID)
                    HexField(label: "Payload", text: $customPayload)
                    Button("Send custom DUML") {
                        message = model.sendCustom(receiver: customReceiver, commandType: customType, commandSet: customSet,
                                                   commandID: customID, payload: customPayload) ?? "Sent"
                    }
                } header: {
                    Text("Custom DUML frame")
                } footer: {
                    Text("Sender, sequence number and both CRCs are filled in. Uses the framing and session above. Only send commands from the notes or chat: some DUML commands change settings or firmware state.")
                }

                Section {
                    TextField("hex bytes", text: $rawHex, axis: .vertical)
                        .font(.callout.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Send raw bytes") { message = model.sendRawHex(rawHex) ?? "Sent" }
                } header: {
                    Text("Raw bytes (sent exactly as typed)")
                }
            }
            .navigationTitle("DUML")
            .alert(message ?? "", isPresented: Binding(get: { message != nil && message != "Sent" }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            }
        }
    }
}

private struct HexField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        LabeledContent(label) {
            TextField("hex", text: $text)
                .font(.body.monospaced())
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }
}

/// Decoded stick values for one session. Every mapping here is a HYPOTHESIS taken from RC-N1 tools.
private struct DecodedSection: View {
    let session: AccessoryStreamSession.Snapshot
    let now: Double

    var body: some View {
        Section {
            if let latest = session.analyzer.latestChannels {
                let ch = latest.report.channels
                Text("06/01 reply, \(Format.age(now - latest.time)) ago, status \(latest.report.status)")
                    .font(.caption).foregroundStyle(.secondary)
                if ch.count >= 4 {
                    HStack {
                        Spacer()
                        StickView(title: "Left (ch3 X, ch2 Y)", x: ch[3].normalized, y: ch[2].normalized)
                        Spacer()
                        StickView(title: "Right (ch0 X, ch1 Y)", x: ch[0].normalized, y: ch[1].normalized)
                        Spacer()
                    }
                }
                ForEach(Array(ch.enumerated()), id: \.offset) { index, channel in
                    HStack {
                        Text("ch\(index) · \(latest.report.label(for: index))").font(.caption)
                        Spacer()
                        Text(verbatim: "tag \(Hex.byte(channel.tag))  \(channel.raw)  \(String(format: "%+.3f", channel.normalized))")
                            .font(.caption.monospaced())
                    }
                }
            }
            if let latest = session.analyzer.latestPush {
                let p = latest.params
                let pushRate = session.analyzer.frameTypes.values.first { $0.commandSet == 0x06 && $0.commandID == 0x05 }?.rate ?? 0
                Text("06/05 push · \(Format.rate(pushRate)) · \(Format.age(now - latest.time)) ago").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    StickView(title: "Left (rudder, throttle)", x: RCStickRange.normalized(p.rudder), y: RCStickRange.normalized(p.throttle))
                    Spacer()
                    StickView(title: "Right (aileron, elevator)", x: RCStickRange.normalized(p.aileron), y: RCStickRange.normalized(p.elevator))
                    Spacer()
                }
                Group {
                    LabeledContent("Raw A/E/T/R", value: "\(p.aileron) / \(p.elevator) / \(p.throttle) / \(p.rudder)")
                    LabeledContent("Gimbal dial", value: "\(p.gimbal)  \(String(format: "%+.2f", RCStickRange.normalized(p.gimbal)))")
                    LabeledContent("Flight mode switch", value: "\(p.flightMode.rawValue) (raw \(p.modeSwitch))")
                    ButtonRow(name: "Pause/RTH", isOn: p.goHomePressed)
                    ButtonRow(name: "Shutter/Record", isOn: p.shutter)
                    ButtonRow(name: "Photo/Video", isOn: p.photoVideo)
                    ButtonRow(name: "B 0x10 (unknown, seen once in test 1)", isOn: p.custom1)
                    LabeledContent("Flag bytes", value: "A \(bits(p.buttonsA))  B \(bits(p.buttonsB))  wheel \(Hex.byte(p.wheelInfo))")
                }
                .font(.caption.monospaced())
            }
            if let battery = session.analyzer.latestBattery?.info {
                LabeledContent("Remote battery (06/1e)", value: "\(battery.percent)%")
                    .font(.caption.monospaced())
            }
        } header: {
            Text("Decoded · \(session.protocolString)")
        } footer: {
            Text("HYPOTHESIS: layouts and scaling come from tools for older DJI remotes. Check them against the raw bytes.")
        }
    }
}

struct StickView: View {
    let title: String
    let x: Double
    let y: Double

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let radius = min(geo.size.width, geo.size.height) / 2 - 10
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(Color(.tertiarySystemFill))
                    Path { path in
                        path.move(to: CGPoint(x: geo.size.width / 2, y: 6))
                        path.addLine(to: CGPoint(x: geo.size.width / 2, y: geo.size.height - 6))
                        path.move(to: CGPoint(x: 6, y: geo.size.height / 2))
                        path.addLine(to: CGPoint(x: geo.size.width - 6, y: geo.size.height / 2))
                    }
                    .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 18, height: 18)
                        .offset(x: x * radius, y: -y * radius)
                }
            }
            .frame(width: 120, height: 120)
            Text(title).font(.caption2)
            Text(String(format: "x %+.2f  y %+.2f", x, y)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

private func bits(_ value: UInt8) -> String {
    let binary = String(value, radix: 2)
    return String(repeating: "0", count: 8 - binary.count) + binary
}

private struct ButtonRow: View {
    let name: String
    let isOn: Bool

    var body: some View {
        HStack {
            Text(name)
            Spacer()
            Text(isOn ? "PRESSED" : "—")
                .bold(isOn)
                .foregroundStyle(isOn ? .orange : .secondary)
        }
    }
}

private struct ReplyLine: View {
    let stats: StreamAnalyzer.ReplyStats?
    let now: Double

    var body: some View {
        Group {
            if let stats, let time = stats.lastReplyTime {
                Text("reply status \(stats.lastStatus.map(Hex.byte) ?? "-") · \(stats.lastLatency.map(Format.ms) ?? "-") · "
                    + "\(Format.age(now - time)) ago · \(stats.replies)/\(stats.sent)")
                    .foregroundStyle(.green)
            } else if let stats {
                Text("sent \(stats.sent)×, no reply").foregroundStyle(.secondary)
            } else {
                Text("not sent yet").foregroundStyle(.tertiary)
            }
        }
        .font(.caption2.monospaced())
    }
}
