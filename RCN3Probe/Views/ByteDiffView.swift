import RCKit
import SwiftUI

/// The "changed bytes" highlighter.
///
/// Orange flash: this byte changed in the last half second. Yellow tint: it has changed since the
/// baseline (stronger = more often). Tap a byte for its value, range and 16-bit readings.
struct ByteDiffView: View {
    enum Source: Hashable {
        case frame(String)
        case raw(Int)
    }

    @Environment(ProbeModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    let sessionID: String
    let source: Source
    @State private var selected: Int?

    var body: some View {
        let session = model.session(id: sessionID)
        let frameType: StreamAnalyzer.FrameType? = {
            if case let .frame(key) = source { return session?.analyzer.frameTypes[key] }
            return nil
        }()
        let tracker: ByteDiffTracker? = {
            switch source {
            case .frame: frameType?.diff
            case let .raw(length): session?.analyzer.rawDiffs[length]
            }
        }()
        // Payload offset 0 is frame offset 11 (after the DUML header).
        let frameOffset = frameType == nil ? 0 : DUMLFrame.headerLength

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let frameType {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(frameType.label) · \(frameType.name)").font(.headline.monospaced())
                        Text("×\(frameType.count) · \(Format.rate(frameType.rate)) · showing the payload (frame bytes \(frameOffset)…)")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(Hex.string(frameType.lastRaw)).font(.caption2.monospaced()).textSelection(.enabled)
                    }
                }

                if let tracker, tracker.packetCount > 0 {
                    ByteGrid(tracker: tracker, now: model.now, columns: sizeClass == .regular ? 16 : 8,
                             selected: $selected)
                    if let selected, selected < tracker.latest.count {
                        ByteDetail(tracker: tracker, index: selected, frameOffset: frameOffset)
                    } else {
                        Text("Tap a byte for details.").font(.caption).foregroundStyle(.secondary)
                    }
                    Legend()
                } else {
                    Text("No packets yet.").foregroundStyle(.secondary)
                }

                Button("Reset baseline (start watching from now)") {
                    model.resetDiffs(sessionID: sessionID)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .navigationTitle("Changed bytes")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ByteGrid: View {
    let tracker: ByteDiffTracker
    let now: Double
    let columns: Int
    @Binding var selected: Int?

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: columns), spacing: 3) {
            ForEach(0..<tracker.latest.count, id: \.self) { i in
                let recent = tracker.lastChange[i] >= 0 && now - tracker.lastChange[i] < 0.5
                VStack(spacing: 0) {
                    Text(Hex.byte(tracker.latest[i]))
                        .font(.system(.callout, design: .monospaced).weight(recent ? .bold : .regular))
                    Text("\(i)").font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(color(for: i), in: RoundedRectangle(cornerRadius: 5))
                .opacity(i < tracker.latestLength ? 1 : 0.35)
                .overlay {
                    if selected == i { RoundedRectangle(cornerRadius: 5).stroke(Color.primary, lineWidth: 2) }
                }
                .onTapGesture { selected = i }
            }
        }
    }

    private func color(for i: Int) -> Color {
        let changedAt = tracker.lastChange[i]
        if changedAt >= 0 {
            let age = now - changedAt
            if age < 0.5 { return Color.orange.opacity(0.9 - age) }
        }
        let count = tracker.changeCounts[i]
        if count > 0 {
            return Color.yellow.opacity(min(0.55, 0.15 + log10(Double(count)) * 0.15))
        }
        return Color(.secondarySystemFill)
    }
}

private struct ByteDetail: View {
    let tracker: ByteDiffTracker
    let index: Int
    let frameOffset: Int

    var body: some View {
        let value = tracker.latest[index]
        let hasNext = index + 1 < tracker.latest.count
        let next = hasNext ? tracker.latest[index + 1] : 0
        let le = UInt16(value) | UInt16(next) << 8
        let be = UInt16(value) << 8 | UInt16(next)
        VStack(alignment: .leading, spacing: 4) {
            Text("Byte \(index)" + (frameOffset > 0 ? " (frame offset \(index + frameOffset))" : "")).font(.headline)
            Text("0x\(Hex.byte(value)) = \(value) (signed \(Int8(bitPattern: value)))")
            Text("range seen 0x\(Hex.byte(tracker.minSeen[index]))…0x\(Hex.byte(tracker.maxSeen[index])) · \(tracker.changeCounts[index]) changes")
            if hasNext {
                Text("UInt16 LE [\(index),\(index + 1)] = \(le) · signed \(Int16(bitPattern: le))")
                Text("UInt16 BE [\(index),\(index + 1)] = \(be)")
                Text("RC-N1 scale: \(String(format: "%+.3f", RCStickRange.normalized(le))) (364…1024…1684)")
                    .foregroundStyle(.secondary)
            }
            Text("bits \(String(value, radix: 2).leftPadded(to: 8))")
        }
        .font(.callout.monospaced())
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct Legend: View {
    var body: some View {
        HStack(spacing: 16) {
            swatch(.orange.opacity(0.8), "changed just now")
            swatch(.yellow.opacity(0.4), "changed since baseline")
            swatch(Color(.secondarySystemFill), "stable")
        }
        .font(.caption)
    }

    private func swatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 14, height: 14)
            Text(label)
        }
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        String(repeating: "0", count: max(0, length - count)) + self
    }
}
