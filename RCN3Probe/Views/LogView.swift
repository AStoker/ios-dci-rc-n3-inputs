import RCKit
import SwiftUI
import UIKit

/// Live log tail, step markers and export.
struct LogView: View {
    @Environment(ProbeModel.self) private var model
    @State private var note = ""
    @State private var shareItem: ShareItem?
    @State private var copied = false
    @State private var follow = true

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    HStack {
                        TextField("Optional note (e.g. left stick full up)", text: $note)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.done)
                            .onSubmit(addMarker)
                        Stepper("", value: $model.markerStep, in: 1...999).labelsHidden()
                    }
                    Button(action: addMarker) {
                        Label("Mark step \(model.markerStep)", systemImage: "flag.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    HStack {
                        Button {
                            shareItem = model.prepareLogForSharing().map(ShareItem.init)
                        } label: {
                            Label("Share log file", systemImage: "square.and.arrow.up")
                        }
                        .disabled(model.logFileURL == nil)
                        Spacer()
                        Button {
                            model.copyReportToClipboard()
                            copied = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                copied = false
                            }
                        } label: {
                            Label(copied ? "Copied" : "Copy report", systemImage: copied ? "checkmark" : "doc.on.clipboard")
                        }
                    }
                    .buttonStyle(.bordered)

                    HStack {
                        Text("\(model.logFileURL?.lastPathComponent ?? "no file") · \(Format.bytes(model.logFileSize))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Toggle("Follow", isOn: $follow).toggleStyle(.button).controlSize(.small)
                        Menu {
                            Button("Start new log file", action: model.startNewLogFile)
                            Button("Clear screen", role: .destructive) { model.log.clearMemory() }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                .padding()

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(model.logLines) { line in
                                Text(line.formatted)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(color(for: line.category))
                                    .textSelection(.enabled)
                                    .id(line.id)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    .onChange(of: model.logLines.last?.id) { _, last in
                        if follow, let last { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
            .navigationTitle("Log")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $shareItem) { item in
                ActivityView(items: [item.url])
            }
        }
    }

    private func addMarker() {
        model.addMarker(note)
        note = ""
    }

    private func color(for category: ProbeLog.Category) -> Color {
        switch category {
        case .mark: .orange
        case .ea: .blue
        case .duml: .green
        case .gc: .purple
        case .net: .teal
        case .stats: .secondary
        case .app, .stream: .primary
        }
    }
}

/// A file to hand to the share sheet. `.sheet(item:)` needs something Identifiable.
struct ShareItem: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The iOS share sheet (`UIActivityViewController`), wrapped for SwiftUI. "Save to Files" and
/// AirDrop to your Mac are the quickest ways to get a log back into the chat.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
