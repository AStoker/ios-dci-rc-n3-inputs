import RCKit
import SwiftUI

/// Every EA session: rates, DUML frame types, raw hex.
struct StreamsView: View {
    @Environment(ProbeModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                if model.sessions.isEmpty {
                    ContentUnavailableView("No EA sessions",
                                           systemImage: "cable.connector.slash",
                                           description: Text("Sessions appear here when an accessory advertises a declared protocol."))
                }
                ForEach(model.sessions) { session in
                    NavigationLink(value: session.id) {
                        SessionRow(session: session, now: model.now)
                    }
                }
            }
            .navigationTitle("Streams")
            .navigationDestination(for: String.self) { id in
                SessionDetailView(sessionID: id)
            }
        }
    }
}

private struct SessionRow: View {
    let session: AccessoryStreamSession.Snapshot
    let now: Double

    var body: some View {
        let a = session.analyzer
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(session.state == .open ? .green : .gray).frame(width: 8, height: 8)
                Text(session.protocolString).font(.headline.monospaced())
            }
            Text(session.state.label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Label(Format.byteRate(a.byteRate), systemImage: "arrow.down")
                Label(Format.rate(a.chunkRate), systemImage: "square.stack")
                Label("DUML \(Format.rate(a.dumlRate))", systemImage: "shippingbox")
            }
            .font(.caption.monospacedDigit())
            if let last = a.lastInTime {
                Text("last packet \(Format.age(now - last)) ago").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct SessionDetailView: View {
    @Environment(ProbeModel.self) private var model
    let sessionID: String
    @State private var paused = false
    @State private var frozenChunks: [StreamAnalyzer.Chunk] = []

    var body: some View {
        if let session = model.session(id: sessionID) {
            let a = session.analyzer
            List {
                Section("Session") {
                    LabeledContent("State", value: session.state.label)
                    LabeledContent("Streams", value: "in \(session.inputOpen ? "open" : "closed") · out \(session.outputOpen ? "open" : "closed")")
                    LabeledContent("Received", value: "\(Format.bytes(a.bytesIn)) in \(a.chunksIn) chunks")
                    LabeledContent("Rate", value: "\(Format.byteRate(a.byteRate)) · \(Format.rate(a.chunkRate)) chunks")
                    LabeledContent("Last packet", value: a.lastInTime.map { Format.age(model.now - $0) + " ago" } ?? "never")
                    LabeledContent("Sent", value: "\(Format.bytes(a.bytesOut)) in \(a.writesOut) writes")
                    if session.pendingWriteBytes > 0 {
                        LabeledContent("Waiting to write", value: Format.bytes(session.pendingWriteBytes))
                    }
                    LabeledContent("DUML frames", value: "\(a.dumlFramesIn) · \(Format.rate(a.dumlRate))")
                    LabeledContent("Zero padding", value: Format.bytes(a.paddingBytes))
                    LabeledContent("Unparsed bytes", value: Format.bytes(a.skippedBytes))
                    if let version = a.versionInfo { LabeledContent("Version reply", value: version) }
                }

                if !a.ports.isEmpty {
                    Section("55 CC envelope ports") {
                        ForEach(a.ports.values.sorted { $0.port < $1.port }) { port in
                            VStack(alignment: .leading) {
                                Text("\(LogicLink.Port.name(port.port)) · \(port.packets) pkts · \(Format.bytes(port.bytes))")
                                Text(Hex.string(port.lastHead)).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    if a.frameTypes.isEmpty {
                        Text("No valid DUML frames yet.").foregroundStyle(.secondary)
                    }
                    ForEach(a.frameTypes.values.sorted { $0.count > $1.count }) { type in
                        NavigationLink {
                            ByteDiffView(sessionID: sessionID, source: .frame(type.id))
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(type.label).font(.callout.monospaced())
                                Text("\(type.name) · ×\(type.count) · \(Format.rate(type.rate)) · payload \(type.payloadLengths.sorted().map(String.init).joined(separator: "/")) B")
                                    .font(.caption).foregroundStyle(.secondary)
                                if !type.diff.changedPositions.isEmpty {
                                    Text("changing bytes: \(type.diff.changedPositions.map(String.init).joined(separator: ", "))")
                                        .font(.caption2.monospaced()).foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                } header: {
                    Text("DUML frame types")
                } footer: {
                    Text("Open a frame type to see which payload bytes change while you move a control.")
                }

                let rawDiffs = a.rawDiffs.filter { $0.value.packetCount > 1 }.sorted { $0.key < $1.key }
                if !rawDiffs.isEmpty {
                    Section("Raw chunks by length (non-DUML view)") {
                        ForEach(rawDiffs, id: \.key) { length, diff in
                            NavigationLink {
                                ByteDiffView(sessionID: sessionID, source: .raw(length))
                            } label: {
                                Text("\(length) B · ×\(diff.packetCount) · \(diff.changedPositions.count) changing")
                                    .font(.callout.monospacedDigit())
                            }
                        }
                    }
                }

                Section {
                    Toggle("Pause", isOn: $paused)
                        .onChange(of: paused) { _, isPaused in
                            frozenChunks = isPaused ? a.recentChunks : []
                        }
                    ForEach((paused ? frozenChunks : a.recentChunks).suffix(40).reversed()) { chunk in
                        HexChunkRow(chunk: chunk, openedAt: session.openedAt)
                    }
                } header: {
                    Text("Live hex (newest first)")
                }

                Section {
                    Button("Reset changed-byte baselines") { model.resetDiffs(sessionID: sessionID) }
                    if session.state.isLive {
                        Button("Close session", role: .destructive) { model.ea.closeSession(id: sessionID) }
                    }
                }
            }
            .navigationTitle(session.protocolString)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Session gone", systemImage: "xmark.circle")
        }
    }
}

private struct HexChunkRow: View {
    let chunk: StreamAnalyzer.Chunk
    let openedAt: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(chunk.direction.rawValue).bold()
                    .foregroundStyle(chunk.direction == .incoming ? .green : .blue)
                Text(String(format: "+%.3f s", chunk.time - openedAt))
                Text("\(chunk.length) B")
                if let note = chunk.note { Text(note).lineLimit(1) }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            Text(Hex.string(chunk.head) + (chunk.length > chunk.head.count ? " …" : ""))
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }
}
