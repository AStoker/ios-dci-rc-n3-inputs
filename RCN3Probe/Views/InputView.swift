import RCKit
import SwiftUI

/// The dashboard proper: every RC-N3 input as the clean API (`RCInputSample`) reports it.
struct InputView: View {
    @Environment(ProbeModel.self) private var model
    @State private var shareItem: ShareItem?

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                Section {
                    Picker("Engine", selection: $model.engine) {
                        ForEach(ProbeModel.Engine.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(model.engine == .inputAPI
                         ? "RCKit's RCN3Remote, the API the simulator will use. Its raw traffic still shows in Streams and Log."
                         : "The raw probe owns the remote, so the input API is stopped. Use this for DUML experiments.")
                }

                Section("Connection") {
                    if let replay = model.replay {
                        ReplayRows(replay: replay, state: model.inputState)
                    } else {
                        ConnectionRows(state: model.inputState, stats: model.remoteStats)
                    }
                }

                Section("Sticks") {
                    TimelineView(.animation(minimumInterval: 1 / 60)) { _ in
                        SticksBlock(sample: model.currentSample())
                    }
                }

                Section("Controls") {
                    TimelineView(.animation(minimumInterval: 1 / 60)) { _ in
                        ControlsBlock(sample: model.currentSample())
                    }
                }

                Section {
                    Picker("Stick mode", selection: $model.stickMode) {
                        ForEach(RCStickMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TimelineView(.animation(minimumInterval: 1 / 60)) { _ in
                        AxesBlock(axes: model.currentSample().map(model.stickMode.axes))
                    }
                } header: {
                    Text("Flight axes")
                } footer: {
                    Text("RCStickMode maps the physical sticks to throttle, yaw, pitch and roll. Mode 2 is the RC-N3 default.")
                }

                Section {
                    RecordingControls(shareItem: $shareItem)
                } header: {
                    Text("Recording")
                } footer: {
                    Text("Recordings are JSON Lines (one sample per line) in Files › On My iPhone › RC-N3 Probe › Recordings. Replay plays one back through the same API, looping.")
                }
            }
            .navigationTitle("RC-N3 Input")
            .sheet(item: $shareItem) { item in
                ActivityView(items: [item.url])
            }
        }
    }
}

private struct ConnectionRows: View {
    let state: RCConnectionState
    let stats: RCN3Remote.Stats

    var body: some View {
        LabeledContent("Status") {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(state.label).lineLimit(2).multilineTextAlignment(.trailing)
            }
        }
        if let accessory = state.accessory {
            LabeledContent("Remote", value: "\(accessory.manufacturer) \(accessory.modelNumber) · fw \(accessory.firmwareRevision)")
        }
        LabeledContent("Samples", value: Format.rate(stats.sampleRate))
        LabeledContent("Stick poll (06/01)", value: "\(Format.rate(stats.pollReplyRate)) · \(stats.averageLatency.map(Format.ms) ?? "-")")
        LabeledContent("Mode/button push (06/05)", value: Format.rate(stats.pushRate))
        if let version = stats.remoteVersion {
            LabeledContent("Remote reports", value: version)
        }
    }

    private var color: Color {
        switch state {
        case .streaming, .replaying: .green
        case .connecting: .orange
        case .failed: .red
        case .stopped, .waitingForAccessory: .gray
        }
    }
}

private struct ReplayRows: View {
    let replay: RCReplaySource
    let state: RCConnectionState

    var body: some View {
        LabeledContent("Status") {
            HStack(spacing: 6) {
                Circle().fill(state.isStreaming ? Color.green : Color.gray).frame(width: 8, height: 8)
                Text(state.label).lineLimit(2).multilineTextAlignment(.trailing)
            }
        }
        LabeledContent("Recording", value: "\(replay.recording.samples.count) samples · \(String(format: "%.1f s", replay.recording.duration)), looping")
        if let note = replay.recording.header.note {
            LabeledContent("Note", value: note)
        }
        if let accessory = replay.recording.header.accessory {
            LabeledContent("Recorded from", value: "\(accessory.manufacturer) \(accessory.modelNumber) · fw \(accessory.firmwareRevision)")
        }
    }
}

private struct SticksBlock: View {
    let sample: RCInputSample?

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Spacer()
                StickView(title: "Left", x: sample?.leftStick.x ?? 0, y: sample?.leftStick.y ?? 0)
                Spacer()
                StickView(title: "Right", x: sample?.rightStick.x ?? 0, y: sample?.rightStick.y ?? 0)
                Spacer()
            }
            if let sample {
                Text(verbatim: "raw L \(sample.raw.leftX)/\(sample.raw.leftY) · R \(sample.raw.rightX)/\(sample.raw.rightY)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(verbatim: "#\(sample.index) · \(sample.source.rawValue) · \(Format.age(max(0, ProbeClock.now() - sample.time))) ago")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            } else {
                Text("No samples yet").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ControlsBlock: View {
    let sample: RCInputSample?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AxisBar(label: "Gimbal", value: sample?.gimbalDial ?? 0)
            HStack {
                Text("Flight mode").font(.caption).frame(width: 84, alignment: .leading)
                ForEach([RCFlightMode.cine, .normal, .sport], id: \.self) { mode in
                    Chip(text: mode.rawValue, isOn: sample?.flightMode == mode)
                }
                if sample?.flightMode == .unknown {
                    Text("waiting for push").font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("Buttons").font(.caption).frame(width: 84, alignment: .leading)
                Chip(text: "Pause/RTH", isOn: sample?.buttons.contains(.pauseRTH) == true)
                Chip(text: "Shutter", isOn: sample?.buttons.contains(.shutterRecord) == true)
                Chip(text: "Photo/Video", isOn: sample?.buttons.contains(.photoVideo) == true)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct AxesBlock: View {
    let axes: RCStickMode.Axes?

    var body: some View {
        VStack(spacing: 8) {
            AxisBar(label: "Throttle", value: axes?.throttle ?? 0)
            AxisBar(label: "Yaw", value: axes?.yaw ?? 0)
            AxisBar(label: "Pitch", value: axes?.pitch ?? 0)
            AxisBar(label: "Roll", value: axes?.roll ?? 0)
        }
        .padding(.vertical, 4)
    }
}

private struct RecordingControls: View {
    @Environment(ProbeModel.self) private var model
    @Binding var shareItem: ShareItem?

    var body: some View {
        if model.recorder != nil {
            HStack {
                Label("Recording", systemImage: "record.circle").foregroundStyle(.red)
                Spacer()
                Text("\(model.recordingSampleCount) samples · \(String(format: "%.1f s", model.recordingDuration))")
                    .font(.caption.monospacedDigit())
            }
            Button("Stop recording", role: .destructive, action: model.stopRecording)
        } else {
            Button {
                model.startRecording()
            } label: {
                Label("Record samples", systemImage: "record.circle")
            }
            .disabled(!model.canRecord)
            if !model.canRecord {
                Text(model.replay != nil ? "Stop the replay to record." : "Recording needs the Input API engine and a streaming remote.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if let replaying = model.replayingURL {
            HStack {
                Label("Replaying \(replaying.deletingPathExtension().lastPathComponent)", systemImage: "play.circle")
                    .lineLimit(1)
                Spacer()
                Button("Stop", action: model.stopReplay)
            }
        }

        ForEach(model.recordings) { file in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name).font(.callout.monospaced()).lineLimit(1)
                    Text("\(Format.bytes(file.size)) · \(file.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.startReplay(file)
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                Button {
                    shareItem = ShareItem(url: file.url)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

struct AxisBar: View {
    let label: String
    let value: Double

    var body: some View {
        HStack {
            Text(label).font(.caption).frame(width: 84, alignment: .leading)
            GeometryReader { geo in
                let half = geo.size.width / 2
                let length = min(1, abs(value)) * half
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: length)
                        .offset(x: value >= 0 ? half : half - length)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.6))
                        .frame(width: 1)
                        .offset(x: half)
                }
            }
            .frame(height: 8)
            Text(String(format: "%+.2f", value))
                .font(.caption.monospacedDigit())
                .frame(width: 48, alignment: .trailing)
        }
    }
}

private struct Chip: View {
    let text: String
    let isOn: Bool

    var body: some View {
        Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isOn ? Color.accentColor : Color(.tertiarySystemFill), in: Capsule())
            .foregroundStyle(isOn ? Color.white : Color.secondary)
    }
}
